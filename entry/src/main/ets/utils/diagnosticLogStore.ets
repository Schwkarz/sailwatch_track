import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export type DiagnosticLogLevel = 'INFO' | 'WARN' | 'ERROR';

export interface DiagnosticRunState {
  schemaVersion: number;
  runId: string;
  startedAt: number;
  sessionStartedAt: number;
  lastHeartbeatAt: number;
  lifecycle: string;
  monitoringActive: boolean;
  monitoringMode: string;
  cleanExit: boolean;
  lastDetail: string;
  lastSystemEvent: string;
}

const DIAGNOSTIC_DOMAIN: number = 0x0000;
const DIAGNOSTIC_TAG: string = 'SailWatchDiag';

/**
 * Small rotating diagnostic log for post-session troubleshooting.
 * It intentionally records status/metrics rather than full sensor payloads.
 */
export class DiagnosticLogStore {
  private readonly MAX_LOG_BYTES: number = 8 * 1024 * 1024;
  private readonly HEARTBEAT_INTERVAL_MS: number = 15 * 1000;
  private logDir: string = '';
  private logPath: string = '';
  private previousLogPath: string = '';
  private statePath: string = '';
  private previousStatePath: string = '';
  private currentBytes: number = 0;
  private ready: boolean = false;
  private runState: DiagnosticRunState | null = null;
  private lastHeartbeatWriteAt: number = 0;

  public setup(filesDir: string): void {
    const requestedLogDir: string = `${filesDir}/diagnostics`;
    if (this.ready && this.logDir === requestedLogDir) {
      return;
    }
    this.logDir = requestedLogDir;
    this.logPath = `${this.logDir}/runtime.log`;
    this.previousLogPath = `${this.logDir}/runtime.previous.log`;
    this.statePath = `${this.logDir}/run_state.json`;
    this.previousStatePath = `${this.logDir}/previous_run_state.json`;
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
    this.startNewRun();
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
    this.writeSystemLog(level, tag, safeMessage);
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

  public getPreviousLogPath(): string {
    return this.previousLogPath;
  }

  public getStatePath(): string {
    return this.statePath;
  }

  public getPreviousStatePath(): string {
    return this.previousStatePath;
  }

  public recordLifecycle(lifecycle: string, detail: string = ''): void {
    if (!this.runState) {
      return;
    }
    const now: number = Date.now();
    this.runState.lifecycle = lifecycle;
    this.runState.lastHeartbeatAt = now;
    this.runState.lastDetail = detail;
    this.lastHeartbeatWriteAt = now;
    this.writeRunState();
    this.info('APP_LIFECYCLE', `state=${lifecycle}${detail.length > 0 ? `,${detail}` : ''}`);
  }

  public recordMonitoring(active: boolean, mode: string, detail: string = ''): void {
    if (!this.runState) {
      return;
    }
    const now: number = Date.now();
    this.runState.monitoringActive = active;
    this.runState.monitoringMode = mode;
    this.runState.sessionStartedAt = active ? now : this.runState.sessionStartedAt;
    this.runState.lastHeartbeatAt = now;
    this.runState.lastDetail = detail;
    this.lastHeartbeatWriteAt = now;
    this.writeRunState();
    this.info('MONITOR_SESSION',
      `active=${active},mode=${mode}${detail.length > 0 ? `,${detail}` : ''}`);
  }

  public heartbeat(detail: string): void {
    if (!this.runState) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastHeartbeatWriteAt < this.HEARTBEAT_INTERVAL_MS) {
      return;
    }
    this.runState.lastHeartbeatAt = now;
    this.runState.lastDetail = detail;
    this.lastHeartbeatWriteAt = now;
    this.writeRunState();
    this.info('HEARTBEAT', detail);
  }

  public recordSystemEvent(eventName: string, params: string): void {
    const clippedParams: string = params.length > 6000 ? `${params.substring(0, 6000)}...[truncated]` : params;
    if (this.runState) {
      this.runState.lastSystemEvent = eventName;
      this.runState.lastHeartbeatAt = Date.now();
      this.runState.lastDetail = `systemEvent=${eventName}`;
      this.writeRunState();
    }
    if (eventName === 'APP_CRASH' || eventName === 'APP_FREEZE' || eventName === 'APP_KILLED') {
      this.error('SYSTEM_EVENT', `name=${eventName},params=${clippedParams}`);
    } else {
      this.warn('SYSTEM_EVENT', `name=${eventName},params=${clippedParams}`);
    }
  }

