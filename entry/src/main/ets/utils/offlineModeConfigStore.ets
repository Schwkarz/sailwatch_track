import { fileIo } from '@kit.CoreFileKit';
import { BlePreferenceMode, MonitorDisplayMetric } from './onlineTrainingConfigStore';

const CONFIG_SCHEMA_VERSION: number = 2;

export interface OfflineModeConfig {
  schemaVersion: number;
  bleMode: BlePreferenceMode;
  bleMac: string;
  bleName: string;
  tiltAverageSeconds: number;
  monitorDisplayMetric: MonitorDisplayMetric;
}

export class OfflineModeConfigStore {
  private configPath: string = '';

  public setup(filesDir: string): void {
    this.configPath = `${filesDir}/offline_mode_config.json`;
    if (!this.pathExists(this.configPath)) {
      this.writeText('');
    }
  }

  public read(): OfflineModeConfig | null {
    if (this.configPath.length === 0 || !this.pathExists(this.configPath)) {
      return null;
    }
    try {
      const text: string = fileIo.readTextSync(this.configPath).trim();
      if (text.length === 0) {
        return null;
      }
      const config: OfflineModeConfig = JSON.parse(text) as OfflineModeConfig;
      if (config.schemaVersion === 1) {
        config.schemaVersion = CONFIG_SCHEMA_VERSION;
        config.monitorDisplayMetric = 'speed';
      }
      return this.isValid(config) ? config : null;
    } catch (error) {
      console.error(`read offline mode config failed: ${JSON.stringify(error)}`);
      return null;
    }
  }

  public write(config: OfflineModeConfig): void {
    if (this.configPath.length === 0) {
      return;
    }
    const normalized: OfflineModeConfig = {
      schemaVersion: CONFIG_SCHEMA_VERSION,
      bleMode: config.bleMode,
      bleMac: config.bleMac,
      bleName: config.bleName,
      tiltAverageSeconds: config.tiltAverageSeconds,
      monitorDisplayMetric: config.monitorDisplayMetric
    };
    this.writeText(JSON.stringify(normalized));
  }

  private isValid(config: OfflineModeConfig): boolean {
    return config !== null && config.schemaVersion === CONFIG_SCHEMA_VERSION &&
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
