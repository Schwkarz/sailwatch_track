import { fileIo } from '@kit.CoreFileKit';

const CONFIG_SCHEMA_VERSION: number = 4;

export type BlePreferenceMode = 'unconfigured' | 'device' | 'skip';
export type MonitorDisplayMetric = 'heartRate' | 'speed' | 'tilt' | 'heading';

export interface OnlineTrainingConfig {
  schemaVersion: number;
  windBoatSource: number;
  levelId: string;
  groupId: string;
  mhmId: string;
  mhmName: string;
  groupColor: string;
  bleMode: BlePreferenceMode;
  bleMac: string;
  bleName: string;
  tiltAverageSeconds: number;
  monitorDisplayMetric: MonitorDisplayMetric;
}

export class OnlineTrainingConfigStore {
  private configPath: string = '';

  public setup(filesDir: string): void {
    this.configPath = `${filesDir}/online_training_config.json`;
    if (!this.pathExists(this.configPath)) {
      this.writeText('');
    }
  }

  public read(): OnlineTrainingConfig | null {
    if (this.configPath.length === 0 || !this.pathExists(this.configPath)) {
      return null;
    }
    try {
      const text: string = fileIo.readTextSync(this.configPath).trim();
      if (text.length === 0) {
        return null;
      }
      const parsed = JSON.parse(text) as OnlineTrainingConfig;
      const oldSchemaVersion: number = parsed.schemaVersion;
      if (oldSchemaVersion === 1) {
        parsed.bleMode = 'unconfigured';
        parsed.bleMac = '';
        parsed.bleName = '';
      }
      if (oldSchemaVersion === 1 || oldSchemaVersion === 2) {
        parsed.tiltAverageSeconds = 60;
      }
      if (oldSchemaVersion >= 1 && oldSchemaVersion <= 3) {
        parsed.schemaVersion = CONFIG_SCHEMA_VERSION;
        parsed.monitorDisplayMetric = 'speed';
      }
      return this.isValid(parsed) ? parsed : null;
    } catch (error) {
      console.error(`read online training config failed: ${JSON.stringify(error)}`);
      return null;
    }
  }

  public write(config: OnlineTrainingConfig): void {
    if (this.configPath.length === 0) {
      return;
    }
    const normalized: OnlineTrainingConfig = {
      schemaVersion: CONFIG_SCHEMA_VERSION,
      windBoatSource: config.windBoatSource,
      levelId: config.levelId,
      groupId: config.groupId,
      mhmId: config.mhmId,
      mhmName: config.mhmName,
      groupColor: config.groupColor,
      bleMode: config.bleMode,
      bleMac: config.bleMac,
      bleName: config.bleName,
      tiltAverageSeconds: config.tiltAverageSeconds,
      monitorDisplayMetric: config.monitorDisplayMetric
    };
    this.writeText(JSON.stringify(normalized));
  }

  public clear(): void {
    if (this.configPath.length > 0) {
      this.writeText('');
    }
  }

  private isValid(config: OnlineTrainingConfig): boolean {
    return config !== null &&
      config.schemaVersion === CONFIG_SCHEMA_VERSION &&
      config.windBoatSource >= 1 && config.windBoatSource <= 5 &&
      config.levelId.length > 0 &&
      config.groupId.length > 0 &&
      config.mhmId.length > 0 &&
      config.mhmName.length > 0 &&
      config.groupColor.length > 0 &&
      (config.tiltAverageSeconds === 1 || config.tiltAverageSeconds === 30 ||
        config.tiltAverageSeconds === 60) &&
      this.isValidDisplayMetric(config.monitorDisplayMetric) &&
      (config.bleMode === 'unconfigured' || config.bleMode === 'skip' ||
        (config.bleMode === 'device' && config.bleMac.length > 0));
  }

  private isValidDisplayMetric(metric: MonitorDisplayMetric): boolean {
    return metric === 'heartRate' || metric === 'speed' || metric === 'tilt' || metric === 'heading';
  }

  private pathExists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (error) {
      return false;
    }
  }

  private writeText(text: string): void {
    const file = fileIo.openSync(
      this.configPath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC
    );
    try {
      fileIo.writeSync(file.fd, text);
    } finally {
      fileIo.closeSync(file);
    }
  }
}
