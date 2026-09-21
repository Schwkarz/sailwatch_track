# SailWatch log receiver

This is a dependency-free authenticated upload endpoint for watch diagnostic files.
It runs on the server's stock Python 3.6 or newer runtime.

- Public routes: `/sailwatch-log/health` and `/sailwatch-log/upload`
- Backend bind: Docker bridge only, `172.17.0.1:18091`
- Per-upload limit: 9 MiB
- Retention: 90 days
- Storage cap: 5 GiB, trimmed to 4 GiB
- Authentication: scoped bearer token from `/etc/sailwatch-log-token`
- Uploaded files: `/opt/sailwatch-log-receiver/data/YYYY-MM-DD/`

The service intentionally provides no public file-listing or download endpoint.

The current public endpoint uses HTTP because the server has no configured domain or
TLS certificate. Before production use, add HTTPS at Nginx and update the watch URL;
diagnostic files can contain location and device-health information.
