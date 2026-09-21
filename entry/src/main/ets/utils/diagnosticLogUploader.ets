import { fileIo } from '@kit.CoreFileKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import http from '@ohos.net.http';
import { DiagnosticLogStore } from './diagnosticLogStore';
import { DIAGNOSTIC_UPLOAD_TOKEN, DIAGNOSTIC_UPLOAD_URL } from './diagnosticUploadConfig';

interface UploadedFileState {
  name: string;
  fingerprint: string;
}

interface DiagnosticUploadState {
  schemaVersion: number;
  files: UploadedFileState[];
}

/**
 * Uploads diagnostic snapshots only after the app has stayed idle for a while.
 * Sensor data and MQTT traffic are never delayed by this uploader.
 */
export class DiagnosticLogUploader {
  private readonly IDLE_DELAY_MS: number = 30 * 1000;
  private readonly INITIAL_RETRY_MS: number = 5 * 60 * 1000;
  private readonly MAX_RETRY_MS: number = 6 * 60 * 60 * 1000;
  private readonly MAX_FILE_CHARS: number = 9 * 1024 * 1024;
  private readonly CANDIDATE_NAMES: string[] = [
    'runtime.previous.log',
    'previous_run_state.json',
    'runtime.log',
    'run_state.json'
  ];

  private diagnosticsDir: string = '';
  private statePath: string = '';
  private logger: DiagnosticLogStore | null = null;
  private idleSince: number = 0;
  private idleUploadCompleted: boolean = false;
  private uploadInFlight: boolean = false;
  private nextAttemptAt: number = 0;
  private consecutiveFailures: number = 0;
  private currentProgress: number = 0;
  private progressCallback: ((progress: number, message: string, phase: string) => void) | null = null;

  public setup(filesDir: string, logger: DiagnosticLogStore): void {
    this.diagnosticsDir = `${filesDir}/diagnostics`;
    this.statePath = `${filesDir}/diagnostic_upload_state.json`;
    this.logger = logger;
  }

  public noteMonitoringStarted(): void {
    this.idleSince = 0;
    this.idleUploadCompleted = false;
  }

  public noteMonitoringStopped(): void {
    this.idleSince = Date.now();
    this.idleUploadCompleted = false;
  }

  public setProgressCallback(
    callback: (progress: number, message: string, phase: string) => void
  ): void {
    this.progressCallback = callback;
  }

  public async tryUploadIfIdle(idle: boolean): Promise<void> {
    if (!idle) {
      // Keep the stop timestamp while MQTT draining or BLE scanning finishes.
      // Monitoring start paths reset the timestamp explicitly via noteMonitoringStarted().
      return;
    }
    const now: number = Date.now();
    if (this.idleSince === 0) {
      this.idleSince = now;
    }
    if (this.idleUploadCompleted || this.uploadInFlight || now < this.nextAttemptAt ||
      now - this.idleSince < this.IDLE_DELAY_MS) {
      return;
    }

    this.uploadInFlight = true;
    this.reportProgress(0, '自动上传：正在准备日志', 'running');
    try {
      const uploadedCount: number = await this.uploadChangedFiles();
      this.consecutiveFailures = 0;
      this.nextAttemptAt = 0;
      this.idleUploadCompleted = true;
      this.logger?.info('LOG_UPLOAD', `idle diagnostic upload completed uploadedCount=${uploadedCount}`);
      this.reportProgress(100, uploadedCount > 0 ?
        `自动上传成功：${uploadedCount} 个文件` : '自动上传完成：没有新日志', 'success');
    } catch (error) {
      this.consecutiveFailures += 1;
      const multiplier: number = Math.pow(2, Math.min(this.consecutiveFailures - 1, 6));
      const delayMs: number = Math.min(this.MAX_RETRY_MS, this.INITIAL_RETRY_MS * multiplier);
      this.nextAttemptAt = Date.now() + delayMs;
      this.logger?.warn('LOG_UPLOAD',
        `upload failed attempt=${this.consecutiveFailures},retryInMs=${delayMs},error=${JSON.stringify(error)}`);
      this.reportProgress(this.currentProgress, '自动上传失败，将自动重试', 'failed');
    } finally {
      this.uploadInFlight = false;
    }
  }

