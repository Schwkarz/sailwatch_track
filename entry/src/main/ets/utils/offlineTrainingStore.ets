import { fileIo } from '@kit.CoreFileKit';

const SCHEMA_VERSION: number = 3;
const MAX_CHART_POINTS: number = 3600;
const CHART_SAMPLE_INTERVAL_SEC: number = 5;

export interface OfflineVector3 {
  x: number;
  y: number;
  z: number;
}

export interface OfflineAngle {
  roll: number;
  pitch: number;
  yaw: number;
}

export interface OfflineImuSample {
  acceleration: OfflineVector3;
  angularVelocity: OfflineVector3;
  angle: OfflineAngle;
  rawData: number[];
}

export interface OfflineGpsSample {
  longitude: number;
  latitude: number;
  rawLongitude?: number;
  rawLatitude?: number;
  speed: number;
  headingT: number | null;
  accuracy: number;
  accepted?: boolean;
  filterReason?: string;
}

export interface OfflineRawSample {
  schemaVersion: number;
  timestamp: number;
  heartRate: number;
  gps: OfflineGpsSample;
  imu: OfflineImuSample | string;
}

export interface ChartPoint {
  offsetSec: number;
  value: number;
}

export interface TrainingReport {
  schemaVersion: number;
  id: string;
  startedAt: number;
  endedAt: number;
  durationSec: number;
  sampleCount: number;
  averageHeartRate: number;
  maxHeartRate: number;
  minHeartRate: number;
  averageTilt: number;
  maxTilt: number;
  distanceMeter: number;
  rawDataPath: string;
  heartSeries: ChartPoint[];
  tiltSeries: ChartPoint[];
  mode?: 'online' | 'offline';
}

export interface TrainingReportIndexItem {
  id: string;
  startedAt: number;
  endedAt: number;
  durationSec: number;
  sampleCount: number;
  averageHeartRate: number;
  maxHeartRate: number;
  mode?: 'online' | 'offline';
}

interface TrainingReportIndexFile {
  schemaVersion: number;
  reports: TrainingReportIndexItem[];
}

interface OfflineSessionState {
  id: string;
  startedAt: number;
  rawDataPath: string;
  sampleCount: number;
  heartSum: number;
  heartCount: number;
  maxHeartRate: number;
  minHeartRate: number;
  tiltSum: number;
  tiltCount: number;
  maxTilt: number;
  distanceMeter: number;
  lastLongitude: number | null;
  lastLatitude: number | null;
  heartSeries: ChartPoint[];
  tiltSeries: ChartPoint[];
  mode: 'online' | 'offline';
}

export class OfflineTrainingStore {
  private recordsDir: string = "";
  private rawDir: string = "";
  private reportsDir: string = "";
  private indexPath: string = "";
  private currentSession: OfflineSessionState | null = null;

  public setup(filesDir: string): void {
    this.recordsDir = `${filesDir}/records`;
    this.rawDir = `${this.recordsDir}/raw`;
    this.reportsDir = `${this.recordsDir}/reports`;
    this.indexPath = `${this.recordsDir}/index.json`;
    this.ensureStorage();
  }

  public hasActiveSession(): boolean {
    return this.currentSession !== null;
  }

  public startSession(startedAt: number, mode: 'online' | 'offline' = 'offline'): string {
    this.ensureStorage();
    const id: string = `session_${startedAt}`;
    const rawDataPath: string = this.getRawPath(id);
    this.writeText(rawDataPath, "");

    const session: OfflineSessionState = {
      id: id,
      startedAt: startedAt,
      rawDataPath: rawDataPath,
      sampleCount: 0,
      heartSum: 0,
      heartCount: 0,
      maxHeartRate: 0,
      minHeartRate: 0,
      tiltSum: 0,
      tiltCount: 0,
      maxTilt: 0,
      distanceMeter: 0,
      lastLongitude: null,
      lastLatitude: null,
      heartSeries: [],
      tiltSeries: [],
      mode: mode
    };
    this.currentSession = session;
    return id;
  }

  public appendSample(sample: OfflineRawSample): void {
    if (!this.currentSession) {
      return;
    }

    this.appendText(this.currentSession.rawDataPath, `${JSON.stringify(sample)}\n`);
    this.currentSession.sampleCount += 1;
    this.updateHeartStats(sample);
    this.updateTiltStats(sample);
    this.updateGpsStats(sample);
  }