  public markAbilityDestroyed(): void {
    if (!this.runState) {
      return;
    }
    const monitoringActive: boolean = this.runState.monitoringActive;
    this.runState.lifecycle = 'ability_on_destroy';
    this.runState.lastHeartbeatAt = Date.now();
    this.runState.lastDetail = monitoringActive ? 'ability_destroyed_while_monitoring' : 'normal_ability_destroy';
    this.runState.cleanExit = !monitoringActive;
    this.writeRunState();
    if (monitoringActive) {
      this.warn('APP_LIFECYCLE', 'ability destroyed while monitoring was active');
    } else {
      this.info('APP_LIFECYCLE', 'ability destroyed after monitoring stopped');
    }
  }

  public isMonitoringActive(): boolean {
    return this.runState !== null && this.runState.monitoringActive;
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

  private startNewRun(): void {
    const previousState: DiagnosticRunState | null = this.readRunState();
    if (previousState) {
      try {
        this.writeText(this.previousStatePath, JSON.stringify(previousState));
      } catch (error) {
        this.warn('DIAGNOSTIC', `failed to preserve previous run state error=${JSON.stringify(error)}`);
      }
      const ageMs: number = Math.max(0, Date.now() - previousState.lastHeartbeatAt);
      if (!previousState.cleanExit) {
        this.warn('PREVIOUS_RUN',
          `unclean_exit runId=${previousState.runId},monitoringActive=${previousState.monitoringActive},` +
          `mode=${previousState.monitoringMode},lifecycle=${previousState.lifecycle},` +
          `lastHeartbeatAgeMs=${ageMs},lastDetail=${previousState.lastDetail},` +
          `lastSystemEvent=${previousState.lastSystemEvent}`);
      } else {
        this.info('PREVIOUS_RUN',
          `clean_exit runId=${previousState.runId},lifecycle=${previousState.lifecycle},` +
          `lastHeartbeatAgeMs=${ageMs}`);
      }
    }

    const now: number = Date.now();
    this.runState = {
      schemaVersion: 1,
      runId: `${now}-${Math.floor(Math.random() * 1000000)}`,
      startedAt: now,
      sessionStartedAt: 0,
      lastHeartbeatAt: now,
      lifecycle: 'logger_setup',
      monitoringActive: false,
      monitoringMode: 'none',
      cleanExit: false,
      lastDetail: 'new_run',
      lastSystemEvent: ''
    };
    this.lastHeartbeatWriteAt = now;
    this.writeRunState();
    this.info('APP', `run started runId=${this.runState.runId}`);
  }

  private readRunState(): DiagnosticRunState | null {
    if (this.statePath.length === 0 || !this.exists(this.statePath)) {
      return null;
    }
    try {
      const text: string = fileIo.readTextSync(this.statePath).trim();
      if (text.length === 0) {
        return null;
      }
      const state: DiagnosticRunState = JSON.parse(text) as DiagnosticRunState;
      if (state.schemaVersion !== 1 || state.runId.length === 0 || state.lastHeartbeatAt <= 0) {
        this.warn('DIAGNOSTIC', 'ignored invalid previous run state');
        return null;
      }
      return state;
    } catch (error) {
      this.warn('DIAGNOSTIC', `failed to read previous run state error=${JSON.stringify(error)}`);
      return null;
    }
  }

  private writeRunState(): void {
    if (!this.runState || this.statePath.length === 0) {
      return;
    }
    try {
      this.writeText(this.statePath, JSON.stringify(this.runState));
    } catch (error) {
      console.error(`write diagnostic run state failed: ${JSON.stringify(error)}`);
    }
  }

  private writeSystemLog(level: DiagnosticLogLevel, tag: string, message: string): void {
    const fullMessage: string = `[${tag}] ${message}`;
    const systemMessage: string = fullMessage.length > 1000 ?
      `${fullMessage.substring(0, 1000)}...[truncated]` : fullMessage;
    if (level === 'ERROR') {
      hilog.error(DIAGNOSTIC_DOMAIN, DIAGNOSTIC_TAG, '%{public}s', systemMessage);
    } else if (level === 'WARN') {
      hilog.warn(DIAGNOSTIC_DOMAIN, DIAGNOSTIC_TAG, '%{public}s', systemMessage);
    }
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

export const diagnosticLogStore: DiagnosticLogStore = new DiagnosticLogStore();