  public isUploading(): boolean {
    return this.uploadInFlight;
  }

  public async uploadNow(): Promise<number> {
    if (this.uploadInFlight) {
      throw new Error('diagnostic upload already in progress');
    }

    this.uploadInFlight = true;
    this.logger?.info('LOG_UPLOAD', 'manual diagnostic upload requested');
    this.reportProgress(0, '正在准备日志', 'running');
    try {
      const uploadedCount: number = await this.uploadChangedFiles();
      this.consecutiveFailures = 0;
      this.nextAttemptAt = 0;
      this.idleUploadCompleted = true;
      this.logger?.info('LOG_UPLOAD', `manual diagnostic upload completed uploadedCount=${uploadedCount}`);
      this.reportProgress(100, uploadedCount > 0 ?
        `上传成功：${uploadedCount} 个文件` : '上传完成：没有新日志', 'success');
      return uploadedCount;
    } catch (error) {
      this.consecutiveFailures += 1;
      const multiplier: number = Math.pow(2, Math.min(this.consecutiveFailures - 1, 6));
      const delayMs: number = Math.min(this.MAX_RETRY_MS, this.INITIAL_RETRY_MS * multiplier);
      this.nextAttemptAt = Date.now() + delayMs;
      this.logger?.warn('LOG_UPLOAD',
        `manual upload failed attempt=${this.consecutiveFailures},retryInMs=${delayMs},` +
        `error=${JSON.stringify(error)}`);
      this.reportProgress(this.currentProgress, '上传失败，将自动重试', 'failed');
      throw new Error(`manual diagnostic upload failed: ${JSON.stringify(error)}`);
    } finally {
      this.uploadInFlight = false;
    }
  }

  private reportProgress(
    progress: number,
    message: string,
    phase: string = 'running'
  ): void {
    this.currentProgress = Math.max(0, Math.min(100, progress));
    if (this.progressCallback !== null) {
      this.progressCallback(this.currentProgress, message, phase);
    }
  }

  private async uploadChangedFiles(): Promise<number> {
    if (this.diagnosticsDir.length === 0 || this.statePath.length === 0 || this.logger === null) {
      throw new Error('diagnostic uploader is not initialized');
    }
    const state: DiagnosticUploadState = this.readState();
    let uploadedCount: number = 0;
    const totalCount: number = this.CANDIDATE_NAMES.length;

    for (let index: number = 0; index < totalCount; index += 1) {
      const name: string = this.CANDIDATE_NAMES[index];
      const completedProgress: number = Math.round(((index + 1) / totalCount) * 100);
      this.reportProgress(Math.max(2, Math.round((index / totalCount) * 100)),
        `正在检查日志 ${index + 1}/${totalCount}`);
      await this.yieldToUi();
      const path: string = `${this.diagnosticsDir}/${name}`;
      if (!this.exists(path)) {
        this.reportProgress(completedProgress,
          `已检查日志 ${index + 1}/${totalCount}`);
        continue;
      }
      const content: string = await fileIo.readText(path);
      if (content.length === 0) {
        this.reportProgress(completedProgress,
          `已检查日志 ${index + 1}/${totalCount}`);
        continue;
      }
      if (content.length > this.MAX_FILE_CHARS) {
        this.logger.warn('LOG_UPLOAD', `skip oversized file=${name},chars=${content.length}`);
        this.reportProgress(completedProgress,
          `已跳过过大日志 ${index + 1}/${totalCount}`);
        continue;
      }
      const fingerprint: string = await this.fingerprint(content);
      if (this.findFingerprint(state, name) === fingerprint) {
        this.reportProgress(completedProgress,
          `已检查日志 ${index + 1}/${totalCount}`);
        continue;
      }

      this.reportProgress(Math.round(((index + 0.5) / totalCount) * 100),
        `正在上传日志 ${index + 1}/${totalCount}`);
      await this.uploadFile(name, content);
      this.updateFingerprint(state, name, fingerprint);
      this.writeState(state);
      uploadedCount += 1;
      this.reportProgress(completedProgress,
        `已上传 ${uploadedCount} 个文件`);
    }

    this.logger.info('LOG_UPLOAD', `changed files uploaded count=${uploadedCount}`);
    this.reportProgress(100, '日志处理完成');
    return uploadedCount;
  }