  public finishSession(endedAt: number): TrainingReport | null {
    if (!this.currentSession) {
      return null;
    }

    const session: OfflineSessionState = this.currentSession;
    const safeEndedAt: number = Math.max(endedAt, session.startedAt);
    const durationSec: number = Math.floor((safeEndedAt - session.startedAt) / 1000);
    const averageHeartRate: number = session.heartCount > 0 ? Math.round(session.heartSum / session.heartCount) : 0;
    const minHeartRate: number = session.heartCount > 0 ? session.minHeartRate : 0;
    const averageTilt: number = session.tiltCount > 0 ?
      Math.round(session.tiltSum / session.tiltCount * 10) / 10 : 0;

    const report: TrainingReport = {
      schemaVersion: SCHEMA_VERSION,
      id: session.id,
      startedAt: session.startedAt,
      endedAt: safeEndedAt,
      durationSec: durationSec,
      sampleCount: session.sampleCount,
      averageHeartRate: averageHeartRate,
      maxHeartRate: session.maxHeartRate,
      minHeartRate: minHeartRate,
      averageTilt: averageTilt,
      maxTilt: Math.round(session.maxTilt * 10) / 10,
      distanceMeter: Math.round(session.distanceMeter),
      rawDataPath: session.rawDataPath,
      heartSeries: session.heartSeries,
      tiltSeries: session.tiltSeries,
      mode: session.mode
    };

    this.currentSession = null;
    this.writeText(this.getReportPath(session.id), JSON.stringify(report));
    this.addReportToIndex(report);
    return report;
  }

  public listReports(): TrainingReportIndexItem[] {
    this.ensureStorage();
    return this.readIndex().reports;
  }

  public readReport(id: string): TrainingReport | null {
    this.ensureStorage();
    const reportPath: string = this.getReportPath(id);
    if (!this.pathExists(reportPath)) {
      return null;
    }

    try {
      const text: string = fileIo.readTextSync(reportPath);
      const report: TrainingReport = JSON.parse(text) as TrainingReport;
      if (!report.heartSeries) {
        report.heartSeries = [];
      }
      if (!report.tiltSeries) {
        report.tiltSeries = [];
      }
      if (!report.mode) {
        report.mode = 'offline';
      }
      if (report.averageTilt === undefined) {
        report.averageTilt = 0;
      }
      if (report.maxTilt === undefined) {
        report.maxTilt = 0;
      }
      if (report.schemaVersion < SCHEMA_VERSION && report.tiltSeries.length > 0) {
        this.restoreSignedTiltStats(report);
      }
      return report;
    } catch (error) {
      console.error(`read offline report failed: ${JSON.stringify(error)}`);
      return null;
    }
  }

  public deleteReport(id: string): boolean {
    this.ensureStorage();
    const rawPath: string = this.getRawPath(id);
    const reportPath: string = this.getReportPath(id);
    try {
      this.deleteIfExists(rawPath);
      this.deleteIfExists(reportPath);

      const indexFile: TrainingReportIndexFile = this.readIndex();
      const remainingReports: TrainingReportIndexItem[] = [];
      for (let i: number = 0; i < indexFile.reports.length; i++) {
        if (indexFile.reports[i].id !== id) {
          remainingReports.push(indexFile.reports[i]);
        }
      }
      indexFile.reports = remainingReports;
      indexFile.schemaVersion = SCHEMA_VERSION;
      this.writeText(this.indexPath, JSON.stringify(indexFile));
      return true;
    } catch (error) {
      console.error(`delete offline report failed: ${JSON.stringify(error)}`);
      return false;
    }
  }

  private ensureStorage(): void {
    if (this.recordsDir.length === 0) {
      return;
    }
    this.ensureDir(this.recordsDir);
    this.ensureDir(this.rawDir);
    this.ensureDir(this.reportsDir);
    if (!this.pathExists(this.indexPath)) {
      const indexFile: TrainingReportIndexFile = {
        schemaVersion: SCHEMA_VERSION,
        reports: []
      };
      this.writeText(this.indexPath, JSON.stringify(indexFile));
    }
  }

  private ensureDir(path: string): void {
    if (this.pathExists(path)) {
      return;
    }
    fileIo.mkdirSync(path);
  }

