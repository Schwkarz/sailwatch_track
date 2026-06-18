import { fileIo } from '@kit.CoreFileKit';

const SCHEMA_VERSION: number = 1;
const MAX_CHART_POINTS: number = 120;

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
  speed: number;
  headingT: number | null;
  accuracy: number;
}

export interface OfflineRawSample {
  schemaVersion: number;
  timestamp: number;
  heartRate: number;
  gps: OfflineGpsSample;
  imu: OfflineImuSample;
}

export interface ChartPoint {
  offsetSec: number;
  value: number;
}

export interface GpsPoint {
  longitude: number;
  latitude: number;
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
  distanceMeter: number;
  rawDataPath: string;
  heartSeries: ChartPoint[];
  gpsTrack: GpsPoint[];
}

export interface TrainingReportIndexItem {
  id: string;
  startedAt: number;
  endedAt: number;
  durationSec: number;
  sampleCount: number;
  averageHeartRate: number;
  maxHeartRate: number;
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
  distanceMeter: number;
  lastLongitude: number | null;
  lastLatitude: number | null;
  heartSeries: ChartPoint[];
  gpsTrack: GpsPoint[];
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

  public startSession(startedAt: number): string {
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
      distanceMeter: 0,
      lastLongitude: null,
      lastLatitude: null,
      heartSeries: [],
      gpsTrack: []
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
      distanceMeter: Math.round(session.distanceMeter),
      rawDataPath: session.rawDataPath,
      heartSeries: session.heartSeries,
      gpsTrack: session.gpsTrack
    };

    this.writeText(this.getReportPath(session.id), JSON.stringify(report));
    this.addReportToIndex(report);
    this.currentSession = null;
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
      return JSON.parse(text) as TrainingReport;
    } catch (error) {
      console.error(`read offline report failed: ${JSON.stringify(error)}`);
      return null;
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
    const item: TrainingReportIndexItem = {
      id: report.id,
      startedAt: report.startedAt,
      endedAt: report.endedAt,
      durationSec: report.durationSec,
      sampleCount: report.sampleCount,
      averageHeartRate: report.averageHeartRate,
      maxHeartRate: report.maxHeartRate
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

    const point: GpsPoint = {
      longitude: longitude,
      latitude: latitude
    };
    this.pushLimitedGpsPoint(session, point);
  }

  private pushLimitedHeartPoint(session: OfflineSessionState, point: ChartPoint): void {
    session.heartSeries.push(point);
    while (session.heartSeries.length > MAX_CHART_POINTS) {
      session.heartSeries.shift();
    }
  }

  private pushLimitedGpsPoint(session: OfflineSessionState, point: GpsPoint): void {
    session.gpsTrack.push(point);
    while (session.gpsTrack.length > MAX_CHART_POINTS) {
      session.gpsTrack.shift();
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
