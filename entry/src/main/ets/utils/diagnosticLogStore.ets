import { fileIo } from '@kit.CoreFileKit';

export type DiagnosticLogLevel = 'INFO' | 'WARN' | 'ERROR';

/**
 * Small rotating diagnostic log for post-session troubleshooting.
 * It intentionally records status/metrics rather than full sensor payloads.
 */
export class DiagnosticLogStore {
  private readonly MAX_LOG_BYTES: number = 8 * 1024 * 1024;
  private logDir: string = '';
  private logPath: string = '';
  private previousLogPath: string = '';
  private currentBytes: number = 0;
  private ready: boolean = false;

  public setup(filesDir: string): void {
    this.logDir = `${filesDir}/diagnostics`;
    this.logPath = `${this.logDir}/runtime.log`;
    this.previousLogPath = `${this.logDir}/runtime.previous.log`;
    if (!this.exists(this.logDir)) {
      fileIo.mkdirSync(this.logDir);
    }
    if (!this.exists(this.logPath)) {
      this.writeText(this.logPath, '');
    }
    try {
      this.currentBytes = Number(fileIo.statSync(this.logPath).size);
    } catch (_) {
      this.currentBytes = 0;
    }
    this.ready = true;
    this.info('APP', 'diagnostic logger started');
  }

  public info(tag: string, message: string): void {
    this.log('INFO', tag, message);
  }

  public warn(tag: string, message: string): void {
    this.log('WARN', tag, message);
  }

  public error(tag: string, message: string): void {
    this.log('ERROR', tag, message);
  }

  public log(level: DiagnosticLogLevel, tag: string, message: string): void {
    if (!this.ready) {
      return;
    }
    const safeMessage: string = message.replace(/\r/g, ' ').replace(/\n/g, ' ');
    const line: string = `${new Date().toISOString()} [${level}] [${tag}] ${safeMessage}\n`;
    try {
      if (this.currentBytes + line.length > this.MAX_LOG_BYTES) {
        this.rotate();
      }
      const file = fileIo.openSync(
        this.logPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.APPEND
      );
      try {
        fileIo.writeSync(file.fd, line);
        this.currentBytes += line.length;
      } finally {
        fileIo.closeSync(file);
      }
    } catch (error) {
      console.error(`write diagnostic log failed: ${JSON.stringify(error)}`);
    }
  }

  public getLogPath(): string {
    return this.logPath;
  }

  private rotate(): void {
    try {
      if (this.exists(this.previousLogPath)) {
        fileIo.unlinkSync(this.previousLogPath);
      }
      fileIo.renameSync(this.logPath, this.previousLogPath);
    } catch (error) {
      console.error(`rotate diagnostic log failed: ${JSON.stringify(error)}`);
    }
    this.writeText(this.logPath, '');
    this.currentBytes = 0;
  }

  private exists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (_) {
      return false;
    }
  }

  private writeText(path: string, text: string): void {
    const file = fileIo.openSync(
      path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC
    );
    try {
      fileIo.writeSync(file.fd, text);
    } finally {
      fileIo.closeSync(file);
    }
  }
}