  private pathExists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (error) {
      return false;
    }
  }

  private deleteIfExists(path: string): void {
    if (this.pathExists(path)) {
      fileIo.unlinkSync(path);
    }
  }

  private getRawPath(id: string): string {
    return `${this.rawDir}/${id}.jsonl`;
  }

  private getReportPath(id: string): string {
    return `${this.reportsDir}/${id}.json`;
  }

  private appendText(path: string, text: string): void {
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.APPEND);
    try {
      fileIo.writeSync(file.fd, text);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private writeText(path: string, text: string): void {
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, text);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private readIndex(): TrainingReportIndexFile {
    if (!this.pathExists(this.indexPath)) {
      const emptyIndex: TrainingReportIndexFile = {
        schemaVersion: SCHEMA_VERSION,
        reports: []
      };
      return emptyIndex;
    }

    try {
      const text: string = fileIo.readTextSync(this.indexPath);
      return JSON.parse(text) as TrainingReportIndexFile;
    } catch (error) {
      console.error(`read offline index failed: ${JSON.stringify(error)}`);
      const fallbackIndex: TrainingReportIndexFile = {
        schemaVersion: SCHEMA_VERSION,
        reports: []
      };
      return fallbackIndex;
    }
  }

  private addReportToIndex(report: TrainingReport): void {
    const indexFile: TrainingReportIndexFile = this.readIndex();
    indexFile.schemaVersion = SCHEMA_VERSION;
    const item: TrainingReportIndexItem = {
      id: report.id,
      startedAt: report.startedAt,
      endedAt: report.endedAt,
      durationSec: report.durationSec,
      sampleCount: report.sampleCount,
      averageHeartRate: report.averageHeartRate,
      maxHeartRate: report.maxHeartRate,
      mode: report.mode ?? 'offline'
    };
    indexFile.reports.unshift(item);
    while (indexFile.reports.length > 50) {
      indexFile.reports.pop();
    }
    this.writeText(this.indexPath, JSON.stringify(indexFile));
  }

  private updateHeartStats(sample: OfflineRawSample): void {
    const heartRate: number = sample.heartRate;
    if (heartRate <= 0 || heartRate >= 255) {
      return;
    }

    const session: OfflineSessionState = this.currentSession as OfflineSessionState;
    session.heartSum += heartRate;
    session.heartCount += 1;
    session.maxHeartRate = Math.max(session.maxHeartRate, heartRate);
    if (session.minHeartRate === 0) {
      session.minHeartRate = heartRate;
    } else {
      session.minHeartRate = Math.min(session.minHeartRate, heartRate);
    }

    const point: ChartPoint = {
      offsetSec: Math.floor((sample.timestamp - session.startedAt) / 1000),
      value: heartRate
    };
    this.pushLimitedHeartPoint(session, point);
  }

  private updateGpsStats(sample: OfflineRawSample): void {
    const longitude: number = sample.gps.longitude;
    const latitude: number = sample.gps.latitude;
    if (longitude === 0 || latitude === 0) {
      return;
    }

    const session: OfflineSessionState = this.currentSession as OfflineSessionState;
    if (session.lastLongitude !== null && session.lastLatitude !== null) {
      session.distanceMeter += this.distanceBetween(
        session.lastLatitude,
        session.lastLongitude,
        latitude,
        longitude
      );
    }
    session.lastLongitude = longitude;
    session.lastLatitude = latitude;
  }

  private pushLimitedHeartPoint(session: OfflineSessionState, point: ChartPoint): void {
    if (session.heartSeries.length > 0) {
      const lastPoint: ChartPoint = session.heartSeries[session.heartSeries.length - 1];
      if (point.offsetSec - lastPoint.offsetSec < CHART_SAMPLE_INTERVAL_SEC) {
        return;
      }
    }
    session.heartSeries.push(point);
    while (session.heartSeries.length > MAX_CHART_POINTS) {
      session.heartSeries.shift();
    }
  }

  private updateTiltStats(sample: OfflineRawSample): void {
    const imu: OfflineImuSample | string = sample.imu;
    if (typeof imu === 'string') {
      return;
    }
    const roll: number = imu.angle.roll;
    const session: OfflineSessionState = this.currentSession as OfflineSessionState;
    session.tiltSum += roll;
    session.tiltCount += 1;
    if (Math.abs(roll) > Math.abs(session.maxTilt)) {
      session.maxTilt = roll;
    }

    const point: ChartPoint = {
      offsetSec: Math.floor((sample.timestamp - session.startedAt) / 1000),
      value: roll
    };
    this.pushLimitedTiltPoint(session, point);
  }

  private restoreSignedTiltStats(report: TrainingReport): void {
    let tiltSum: number = 0;
    let peakTilt: number = 0;
    for (let i: number = 0; i < report.tiltSeries.length; i++) {
      const tilt: number = report.tiltSeries[i].value;
      tiltSum += tilt;
      if (Math.abs(tilt) > Math.abs(peakTilt)) {
        peakTilt = tilt;
      }
    }
    report.averageTilt = Math.round(tiltSum / report.tiltSeries.length * 10) / 10;
    report.maxTilt = Math.round(peakTilt * 10) / 10;
  }

  private pushLimitedTiltPoint(session: OfflineSessionState, point: ChartPoint): void {
    if (session.tiltSeries.length > 0) {
      const lastPoint: ChartPoint = session.tiltSeries[session.tiltSeries.length - 1];
      if (point.offsetSec - lastPoint.offsetSec < CHART_SAMPLE_INTERVAL_SEC) {
        return;
      }
    }
    session.tiltSeries.push(point);
    while (session.tiltSeries.length > MAX_CHART_POINTS) {
      session.tiltSeries.shift();
    }
  }

  private distanceBetween(lat1: number, lon1: number, lat2: number, lon2: number): number {
    const earthRadius: number = 6371000;
    const dLat: number = this.toRadians(lat2 - lat1);
    const dLon: number = this.toRadians(lon2 - lon1);
    const radLat1: number = this.toRadians(lat1);
    const radLat2: number = this.toRadians(lat2);
    const a: number =
      Math.sin(dLat / 2) * Math.sin(dLat / 2) +
        Math.cos(radLat1) * Math.cos(radLat2) *
          Math.sin(dLon / 2) * Math.sin(dLon / 2);
    const c: number = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return earthRadius * c;
  }

  private toRadians(degrees: number): number {
    return degrees * Math.PI / 180;
  }
}