  private async uploadFile(name: string, content: string): Promise<void> {
    if (this.logger === null) {
      throw new Error('diagnostic logger unavailable');
    }
    const request: http.HttpRequest = http.createHttp();
    try {
      let productModel: string = 'unknown-wearable';
      try {
        productModel = deviceInfo.productModel;
      } catch (_) {
        // Keep the fallback; failure is non-fatal for uploads.
      }
      const response: http.HttpResponse = await request.request(
        DIAGNOSTIC_UPLOAD_URL,
        {
          method: http.RequestMethod.POST,
          connectTimeout: 15000,
          readTimeout: 45000,
          header: {
            'Authorization': `Bearer ${DIAGNOSTIC_UPLOAD_TOKEN}`,
            'Content-Type': 'text/plain; charset=utf-8',
            'X-SailWatch-File': name,
            'X-SailWatch-Run-Id': this.logger.getRunId(),
            'X-SailWatch-Device': productModel
          },
          extraData: content
        }
      );
      if (response.responseCode !== http.ResponseCode.OK &&
        response.responseCode !== http.ResponseCode.CREATED) {
        throw new Error(`server returned HTTP ${response.responseCode}`);
      }
      this.logger.info('LOG_UPLOAD',
        `file uploaded name=${name},chars=${content.length},responseCode=${response.responseCode}`);
    } finally {
      request.destroy();
    }
  }

  private async yieldToUi(): Promise<void> {
    await new Promise<void>(resolve => setTimeout(resolve, 0));
  }

  private async fingerprint(content: string): Promise<string> {
    let hash: number = 2166136261;
    for (let index: number = 0; index < content.length; index += 1) {
      hash ^= content.charCodeAt(index);
      hash = Math.imul(hash, 16777619);
      if (index > 0 && index % 65536 === 0) {
        await this.yieldToUi();
      }
    }
    return `${content.length}:${(hash >>> 0).toString(16)}`;
  }

  private findFingerprint(state: DiagnosticUploadState, name: string): string {
    for (const fileState of state.files) {
      if (fileState.name === name) {
        return fileState.fingerprint;
      }
    }
    return '';
  }

  private updateFingerprint(state: DiagnosticUploadState, name: string, fingerprint: string): void {
    for (const fileState of state.files) {
      if (fileState.name === name) {
        fileState.fingerprint = fingerprint;
        return;
      }
    }
    state.files.push({ name: name, fingerprint: fingerprint } as UploadedFileState);
  }

  private readState(): DiagnosticUploadState {
    if (!this.exists(this.statePath)) {
      return { schemaVersion: 1, files: [] } as DiagnosticUploadState;
    }
    try {
      const text: string = fileIo.readTextSync(this.statePath).trim();
      if (text.length === 0) {
        return { schemaVersion: 1, files: [] } as DiagnosticUploadState;
      }
      const state: DiagnosticUploadState = JSON.parse(text) as DiagnosticUploadState;
      if (state.schemaVersion !== 1 || !state.files) {
        return { schemaVersion: 1, files: [] } as DiagnosticUploadState;
      }
      return state;
    } catch (_) {
      return { schemaVersion: 1, files: [] } as DiagnosticUploadState;
    }
  }

  private writeState(state: DiagnosticUploadState): void {
    const file = fileIo.openSync(
      this.statePath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC
    );
    try {
      fileIo.writeSync(file.fd, JSON.stringify(state));
    } finally {
      fileIo.closeSync(file);
    }
  }

  private exists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (_) {
      return false;
    }
  }
}
