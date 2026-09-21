#!/usr/bin/env python3
"""Small authenticated HTTP receiver for SailWatch diagnostic files."""

import argparse
import hashlib
import hmac
import json
import os
import re
import tempfile
import time
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from socketserver import ThreadingMixIn
from typing import Any, Dict, Iterable, Optional, Tuple


MAX_UPLOAD_BYTES = 9 * 1024 * 1024
RETENTION_SECONDS = 90 * 24 * 60 * 60
MAX_STORAGE_BYTES = 5 * 1024 * 1024 * 1024
TRIM_STORAGE_BYTES = 4 * 1024 * 1024 * 1024
SAFE_PART = re.compile(r"[^A-Za-z0-9._-]+")


def safe_part(value: str, fallback: str, limit: int = 80) -> str:
    cleaned = SAFE_PART.sub("_", value.strip()).strip("._-")
    return (cleaned or fallback)[:limit]


def iter_uploaded_files(root: Path) -> Iterable[Path]:
    for path in root.rglob("*"):
        if path.is_file() and not path.name.endswith(".part"):
            yield path


def safe_unlink(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def cleanup_storage(root: Path) -> None:
    now = time.time()
    files = list(iter_uploaded_files(root))
    for path in files:
        try:
            if now - path.stat().st_mtime > RETENTION_SECONDS:
                safe_unlink(path)
        except OSError:
            continue

    files = []
    total = 0
    for path in iter_uploaded_files(root):
        try:
            stat = path.stat()
        except OSError:
            continue
        files.append((stat.st_mtime, stat.st_size, path))
        total += stat.st_size

    if total <= MAX_STORAGE_BYTES:
        return
    for _, size, path in sorted(files):
        try:
            safe_unlink(path)
            total -= size
        except OSError:
            continue
        if total <= TRIM_STORAGE_BYTES:
            break


class ReceiverServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: Tuple[str, int], root: Path, token: str) -> None:
        super().__init__(address, ReceiverHandler)
        self.storage_root = root
        self.upload_token = token


class ReceiverHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "SailWatchLogReceiver/1"

    @property
    def receiver(self):
        return self.server  # type: ignore[return-value]

    def log_message(self, fmt: str, *args: object) -> None:
        print(
            f"{datetime.now(timezone.utc).isoformat()} "
            f"remote={self.client_address[0]} {fmt % args}",
            flush=True,
        )

    def send_json(self, status: HTTPStatus, payload: Dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def authenticated(self) -> bool:
        supplied = self.headers.get("Authorization", "")
        expected = f"Bearer {self.receiver.upload_token}"
        return hmac.compare_digest(supplied, expected)

    def do_GET(self) -> None:
        if self.path != "/health":
            self.send_json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "not_found"})
            return
        self.send_json(HTTPStatus.OK, {"ok": True, "service": "sailwatch-log-receiver"})

    def do_POST(self) -> None:
        if self.path != "/upload":
            self.close_connection = True
            self.send_json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "not_found"})
            return
        if not self.authenticated():
            self.close_connection = True
            self.send_json(HTTPStatus.UNAUTHORIZED, {"ok": False, "error": "unauthorized"})
            return

        try:
            length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            length = -1
        if length <= 0 or length > MAX_UPLOAD_BYTES:
            self.close_connection = True
            self.send_json(
                HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                {"ok": False, "error": "invalid_size", "maxBytes": MAX_UPLOAD_BYTES},
            )
            return

        source_name = safe_part(self.headers.get("X-SailWatch-File", ""), "runtime.log")
        run_id = safe_part(self.headers.get("X-SailWatch-Run-Id", ""), "unknown-run")
        device = safe_part(self.headers.get("X-SailWatch-Device", ""), "unknown-device")
        day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        target_dir = self.receiver.storage_root / day
        target_dir.mkdir(parents=True, exist_ok=True)

        digest = hashlib.sha256()
        remaining = length
        temp_path = None  # type: Optional[Path]
        try:
            with tempfile.NamedTemporaryFile(
                mode="wb", prefix="upload-", suffix=".part", dir=target_dir, delete=False
            ) as output:
                temp_path = Path(output.name)
                while remaining > 0:
                    chunk = self.rfile.read(min(64 * 1024, remaining))
                    if not chunk:
                        raise ConnectionError("request body ended early")
                    output.write(chunk)
                    digest.update(chunk)
                    remaining -= len(chunk)
                output.flush()
                os.fsync(output.fileno())

            sha256 = digest.hexdigest()
            duplicate = next(target_dir.glob(f"*_{sha256[:16]}_*"), None)
            if duplicate is not None:
                safe_unlink(temp_path)
                self.send_json(
                    HTTPStatus.OK,
                    {"ok": True, "deduplicated": True, "sha256": sha256, "size": length},
                )
                return

            received_at = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
            final_name = f"{received_at}_{sha256[:16]}_{device}_{run_id}_{source_name}"
            final_path = target_dir / final_name
            temp_path.replace(final_path)
            os.chmod(final_path, 0o640)
            cleanup_storage(self.receiver.storage_root)
            self.send_json(
                HTTPStatus.CREATED,
                {
                    "ok": True,
                    "deduplicated": False,
                    "sha256": sha256,
                    "size": length,
                    "storedAs": f"{day}/{final_name}",
                },
            )
        except Exception as error:  # noqa: BLE001 - boundary logs and returns a safe error
            if temp_path is not None:
                safe_unlink(temp_path)
            self.log_error("upload failed: %s", repr(error))
            self.send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"ok": False, "error": "store_failed"})


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="172.17.0.1")
    parser.add_argument("--port", type=int, default=18091)
    parser.add_argument("--root", type=Path, default=Path("/opt/sailwatch-log-receiver/data"))
    parser.add_argument("--token-file", type=Path, default=Path("/etc/sailwatch-log-token"))
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    token = args.token_file.read_text(encoding="utf-8").strip()
    if len(token) < 32:
        raise SystemExit("upload token must contain at least 32 characters")
    args.root.mkdir(parents=True, exist_ok=True)
    server = ReceiverServer((args.host, args.port), args.root, token)
    print(f"listening on {args.host}:{args.port}, root={args.root}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
