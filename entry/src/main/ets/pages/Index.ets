import { abilityAccessCtrl, common, PermissionRequestResult ,Permissions } from '@kit.AbilityKit';
import { sensor } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import window from '@ohos.window';
import { geoLocationManager } from '@kit.LocationKit';
import http from '@ohos.net.http';
import { JSON } from '@kit.ArkTS';
import { display } from '@kit.ArkUI';
import { notificationManager } from '@kit.NotificationKit'

import {BleManagement, wt_SensorData, BleDeviceItem} from '../utils/bluetoothManage'
import {MqttManagement, mqttUploadData, get_level, level_rec, get_group, group_rec, sailboat_data, original_data, WindDataMessage} from '../utils/mqtt'
import {DataUploader, UploadData, ble_SensorData} from '../utils/updataloader'
import {
  OfflineTrainingStore,
  OfflineRawSample,
  OfflineImuSample,
  ChartPoint,
  TrainingReport,
  TrainingReportIndexItem
} from '../utils/offlineTrainingStore'
import {
  OnlineTrainingConfig,
  OnlineTrainingConfigStore,
  BlePreferenceMode
} from '../utils/onlineTrainingConfigStore'
import {
  OfflineModeConfig,
  OfflineModeConfigStore
} from '../utils/offlineModeConfigStore'

//是否为测试环境
const is_test: boolean = false;
//租户编码
let tenantCode: number = -1;
//生产环境租户编码
const product_tenantCode: number = 1023;
//测试环境租户编码
const test_tenantCode: number = 1188;
//url
let user_url: string = ""
//测试地址url
const test_url: string = "180.107.109.102"
//生产地址url
const product_url: string = "221.229.219.18"

//地磁偏移
const declination: number = -3.8;
//姿态阈值
const postureThreshold: number = 1;
//俯仰姿态阈值
const pitchpostureThreshold: number = 2;
//gps精度阈值
const gps_accuracy_set: number = 20;
//选择教练艇
let windBoatsource: number = -1;

//测试延时用
let now_time: number = 0;
let dur_time: number = 0;

//测试gps更新次数
let location_change: number = 0;

//gps定时器
let gpsTimer: number | undefined = undefined;

let last_wind: WindDataMessage | undefined = undefined;
let last_last_wind: WindDataMessage | undefined = undefined;

const APP_MODE_UNSELECTED: number = 0;
const APP_MODE_SERVER: number = 1;
const APP_MODE_OFFLINE: number = 2;


// 在接口定义部分添加新的状态类型
interface LevelButton {
  levelId: string;
  levelName: string;
  selected: boolean;
}

interface GroupButton {
  groupId: string;
  mhmName: string;
  mhmId: string;
  selected: boolean;
  color: string;
}

// 数据容量测试结果类型
interface ITestResult {
  success: boolean;
  sizeKB: number;
  duration?: number;    // 成功时存在
  error?: string;          // 失败时存在
}

interface uploadCap {
  payload: string;
  timestamp: number;
}

// 数据生成工具（手表端）
function generateTestData(sizeKB: number): string {
  const char = 'A';
  return char.repeat(sizeKB * 1024); // 生成指定大小的字符串
}

// 生成12位随机数字
function generateRandomNum(length: number = 12): string {
  return new Array(length).fill(0).map(() => Math.floor(Math.random() * 10)).join('');
}

// 定义一个发布通知的函数
function sendNotification() {
  const id = Date.now(); // 唯一ID
  const notificationRequest: notificationManager.NotificationRequest = {
    id,
    content: {
      notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
      normal: {
        title: "通知",
        text: "这是一个通知",
        additionalText: "触发时间：" + new Date().toLocaleTimeString()
      }
    }
  };

  notificationManager.publish(notificationRequest, (err: BusinessError) => {
    if (err) {
      console.error(`发布通知失败，错误码: ${err.code}, 信息: ${err.message}`);
    } else {
      console.info("通知发布成功");

      // 1 秒后自动取消
      setTimeout(() => {
        notificationManager.cancel(id, (cancelErr: BusinessError) => {
          if (cancelErr) {
            console.error(`取消通知失败: ${cancelErr.code}, ${cancelErr.message}`);
          } else {
            console.info("通知已自动取消");
          }
        });
      }, 200);
    }
  });
}

// 定义一个定时器，每隔 1 秒检查一次屏幕状态
function startTimerNotification(interval: number = 1000): number {
  return setInterval(() => {
    // console.log("notification catch started")
    display.getAllDisplays((err: BusinessError, data: Array<display.Display>) => {
      const errCode: number = err.code;
      if (errCode) {
        console.error(`Failed to obtain all the display objects. Code: ${err.code}, message: ${err.message}`);
        return;
      }
      if(data && data.length > 0){
        if(data[0].state == 1){
          sendNotification();
        }
      }else {
        console.error('no displaydata')
        return;
      }
      // console.info(`Succeeded in obtaining all the display objects. Data: ${JSON.stringify(data[0].state)}`);
    });




  }, interval);
}

let requestEnableNotificationCallback = (err: BusinessError): void => {
  if (err) {
    console.error(`requestEnableNotification failed, code is ${err.code}, message is ${err.message}`);
  } else {
    console.info(`requestEnableNotification success`);
  }
};

@Entry
@Component
struct Index {

  // 添加 Navigation 控制器
  @State pageStack: NavPathStack = new NavPathStack();
  @State hasInitiatedJump: boolean = false;

  check_test(): void{
    if(is_test){
      tenantCode = test_tenantCode;
      user_url = test_url;
    }else{
      tenantCode = product_tenantCode;
      user_url = product_url;
    }
  }

  @State heartRate: number = 0;
  @State location: Array<number> = [0,0]; //[0]经度 [1]纬度
  @State headingT: number | null = null;
  @State gps_accuracy: number = 0;
  sensor_data: Array<number> = [0,0,0,0,0,0]; //x,y,z加速度
  @State speed: number = 0;
  //上传数据的定时器变量
  @State uploadTimer: number | undefined = undefined;
  @State uploadTimer_buffer: number | undefined = undefined;
  @State uploadInterval: number = 100; // 100ms上传一次

  //监测网络状态定时器
  @State checkTimer: number | undefined = undefined;
  //Mqtt上传定时器
  @State MqttTimer: number | undefined = undefined;
  @State notificationTimer: number | undefined = undefined;

  @State sensorInterval: number = 50000000; //加速度传感器读取间隔 ns
  @State heartInterval: number = 1000000000; //心率读取间隔 ns

  //显示网络连接状态
  @State isConnected: boolean = false;
  @State connectionStatusColor: Color = Color.Red
  @State isbleConnected: boolean = false
  @State bleconnectionStatusColor: Color = Color.Red

  //显示上传状态
  @State isStartUpload: boolean = false;
  @State buttonString: string = '开始记录'

  dataUploader: DataUploader = new DataUploader();
  @State dataQueueLength : number = 0;

  @State isLongPressing: boolean = false; // 是否正在长按
  @State longPressTimer: number | undefined = undefined; // 长按计时器
  @State longPressProgress: number = 0; // 长按进度（0-100）
  private longPressDuration: number = 2000; // 长按持续时间3秒

  // 在Index组件中添加冷却时间状态
  @State isCoolingDown: boolean = false; // 冷却状态
  @State coolDownTimer: number | undefined = undefined; // 冷却计时器
  private coolDownDuration: number = 1000; // 冷却时间1秒

  @State levelButtons: LevelButton[] = [];
  @State groupButtons: GroupButton[] = [];
  @State selectedLevelId: string = '';
  @State selectedGroupId: string = '';
  @State selectedmhmName: string = '';
  @State selectedmhmId: string = '';
  @State isLoading: boolean = false;
  @State selectedGroupColor: string = "#000000"; //默认黑色

  @State button_size: number = 60;

  @State appMode: number = APP_MODE_UNSELECTED;
  @State bleDevices: BleDeviceItem[] = [];
  @State isBleScanning: boolean = false;
  @State selectedBleDeviceName: string = '';
  @State selectedBleDeviceId: string = '';
  @State selectedBleMac: string = '';
  @State bleScanStatus: string = '未扫描';
  @State isPermissionRequestCompleted: boolean = false;
  @State hasBluetoothPermission: boolean = false;

  @State isOfflineRecording: boolean = false;
  @State offlineButtonString: string = '开始';
  @State offlineSampleCount: number = 0;
  @State offlineElapsedSeconds: number = 0;
  @State recentTiltAverage: number = 0;
  @State hasRecentTiltData: boolean = false;
  @State offlineStatus: string = '未开始';
  @State offlineRecordTimer: number | undefined = undefined;
  @State offlineTiltDisplayTimer: number | undefined = undefined;
  @State offlineLongPressTimer: number | undefined = undefined;
  @State isOfflineLongPressing: boolean = false;
  @State offlineLongPressProgress: number = 0;
  @State offlineReports: TrainingReportIndexItem[] = [];
  @State selectedReport: TrainingReport | null = null;
  @State pendingDeleteReportId: string = '';
  @State offlineTiltAverageSeconds: number = 60;

  offlineStore: OfflineTrainingStore = new OfflineTrainingStore();
  onlineConfigStore: OnlineTrainingConfigStore = new OnlineTrainingConfigStore();
  offlineModeConfigStore: OfflineModeConfigStore = new OfflineModeConfigStore();
  private hasSetupBleCallbacks: boolean = false;
  private isBleSelectionVisible: boolean = false;
  private offlineStartedAt: number = 0;
  private recentTiltValues: number[] = [];
  private offlineLongPressDuration: number = 2000;
  private offlineStopCompletedByLongPress: boolean = false;
  private blePreferenceMode: BlePreferenceMode = 'unconfigured';
  private pendingPreferredBleMac: string = '';
  private isChangingOfflineBle: boolean = false;
  private isChangingOnlineBle: boolean = false;


  @Builder
  PagesMap(name: string) {
    if (name == 'ModeSelection') {
      this.modeSelectionBuilder('ModeSelection')
    }else if (name == 'BleDeviceSelection') {
      this.bleDeviceSelectionBuilder('BleDeviceSelection')
    }else if (name == 'OfflineInterface') {
      this.offlineInterfaceBuilder('OfflineInterface')
    }else if (name == 'OfflineSettings') {
      this.offlineSettingsBuilder('OfflineSettings')
    }else if (name == 'OnlineSettings') {
      this.onlineSettingsBuilder('OnlineSettings')
    }else if (name == 'OfflineHistory') {
      this.offlineHistoryBuilder('OfflineHistory')
    }else if (name == 'OfflineReportDetail') {
      this.offlineReportDetailBuilder('OfflineReportDetail')
    }else if (name == 'WindInterfaceBuilder') {
      this.WindInterfaceBuilder('WindInterfaceBuilder');
    }else if(name == 'LevelSelection'){
      this.levelSelectionBuilder('LevelSelection');
    }else if(name == 'GroupSelection'){
      this.groupSelectionBuilder('GroupSelection')
    }else if(name == 'LoadInterface'){
      this.loadInterfaceBuilder('LoadInterface')
    }else if(name == 'test'){
      this.testBuilder('test')
    }
  }

  build() {
    Navigation(this.pageStack) {

    }
    .width('100%')
    .height('100%')
    .navDestination(this.PagesMap)
    .hideNavBar(true)
    .hideTitleBar(true)
    .hideBackButton(true)
    .hideToolBar(true)
  }

  // 页面跳转方法
  pushPage(pageName: string, param?: Object) {
    this.pageStack.pushPathByName(pageName, param, false);
  }

  popPage() {
    this.pageStack.pop();
  }

  private getAbilityContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private setupBleCallbacks(): void {
    if (this.hasSetupBleCallbacks) {
      return;
    }
    this.hasSetupBleCallbacks = true;
    this.wtBLE.setDeviceDiscoveryCallback((devices: BleDeviceItem[]) => {
      this.bleDevices = devices;
      for (let i: number = 0; i < devices.length; i++) {
        const device: BleDeviceItem = devices[i];
        if (device.deviceId === this.selectedBleDeviceId && device.macAddress.length > 0) {
          this.selectedBleMac = device.macAddress;
        }
        if (this.pendingPreferredBleMac.length > 0 &&
          device.macAddress.toUpperCase() === this.pendingPreferredBleMac.toUpperCase()) {
          this.pendingPreferredBleMac = '';
          this.selectedBleDeviceId = device.deviceId;
          this.selectedBleDeviceName = device.deviceName;
          this.selectedBleMac = device.macAddress;
          this.bleScanStatus = `自动连接 ${device.deviceName}`;
          this.wtBLE.connectDevice(device.deviceId, device.deviceName);
          break;
        }
      }
      if (devices.length === 0) {
        this.bleScanStatus = this.isBleScanning ? '正在搜索 WT901' : '未发现设备';
      } else {
        this.bleScanStatus = `发现 ${devices.length} 个 WT901`;
      }
    });
    this.wtBLE.setOnConnectCallback(() => {
      this.isbleConnected = true;
      this.bleconnectionStatusColor = Color.Green;
      this.isBleScanning = false;
      this.bleScanStatus = '已连接';
    });
    this.wtBLE.setOnDisconnectCallback(() => {
      this.isbleConnected = false;
      this.bleconnectionStatusColor = Color.Red;
      this.hasRecentTiltData = false;
      this.bleScanStatus = '已断开';
    });
  }

  selectServerMode(): void {
    this.appMode = APP_MODE_SERVER;
    const config: OnlineTrainingConfig | null = this.onlineConfigStore.read();
    if (config !== null) {
      this.applyOnlineTrainingConfig(config);
      if (config.bleMode === 'unconfigured') {
        this.pushPage('BleDeviceSelection');
      } else {
        this.pushPage('LoadInterface');
        this.connectWatchMqtt();
        this.applySavedBlePreference(config.bleMode, config.bleMac, config.bleName);
      }
    } else {
      this.pushPage('WindInterfaceBuilder');
    }
  }

  applyOnlineTrainingConfig(config: OnlineTrainingConfig): void {
    windBoatsource = config.windBoatSource;
    this.selectedLevelId = config.levelId;
    this.selectedGroupId = config.groupId;
    this.selectedmhmId = config.mhmId;
    this.selectedmhmName = config.mhmName;
    this.selectedGroupColor = config.groupColor;
    this.mygroup.data[0].groupId = config.groupId;
    this.mygroup.data[0].mhmId = config.mhmId;
    this.mygroup.data[0].mhmName = config.mhmName;
    this.mygroup.data[0].color = config.groupColor;
    this.blePreferenceMode = config.bleMode;
    this.selectedBleMac = config.bleMac;
    this.selectedBleDeviceName = config.bleName;
    this.offlineTiltAverageSeconds = config.tiltAverageSeconds;
  }

  saveOnlineTrainingConfig(): void {
    const config: OnlineTrainingConfig = {
      schemaVersion: 3,
      windBoatSource: windBoatsource,
      levelId: this.selectedLevelId,
      groupId: this.selectedGroupId,
      mhmId: this.selectedmhmId,
      mhmName: this.selectedmhmName,
      groupColor: this.selectedGroupColor,
      bleMode: this.blePreferenceMode,
      bleMac: this.selectedBleMac,
      bleName: this.selectedBleDeviceName,
      tiltAverageSeconds: this.offlineTiltAverageSeconds
    };
    try {
      this.onlineConfigStore.write(config);
    } catch (error) {
      console.error(`保存在线训练配置失败: ${JSON.stringify(error)}`);
    }
  }

  async openOnlineSettings(): Promise<void> {
    if (this.isStartUpload) {
      return;
    }
    this.wtBLE.disconnect();
    this.pendingPreferredBleMac = '';
    this.selectedBleDeviceId = '';
    this.selectedBleDeviceName = '';
    this.selectedBleMac = '';
    this.isbleConnected = false;
    this.bleconnectionStatusColor = Color.Gray;
    this.hasRecentTiltData = false;
    try {
      this.onlineConfigStore.clear();
      await this.mqttManager.disconnect();
      this.mqttManager.clearSubscriptions();
    } catch (error) {
      console.error(`重置在线训练配置失败: ${JSON.stringify(error)}`);
    }
    this.isConnected = false;
    this.connectionStatusColor = Color.Gray;
    windBoatsource = -1;
    this.selectedLevelId = '';
    this.selectedGroupId = '';
    this.selectedmhmId = '';
    this.selectedmhmName = '';
    this.selectedGroupColor = '#000000';
    this.blePreferenceMode = 'unconfigured';
    this.selectedBleMac = '';
    this.selectedBleDeviceName = '';
    this.pushPage('WindInterfaceBuilder');
  }

  openOnlineMenu(): void {
    if (this.isStartUpload || this.isOfflineRecording) {
      return;
    }
    this.pushPage('OnlineSettings');
  }

  selectOfflineMode(): void {
    this.appMode = APP_MODE_OFFLINE;
    windBoatsource = -1;
    const config: OfflineModeConfig | null = this.offlineModeConfigStore.read();
    if (config === null || config.bleMode === 'unconfigured') {
      this.pushPage('BleDeviceSelection');
      return;
    }
    this.applyOfflineModeConfig(config);
    this.pushPage('OfflineInterface');
    this.applySavedBlePreference(config.bleMode, config.bleMac, config.bleName);
  }

  applySavedBlePreference(mode: BlePreferenceMode, macAddress: string, deviceName: string): void {
    this.blePreferenceMode = mode;
    this.selectedBleDeviceName = deviceName;
    this.selectedBleMac = macAddress;
    this.selectedBleDeviceId = '';
    this.pendingPreferredBleMac = '';
    this.isbleConnected = false;
    if (mode === 'skip') {
      this.bleconnectionStatusColor = Color.Gray;
      this.bleScanStatus = '已按配置跳过姿态传感器';
      return;
    }
    if (mode === 'device' && macAddress.length > 0) {
      this.bleconnectionStatusColor = Color.Red;
      this.pendingPreferredBleMac = macAddress;
      this.bleScanStatus = `正在查找 ${deviceName}`;
      this.startBleDeviceScan();
    }
  }

  applyOfflineModeConfig(config: OfflineModeConfig): void {
    this.blePreferenceMode = config.bleMode;
    this.selectedBleMac = config.bleMac;
    this.selectedBleDeviceName = config.bleName;
    this.offlineTiltAverageSeconds = config.tiltAverageSeconds;
  }

  saveOfflineModeConfig(): void {
    const config: OfflineModeConfig = {
      schemaVersion: 1,
      bleMode: this.blePreferenceMode,
      bleMac: this.selectedBleMac,
      bleName: this.selectedBleDeviceName,
      tiltAverageSeconds: this.offlineTiltAverageSeconds
    };
    try {
      this.offlineModeConfigStore.write(config);
    } catch (error) {
      console.error(`保存离线模式配置失败: ${JSON.stringify(error)}`);
    }
  }

  startBleDeviceScan(): void {
    this.setupBleCallbacks();
    if (!this.isPermissionRequestCompleted) {
      this.isBleScanning = false;
      this.bleScanStatus = '等待蓝牙权限';
      return;
    }
    if (!this.hasBluetoothPermission) {
      this.isBleScanning = false;
      this.bleScanStatus = '未获得蓝牙权限';
      return;
    }
    if (this.wtBLE.isConnected()) {
      this.wtBLE.disconnect();
      this.selectedBleDeviceId = '';
      this.isbleConnected = false;
      this.bleconnectionStatusColor = Color.Red;
      this.hasRecentTiltData = false;
      this.bleScanStatus = '已断开原传感器，正在重新扫描';
    }
    this.bleDevices = [];
    this.bleScanStatus = '正在搜索 WT901';
    this.isBleScanning = this.wtBLE.startWt901DeviceScan();
    if (!this.isBleScanning) {
      this.bleScanStatus = '扫描失败，请检查蓝牙';
    }
  }

  stopBleDeviceScan(): void {
    this.wtBLE.stopDeviceScan();
    this.isBleScanning = false;
    this.bleScanStatus = this.bleDevices.length > 0 ? `发现 ${this.bleDevices.length} 个 WT901` : '已停止';
  }

  selectBleDevice(item: BleDeviceItem): void {
    this.selectedBleDeviceId = item.deviceId;
    this.selectedBleDeviceName = item.deviceName;
    this.selectedBleMac = item.macAddress;
    this.isbleConnected = false;
    this.bleconnectionStatusColor = Color.Red;
    this.bleScanStatus = `连接 ${item.deviceName}`;
    this.isBleScanning = false;
    const connecting: boolean = this.wtBLE.connectDevice(item.deviceId, item.deviceName);
    if (!connecting) {
      this.bleScanStatus = '连接失败，请重试';
    }
  }

  onBleSelectionAppear(): void {
    this.isBleSelectionVisible = true;
    this.startBleDeviceScan();
  }

  onBleSelectionDisappear(): void {
    this.isBleSelectionVisible = false;
    this.stopBleDeviceScan();
  }

  enterAfterBleSelected(): void {
    if (this.selectedBleDeviceId.length === 0 || !this.isbleConnected || this.selectedBleMac.length === 0) {
      return;
    }
    this.blePreferenceMode = 'device';
    this.stopBleDeviceScan();
    if (this.appMode === APP_MODE_SERVER) {
      this.saveOnlineTrainingConfig();
      if (this.isChangingOnlineBle) {
        this.isChangingOnlineBle = false;
        this.popPage();
        this.popPage();
      } else {
        this.pushPage('LoadInterface');
        this.connectWatchMqtt();
      }
    } else if (this.appMode === APP_MODE_OFFLINE) {
      this.saveOfflineModeConfig();
      if (this.isChangingOfflineBle) {
        this.isChangingOfflineBle = false;
        this.popPage();
        this.popPage();
      } else {
        this.pushPage('OfflineInterface');
      }
    }
  }

  skipBleConnection(): void {
    if (this.appMode !== APP_MODE_SERVER && this.appMode !== APP_MODE_OFFLINE) {
      return;
    }
    this.stopBleDeviceScan();
    this.wtBLE.disconnect();
    this.selectedBleDeviceId = '';
    this.selectedBleDeviceName = '';
    this.selectedBleMac = '';
    this.blePreferenceMode = 'skip';
    this.isbleConnected = false;
    this.bleconnectionStatusColor = Color.Gray;
    this.hasRecentTiltData = false;
    this.bleScanStatus = '已跳过姿态传感器';
    if (this.appMode === APP_MODE_SERVER) {
      this.saveOnlineTrainingConfig();
      if (this.isChangingOnlineBle) {
        this.isChangingOnlineBle = false;
        this.popPage();
        this.popPage();
      } else {
        this.pushPage('LoadInterface');
        this.connectWatchMqtt();
      }
    } else {
      this.saveOfflineModeConfig();
      if (this.isChangingOfflineBle) {
        this.isChangingOfflineBle = false;
        this.popPage();
        this.popPage();
      } else {
        this.pushPage('OfflineInterface');
      }
    }
  }

  openOfflineHistory(): void {
    if (this.isOfflineRecording) {
      return;
    }
    this.refreshOfflineReports();
    this.pushPage('OfflineHistory');
  }

  openOfflineSettings(): void {
    if (this.isOfflineRecording) {
      return;
    }
    this.pushPage('OfflineSettings');
  }

  changeOfflineBleSensor(): void {
    if (this.isOfflineRecording) {
      return;
    }
    this.wtBLE.disconnect();
    this.selectedBleDeviceId = '';
    this.selectedBleDeviceName = '';
    this.selectedBleMac = '';
    this.isbleConnected = false;
    this.bleconnectionStatusColor = Color.Red;
    this.isChangingOfflineBle = true;
    this.pushPage('BleDeviceSelection');
  }

  changeOnlineBleSensor(): void {
    if (this.isStartUpload || this.isOfflineRecording) {
      return;
    }
    this.wtBLE.disconnect();
    this.selectedBleDeviceId = '';
    this.selectedBleDeviceName = '';
    this.selectedBleMac = '';
    this.isbleConnected = false;
    this.bleconnectionStatusColor = Color.Red;
    this.hasRecentTiltData = false;
    this.isChangingOnlineBle = true;
    this.pushPage('BleDeviceSelection');
  }

  setOfflineTiltAverageSeconds(seconds: number): void {
    if (seconds !== 1 && seconds !== 30 && seconds !== 60) {
      return;
    }
    this.offlineTiltAverageSeconds = seconds;
    this.recentTiltValues = [];
    this.recentTiltAverage = 0;
    this.hasRecentTiltData = false;
    if (this.appMode === APP_MODE_SERVER) {
      this.saveOnlineTrainingConfig();
    } else {
      this.saveOfflineModeConfig();
    }
  }

  getOfflineTiltWindowText(): string {
    if (this.offlineTiltAverageSeconds === 1) {
      return '实时';
    }
    if (this.offlineTiltAverageSeconds === 30) {
      return '30s';
    }
    return '1min';
  }

  startOfflineTiltDisplay(): void {
    this.stopOfflineTiltDisplay();
    this.refreshOfflineTiltDisplay();
    this.offlineTiltDisplayTimer = setInterval(() => {
      this.refreshOfflineTiltDisplay();
    }, 1000);
  }

  stopOfflineTiltDisplay(): void {
    if (this.offlineTiltDisplayTimer !== undefined) {
      clearInterval(this.offlineTiltDisplayTimer);
      this.offlineTiltDisplayTimer = undefined;
    }
  }

  refreshOfflineTiltDisplay(): void {
    if (this.isOfflineRecording) {
      return;
    }
    if (this.isOfflineSensorDataAvailable(Date.now())) {
      this.updateRecentTiltAverage(this.wtBLE.ble_sensorData.angle.roll);
      this.hasRecentTiltData = true;
    } else {
      this.recentTiltValues = [];
      this.recentTiltAverage = 0;
      this.hasRecentTiltData = false;
    }
  }

  refreshOfflineReports(): void {
    try {
      this.offlineReports = this.offlineStore.listReports();
    } catch (error) {
      console.error(`刷新离线报告失败: ${JSON.stringify(error)}`);
      this.offlineReports = [];
    }
  }

  openOfflineReport(id: string): void {
    const report: TrainingReport | null = this.offlineStore.readReport(id);
    if (report) {
      this.selectedReport = report;
      this.pushPage('OfflineReportDetail');
    }
  }

  requestDeleteOfflineReport(id: string): void {
    if (this.pendingDeleteReportId !== id) {
      this.pendingDeleteReportId = id;
      return;
    }
    const deleted: boolean = this.offlineStore.deleteReport(id);
    this.pendingDeleteReportId = '';
    if (deleted) {
      if (this.selectedReport !== null && this.selectedReport.id === id) {
        this.selectedReport = null;
      }
      this.refreshOfflineReports();
    }
  }

  @Builder
  testBuilder(name: string) {
    Column(){
      Text("123")
        .fontSize(50)
    }
    .width('100%')
    .height('100%') // 让 Column 占满父容器
    .backgroundColor(Color.White)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  modeSelectionBuilder(name: string) {
    NavDestination() {
      Column() {
        Text('训练模式')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .margin({ bottom: 20 })

        Button('连接服务器')
          .fontSize(16)
          .type(ButtonType.Capsule)
          .backgroundColor(0x317aff)
          .fontColor(Color.White)
          .width(150)
          .height(46)
          .margin({ bottom: 14 })
          .onClick(() => this.selectServerMode())

        Button('离线模式')
          .fontSize(16)
          .type(ButtonType.Capsule)
          .backgroundColor(0x2f9b67)
          .fontColor(Color.White)
          .width(150)
          .height(46)
          .margin({ bottom: 14 })
          .onClick(() => this.selectOfflineMode())

        Button('历史报告')
          .fontSize(14)
          .type(ButtonType.Capsule)
          .backgroundColor(0x555555)
          .fontColor(Color.White)
          .width(120)
          .height(38)
          .onClick(() => this.openOfflineHistory())
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(0x000000)
    }
    .hideTitleBar(true)
    .onBackPressed(() => true)
  }

  @Builder
  bleDeviceSelectionBuilder(name: string) {
    NavDestination() {
      Column() {
        Text('选择姿态传感器')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .margin({ top: 2, bottom: 3 })

        Text(this.bleScanStatus)
          .fontSize(10)
          .fontColor(Color.Gray)
          .margin({ bottom: 4 })

        Row() {
          Button(this.isBleScanning ? '扫描中' : '扫描')
            .fontSize(13)
            .type(ButtonType.Capsule)
            .backgroundColor(0x317aff)
            .fontColor(Color.White)
            .width(76)
            .height(28)
            .margin({ right: 6 })
            .onClick(() => this.startBleDeviceScan())

          Button('停止')
            .fontSize(13)
            .type(ButtonType.Capsule)
            .backgroundColor(0x555555)
            .fontColor(Color.White)
            .width(62)
            .height(28)
            .onClick(() => this.stopBleDeviceScan())
        }
        .margin({ bottom: 4 })

        Column() {
          if (this.bleDevices.length === 0) {
            Text('暂无 WT901 设备')
              .fontSize(11)
              .fontColor(Color.Gray)
              .margin({ top: 16 })
          } else {
            Scroll() {
              Column() {
                ForEach(this.bleDevices, (item: BleDeviceItem) => {
                  Column() {
                    Text(item.deviceName)
                      .fontSize(12)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Color.White)
                      .maxLines(1)
                    Text(item.macAddress.length > 0 ? `MAC ${item.macAddress}` : '')
                      .fontSize(8)
                      .fontColor(Color.Gray)
                      .maxLines(1)
                    Text(`RSSI ${item.rssi}`)
                      .fontSize(8)
                      .fontColor(0x9fc7ff)
                  }
                  .width('90%')
                  .height(48)
                  .justifyContent(FlexAlign.Center)
                  .alignItems(HorizontalAlign.Center)
                  .backgroundColor(item.deviceId === this.selectedBleDeviceId ? 0x245f9e : 0x222222)
                  .borderRadius(6)
                  .margin({ bottom: 5 })
                  .onClick(() => this.selectBleDevice(item))
                })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
            }
            .width('100%')
            .height('100%')
          }
        }
        .width('100%')
        .layoutWeight(1)

        Row() {
          Button(this.isbleConnected ? '进入' :
            (this.selectedBleDeviceId.length > 0 ? '连接中' : '请选择'))
            .fontSize(13)
            .type(ButtonType.Capsule)
            .backgroundColor(this.isbleConnected ? 0x2f9b67 : 0x555555)
            .fontColor(Color.White)
            .width(76)
            .height(28)
            .onClick(() => this.enterAfterBleSelected())

          Button('跳过')
            .fontSize(13)
            .type(ButtonType.Capsule)
            .backgroundColor(0x555555)
            .fontColor(Color.White)
            .width(62)
            .height(28)
            .margin({ left: 6 })
            .onClick(() => this.skipBleConnection())
        }
        .justifyContent(FlexAlign.Center)
        .margin({ top: 4, bottom: 2 })
      }
      .width('100%')
      .height('100%')
      .padding({ top: 6, bottom: 8, left: 10, right: 10 })
      .backgroundColor(0x000000)
    }
    .hideTitleBar(true)
    .onAppear(() => this.onBleSelectionAppear())
    .onDisAppear(() => this.onBleSelectionDisappear())
    .onBackPressed(() => {
      this.stopBleDeviceScan();
      this.popPage();
      return true;
    })
  }

  @Builder
  offlineInterfaceBuilder(name: string) {
    NavDestination() {
      Column() {
        Text('离线模式')
          .fontSize(8)
          .fontWeight(FontWeight.Bold)
          .fontColor(0x333333)
          .margin({ bottom: 5 })

        Row() {
          Text('姿态')
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
          Circle()
            .width(8)
            .height(8)
            .fill(this.bleconnectionStatusColor)
            .margin({ left: 5 })
        }
        .justifyContent(FlexAlign.Center)
        .margin({ bottom: 5 })

        Button('菜单')
          .fontSize(10)
          .type(ButtonType.Capsule)
          .backgroundColor(this.isOfflineRecording ? 0x333333 : 0x555555)
          .fontColor(Color.White)
          .width(72)
          .height(25)
          .enabled(!this.isOfflineRecording)
          .opacity(this.isOfflineRecording ? 0.45 : 1)
          .onClick(() => this.openOfflineSettings())

        Text(`${(this.speed * 1.94).toFixed(1)}`)
          .fontSize(80)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)

        Row() {
          Text(formatDuration(this.offlineElapsedSeconds))
            .fontSize(9)
            .fontColor(Color.White)
          Text(`${this.getOfflineTiltWindowText()}均倾 ${this.hasRecentTiltData ? this.formatSignedAngle(this.recentTiltAverage) : '---'}`)
            .fontSize(9)
            .fontColor(0x9fc7ff)
          Text(`心率 ${this.heartRate}`)
            .fontSize(9)
            .fontColor(0xff8b8b)
        }
          .width('90%')
          .justifyContent(FlexAlign.SpaceBetween)
          .margin({ bottom: 5 })

        Stack() {
          Button(this.isOfflineRecording ? '长按停止' : '开始记录')
            .fontSize(14)
            .type(ButtonType.Capsule)
            .backgroundColor(this.isOfflineRecording ? 0xd64c4c : 0x2f9b67)
            .fontColor(Color.White)
            .width(100)
            .height(35)
            .onClick(() => this.onOfflineButtonClick())
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                if (this.isOfflineRecording) {
                  this.startOfflineLongPressDetection();
                } else {
                  this.offlineStopCompletedByLongPress = false;
                }
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.stopOfflineLongPressDetection();
              }
            })

          if (this.isOfflineLongPressing && this.isOfflineRecording) {
            Progress({ value: this.offlineLongPressProgress, total: 100, type: ProgressType.Ring })
              .width(35)
              .height(35)
              .color(Color.Red)
              .backgroundColor(0x00000000)
          }
        }
        .width(126)
        .height(44)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(0x000000)
    }
    .hideTitleBar(true)
    .onAppear(() => this.startOfflineTiltDisplay())
    .onDisAppear(() => this.stopOfflineTiltDisplay())
    .onBackPressed(() => true)
  }

  @Builder
  offlineSettingsBuilder(name: string) {
    NavDestination() {
      Column() {
        Text('离线设置')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .margin({ bottom: 18 })

        Button('蓝牙传感器连接')
          .fontSize(13)
          .type(ButtonType.Capsule)
          .backgroundColor(0x317aff)
          .fontColor(Color.White)
          .width(150)
          .height(36)
          .margin({ bottom: 14 })
          .onClick(() => this.changeOfflineBleSensor())

        Text(`平均倾角时间：${this.getOfflineTiltWindowText()}`)
          .fontSize(11)
          .fontColor(0x9fc7ff)
          .margin({ bottom: 7 })

        Row() {
          Button('实时')
            .fontSize(10)
            .backgroundColor(this.offlineTiltAverageSeconds === 1 ? 0x2f9b67 : 0x555555)
            .width(55)
            .height(28)
            .onClick(() => this.setOfflineTiltAverageSeconds(1))
          Button('30s')
            .fontSize(10)
            .backgroundColor(this.offlineTiltAverageSeconds === 30 ? 0x2f9b67 : 0x555555)
            .width(55)
            .height(28)
            .margin({ left: 5, right: 5 })
            .onClick(() => this.setOfflineTiltAverageSeconds(30))
          Button('1min')
            .fontSize(10)
            .backgroundColor(this.offlineTiltAverageSeconds === 60 ? 0x2f9b67 : 0x555555)
            .width(55)
            .height(28)
            .onClick(() => this.setOfflineTiltAverageSeconds(60))
        }
        .margin({ bottom: 16 })

        Button('查看历史报告')
          .fontSize(13)
          .type(ButtonType.Capsule)
          .backgroundColor(0x555555)
          .fontColor(Color.White)
          .width(150)
          .height(36)
          .onClick(() => this.openOfflineHistory())
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(0x000000)
    }
    .hideTitleBar(true)
    .onBackPressed(() => {
      this.popPage();
      return true;
    })
  }

  @Builder
  onlineSettingsBuilder(name: string) {
    NavDestination() {
      Column() {
        Text('在线菜单')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .margin({ bottom: 12 })

        Button('蓝牙传感器连接')
          .fontSize(12)
          .type(ButtonType.Capsule)
          .backgroundColor(0x317aff)
          .fontColor(Color.White)
          .width(150)
          .height(32)
          .margin({ bottom: 10 })
          .onClick(() => this.changeOnlineBleSensor())

        Text(`平均倾角时间：${this.getOfflineTiltWindowText()}`)
          .fontSize(11)
          .fontColor(0x9fc7ff)
          .margin({ bottom: 6 })

        Row() {
          Button('实时')
            .fontSize(10)
            .backgroundColor(this.offlineTiltAverageSeconds === 1 ? 0x2f9b67 : 0x555555)
            .width(55)
            .height(27)
            .onClick(() => this.setOfflineTiltAverageSeconds(1))
          Button('30s')
            .fontSize(10)
            .backgroundColor(this.offlineTiltAverageSeconds === 30 ? 0x2f9b67 : 0x555555)
            .width(55)
            .height(27)
            .margin({ left: 5, right: 5 })
            .onClick(() => this.setOfflineTiltAverageSeconds(30))
          Button('1min')
            .fontSize(10)
            .backgroundColor(this.offlineTiltAverageSeconds === 60 ? 0x2f9b67 : 0x555555)
            .width(55)
            .height(27)
            .onClick(() => this.setOfflineTiltAverageSeconds(60))
        }
        .margin({ bottom: 10 })

        Button('查看历史报告')
          .fontSize(12)
          .type(ButtonType.Capsule)
          .backgroundColor(0x555555)
          .fontColor(Color.White)
          .width(150)
          .height(32)
          .margin({ bottom: 10 })
          .onClick(() => this.openOfflineHistory())

        Button('重新设置训练配置')
          .fontSize(11)
          .type(ButtonType.Capsule)
          .backgroundColor(0x7a3030)
          .fontColor(Color.White)
          .width(150)
          .height(30)
          .onClick(() => this.openOnlineSettings())
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(0x000000)
    }
    .hideTitleBar(true)
    .onBackPressed(() => {
      this.popPage();
      return true;
    })
  }

  @Builder
  offlineHistoryBuilder(name: string) {
    NavDestination() {
      Column() {
        Text('历史报告')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .margin({ top: 12, bottom: 10 })

        if (this.offlineReports.length === 0) {
          Text('暂无报告')
            .fontSize(14)
            .fontColor(Color.Gray)
            .margin({ top: 30 })
        } else {
          Scroll() {
            Column() {
              ForEach(this.offlineReports, (item: TrainingReportIndexItem) => {
                Row() {
                  Column() {
                    Text(`${item.mode === 'online' ? '在线' : '离线'} ${formatShortDateTime(item.startedAt)}`)
                      .fontSize(13)
                      .fontColor(Color.White)
                      .maxLines(1)
                    Text(`${formatDuration(item.durationSec)}  均心 ${item.averageHeartRate}`)
                      .fontSize(11)
                      .fontColor(Color.Gray)
                  }
                  .layoutWeight(1)
                  .height(52)
                  .justifyContent(FlexAlign.Center)
                  .alignItems(HorizontalAlign.Center)
                  .onClick(() => this.openOfflineReport(item.id))

                  Button(this.pendingDeleteReportId === item.id ? '确认' : '删除')
                    .fontSize(10)
                    .type(ButtonType.Capsule)
                    .backgroundColor(this.pendingDeleteReportId === item.id ? 0xff3030 : 0x7a3030)
                    .fontColor(Color.White)
                    .width(52)
                    .height(28)
                    .margin({ right: 6 })
                    .onClick(() => this.requestDeleteOfflineReport(item.id))
                }
                .width('92%')
                .height(58)
                .backgroundColor(0x222222)
                .borderRadius(8)
                .margin({ bottom: 8 })
              })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
          }
          .width('100%')
          .height('74%')
        }

      }
      .width('100%')
      .height('100%')
      .padding(12)
      .backgroundColor(0x000000)
    }
    .hideTitleBar(true)
    .onAppear(() => {
      this.pendingDeleteReportId = '';
      this.refreshOfflineReports();
    })
    .onBackPressed(() => {
      this.popPage();
      return true;
    })
  }

  @Builder
  offlineReportDetailBuilder(name: string) {
    NavDestination() {
      Column() {
        if (this.selectedReport === null) {
          Text('报告不存在')
            .fontSize(16)
            .fontColor(Color.White)
        } else {
          Text(this.getSelectedReportDateText())
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .margin({ top: 8, bottom: 6 })

          Text(this.getSelectedReportSummaryText())
            .fontSize(11)
            .fontColor(Color.Gray)
            .margin({ bottom: 4 })

          Text(this.getSelectedReportHeartText())
            .fontSize(11)
            .fontColor(Color.Gray)
            .margin({ bottom: 3 })

          Text('心率曲线')
            .fontSize(9)
            .fontColor(0xff8b8b)
            .margin({ bottom: 2 })

          Stack() {
            if (this.hasHeartSeries(this.selectedReport)) {
              Path({
                width: 160,
                height: 54,
                commands: this.buildHeartLinePath(this.selectedReport)
              })
                .fill(Color.Transparent)
                .stroke(0xffff6b6b)
                .strokeWidth(2)
            } else {
              Text('暂无心率数据')
                .fontSize(10)
                .fontColor(Color.Gray)
            }
          }
          .width(160)
          .height(54)
          .backgroundColor(0x181818)
          .borderRadius(6)
          .margin({ bottom: 5 })

          Text(this.getSelectedReportTiltText())
            .fontSize(10)
            .fontColor(Color.Gray)
            .margin({ bottom: 2 })

          Stack() {
            if (this.hasTiltSeries(this.selectedReport)) {
              Path({
                width: 160,
                height: 54,
                commands: 'M 4 27 L 156 27'
              })
                .fill(Color.Transparent)
                .stroke(0xff555555)
                .strokeWidth(1)

              Path({
                width: 160,
                height: 54,
                commands: this.buildTiltLinePath(this.selectedReport)
              })
                .fill(Color.Transparent)
                .stroke(0xff4bc0ff)
                .strokeWidth(2)
            } else {
              Text('暂无倾角数据')
                .fontSize(10)
                .fontColor(Color.Gray)
            }
          }
          .width(160)
          .height(54)
          .backgroundColor(0x181818)
          .borderRadius(6)
          .margin({ bottom: 5 })

          Text(this.getSelectedReportDistanceText())
            .fontSize(11)
            .fontColor(Color.Gray)
            .margin({ bottom: 6 })
        }
      }
      .width('100%')
      .height('100%')
      .padding(10)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(0x000000)
    }
    .hideTitleBar(true)
    .onBackPressed(() => {
      this.popPage();
      return true;
    })
  }

  // 风源选择页面
  @Builder
  WindInterfaceBuilder(name: string) {
    NavDestination()
    {
      Column() { // 外层 Column（根容器）
        Text(`请选择教练艇`)
          .margin({top:10,bottom:10})
        Column() { // 内层 Column（按钮区域）
          Row() {
            Button('1').onClick(() => { windBoatsource = 1; this.pushPage('LevelSelection') })
              .width(this.button_size).height(this.button_size).margin({ right: 10 })
            Button('2').onClick(() => { windBoatsource = 2; this.pushPage('LevelSelection') })
              .width(this.button_size).height(this.button_size).margin({ right: 10 })
            Button('3').onClick(() => { windBoatsource = 3; this.pushPage('LevelSelection') })
              .width(this.button_size).height(this.button_size)
          }
          .margin({ bottom: 10, top: 15 })
          .justifyContent(FlexAlign.Center)

          Row() {
            Button('4').onClick(() => { windBoatsource = 4; this.pushPage('LevelSelection') })
              .width(this.button_size).height(this.button_size).margin({ right: 10 })
            Button('5').onClick(() => { windBoatsource = 5; this.pushPage('LevelSelection') })
              .width(this.button_size).height(this.button_size)
          }
          .justifyContent(FlexAlign.Center)
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .hideTitleBar(true)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .onBackPressed(() => {
      this.popPage();  // 允许返回上一页
      return true;
    })
  }

  // 级别选择页面
  @Builder
  levelSelectionBuilder(name: string) {
    NavDestination() {
      Column() {
        Text('请选择级别')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 10 })
          .fontColor(Color.White)

        if (this.isLoading) {
          LoadingProgress()
            .color(Color.White)
            .margin({ bottom: 10 })
          Text('加载中...')
            .fontSize(14)
            .fontColor(Color.Gray)
        } else if (this.levelButtons.length === 0) {
          Text('暂无级别数据')
            .fontSize(16)
            .fontColor(Color.Gray)
            .margin({ bottom: 10 })
          Button('重新加载')
            .onClick(() => this.loadLevels())
        } else {
          Scroll() {
            Column() {
              ForEach(this.levelButtons, (item: LevelButton) => {
                Button(item.levelName)
                  .fontSize(16)
                  .type(ButtonType.Capsule)
                  .stateEffect(true)
                  .backgroundColor(item.selected ? 0x317aff : 0x444444)
                  .fontColor(Color.White)
                  .margin({ bottom: 10 })
                  .onClick(() => this.selectLevel(item.levelId))
              })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
          }
          .width('100%')
          .height('60%')
        }
      }
      .height('100%')
      .justifyContent(FlexAlign.Start)
      .padding(20)
      .backgroundColor(0x000000)
    }
    .onAppear(() => { // <---  在这里添加 onAppear
      // 当此页面出现时，自动加载级别列表
      this.loadLevels();
    })
    .hideTitleBar(true)
    .onBackPressed(() => {
      this.popPage();  // 允许返回上一页
      return true;
    })
  }

  // 分组选择页面
  @Builder
  groupSelectionBuilder(name: string) {
    NavDestination() {
      Column() {
        Text('请选择分组')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 10 })
          .fontColor(Color.White)

        if (this.isLoading) {
          LoadingProgress()
            .color(Color.White)
            .margin({ bottom: 10 })
          Text('加载中...')
            .fontSize(14)
            .fontColor(Color.Gray)
        } else if (this.groupButtons.length === 0) {
          Text('暂无分组数据')
            .fontSize(16)
            .fontColor(Color.Gray)
            .margin({ bottom: 10 })
          Button('返回上一级')
            .onClick(() => this.popPage())
        } else {
          Scroll() {
            Column() {
              ForEach(this.groupButtons, (item: GroupButton) => {
                Button(item.mhmName)
                  .fontSize(16)
                  .type(ButtonType.Capsule)
                  .stateEffect(true)
                  .backgroundColor(item.selected ? 0x317aff : 0x444444)
                  .fontColor(Color.White)
                  .margin({ bottom: 10 })
                  .width('80%')
                  .onClick(() => this.selectGroup(item.groupId, item.mhmId, item.mhmName, item.color))
              })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
          }
          .width('100%')
          .height('60%')

          Button('返回')
            .fontSize(14)
            .type(ButtonType.Capsule)
            .backgroundColor(0x666666)
            .fontColor(Color.White)
            .margin({ bottom: 10 })
            .onClick(() => this.popPage())
        }
      }
      .height('100%')
      .justifyContent(FlexAlign.Start)
      .padding(15)
      .backgroundColor(0x000000)
    }
    .hideTitleBar(true)
    .onBackPressed(() => {
      this.popPage();
      return true;
    })
  }

  // 主界面
  @Builder
  loadInterfaceBuilder(name: string) {
    NavDestination() {
      Column() {
        // 状态指示行
        Row() {
          Text(`服务器`)
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
          Circle()
            .width(8)
            .height(8)
            .fill(this.connectionStatusColor)
            .margin({ left: 5, right: 15 })
          Text(`姿态`)
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
          Circle()
            .width(8)
            .height(8)
            .fill(this.bleconnectionStatusColor)
            .margin({ left: 5 })
        }
        .justifyContent(FlexAlign.Center)
        .margin({ top: 15, bottom: 5 })

        // 船名信息
        Text(`${this.selectedmhmName} : ${windBoatsource}`)
          .fontSize(12)
          .fontColor(Color.Gray)
          .margin({ bottom: 5 })

        Button('菜单')
          .fontSize(9)
          .type(ButtonType.Capsule)
          .backgroundColor(this.isStartUpload ? 0x333333 : 0x555555)
          .fontColor(Color.White)
          .width(68)
          .height(20)
          .enabled(!this.isStartUpload)
          .opacity(this.isStartUpload ? 0.45 : 1)
          .margin({ bottom: 3 })
          .onClick(() => this.openOnlineMenu())

        // 速度显示
        Text(`${(this.speed * 1.94).toFixed(1)}`)
          .fontSize(80)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .margin({ bottom: 3 })

        Row() {
          Text(formatDuration(this.offlineElapsedSeconds))
            .fontSize(9)
            .fontColor(Color.White)
          Text(`${this.getOfflineTiltWindowText()}均倾 ${this.hasRecentTiltData ? this.formatSignedAngle(this.recentTiltAverage) : '---'}`)
            .fontSize(9)
            .fontColor(0x9fc7ff)
          Text(`心率 ${this.heartRate}`)
            .fontSize(9)
            .fontColor(0xff8b8b)
        }
        .width('90%')
        .justifyContent(FlexAlign.SpaceBetween)
        .margin({ bottom: 4 })

        // 上传按钮区域
        Column() {
          Stack() {
            Button(this.buttonString)
              .fontSize(16)
              .type(ButtonType.Capsule)
              .stateEffect(!this.isCoolingDown)
              .backgroundColor(this.isCoolingDown ? 0x888888 :
                (this.isLongPressing ? 0xff0000 : 0x317aff))
              .fontColor(Color.White)
              .width(120)
              .height(40)
              .opacity(this.isCoolingDown ? 0.6 : 1)
              .onClick((event?: ClickEvent) => this.onButtonClick(event))
              .onTouch((event: TouchEvent) => {
                if (this.isCoolingDown || !this.isStartUpload) return;
                switch (event.type) {
                  case TouchType.Down:
                    this.startLongPressDetection();
                    break;
                  case TouchType.Up:
                  case TouchType.Cancel:
                    this.stopLongPressDetection();
                    break;
                }
              })

            if (this.isLongPressing && this.isStartUpload) {
              Progress({ value: this.longPressProgress, total: 100, type: ProgressType.Ring })
                .width(40)
                .height(40)
                .color(Color.Red)
                .backgroundColor(0x00000000)
            }

            if (this.isCoolingDown) {
              Progress({ value: 100, total: 100, type: ProgressType.Ring })
                .width(40)
                .height(40)
                .color(Color.Gray)
                .backgroundColor(0x00000000)
            }
          }
          .width(130)
          .height(50)

        }
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor(0x000000)
    }
    .hideTitleBar(true)
    .onAppear(() => this.startOfflineTiltDisplay())
    .onDisAppear(() => this.stopOfflineTiltDisplay())
    .onBackPressed(() => {

      return true;

    })
  }

  // 修改长按检测方法
  startLongPressDetection(): void {
    if (this.isLongPressing) return;
    // 清除之前的计时器
    if (this.longPressTimer !== undefined) {
      clearInterval(this.longPressTimer);
    }

    this.isLongPressing = true;
    this.longPressProgress = 0;

    const startTime = Date.now();
    const updateInterval = 50; // 每50ms更新一次进度

    this.longPressTimer = setInterval(() => {
      const elapsed = Date.now() - startTime;
      this.longPressProgress = Math.min((elapsed / this.longPressDuration) * 100, 100);

      // 达到长按时间
      if (elapsed >= this.longPressDuration) {
        this.handleLongPressComplete();
      }
    }, updateInterval);
  }
  // 长按完成处理
  handleLongPressComplete(): void {
    console.log('长按完成')
    this.stopLongPressDetection();
    this.stopUpload();
  }


  // 停止长按检测
  stopLongPressDetection(): void {
    if (this.longPressTimer !== undefined) {
      clearInterval(this.longPressTimer);
      this.longPressTimer = undefined;
    }
    this.isLongPressing = false;
    this.longPressProgress = 0;
  }

  // 修改停止上传方法，添加冷却时间
  stopUpload(): void {
    // 停止MQTT定时器
    if (this.MqttTimer !== undefined) {
      clearInterval(this.MqttTimer);
      this.MqttTimer = undefined;
    }

    // 断开MQTT连接
    // this.mqttManager.destroy();
    this.stopUploadTimer();
    this.stopOfflineRecording();

    this.isStartUpload = false;
    this.buttonString = '开始记录';
    console.info('长按停止上传成功');

    // 启动冷却时间
    this.startCoolDown();
  }

  // 启动冷却时间
  startCoolDown(): void {
    this.isCoolingDown = true;

    if (this.coolDownTimer !== undefined) {
      clearTimeout(this.coolDownTimer);
    }

    this.coolDownTimer = setTimeout(() => {
      this.isCoolingDown = false;
      this.coolDownTimer = undefined;
      console.info('冷却时间结束，可以重新开始上传');
    }, this.coolDownDuration);
  }

  // 修改按钮点击事件，添加冷却时间检查
  onButtonClick(event?: ClickEvent): void {
    if (event) {

      if (this.isCoolingDown) {
        console.info('冷却时间中，请稍后再试');
        return;
      }

      if (!this.isStartUpload) {
        //不在上传状态中
        this.isStartUpload = true;
        this.buttonString = '长按停止';
        this.startOfflineRecording();
        this.connectWatchMqtt();
        this.startMqttSend();
      }
    }
  }

  onOfflineButtonClick(): void {
    if (this.offlineStopCompletedByLongPress) {
      this.offlineStopCompletedByLongPress = false;
      return;
    }
    if (this.isOfflineRecording) {
      return;
    }
    this.startOfflineRecording();
  }

  startOfflineLongPressDetection(): void {
    if (!this.isOfflineRecording || this.isOfflineLongPressing) {
      return;
    }
    this.stopOfflineLongPressDetection();
    this.isOfflineLongPressing = true;
    this.offlineLongPressProgress = 0;
    const startTime: number = Date.now();
    this.offlineLongPressTimer = setInterval(() => {
      const elapsed: number = Date.now() - startTime;
      this.offlineLongPressProgress = Math.min((elapsed / this.offlineLongPressDuration) * 100, 100);
      if (elapsed >= this.offlineLongPressDuration) {
        this.offlineStopCompletedByLongPress = true;
        this.stopOfflineLongPressDetection();
        this.stopOfflineRecording();
      }
    }, 50);
  }

  stopOfflineLongPressDetection(): void {
    if (this.offlineLongPressTimer !== undefined) {
      clearInterval(this.offlineLongPressTimer);
      this.offlineLongPressTimer = undefined;
    }
    this.isOfflineLongPressing = false;
    this.offlineLongPressProgress = 0;
  }

  startOfflineRecording(): void {
    if (this.isOfflineRecording) {
      return;
    }
    try {
      this.offlineStore.setup(this.getAbilityContext().filesDir);
      this.offlineStartedAt = Date.now();
      this.offlineStore.startSession(
        this.offlineStartedAt,
        this.appMode === APP_MODE_SERVER ? 'online' : 'offline'
      );
      this.offlineSampleCount = 0;
      this.offlineElapsedSeconds = 0;
      this.recentTiltValues = [];
      this.recentTiltAverage = 0;
      this.hasRecentTiltData = false;
      this.isOfflineRecording = true;
      this.offlineButtonString = '停止';
      this.offlineStatus = '记录中';
      if (this.offlineRecordTimer !== undefined) {
        clearInterval(this.offlineRecordTimer);
      }
      this.appendOfflineSample();
      this.offlineRecordTimer = setInterval(() => {
        this.appendOfflineSample();
      }, 1000);
    } catch (error) {
      this.offlineStatus = '启动失败';
      console.error(`启动离线记录失败: ${JSON.stringify(error)}`);
    }
  }

  stopOfflineRecording(): void {
    this.stopOfflineLongPressDetection();
    if (this.offlineRecordTimer !== undefined) {
      clearInterval(this.offlineRecordTimer);
      this.offlineRecordTimer = undefined;
    }
    if (!this.isOfflineRecording) {
      return;
    }
    this.offlineElapsedSeconds = Math.max(0, Math.floor((Date.now() - this.offlineStartedAt) / 1000));
    try {
      const report: TrainingReport | null = this.offlineStore.finishSession(Date.now());
      if (report) {
        this.offlineStatus = `已生成报告 ${report.sampleCount}点`;
        this.selectedReport = report;
      } else {
        this.offlineStatus = '无报告';
      }
    } catch (error) {
      const stopError: Error = error as Error;
      this.offlineStatus = '报告生成失败';
      console.error(`停止离线记录失败: ${stopError.message}`);
    } finally {
      this.isOfflineRecording = false;
      this.offlineButtonString = '开始';
    }
    this.refreshOfflineReports();
  }

  appendOfflineSample(): void {
    if (!this.isOfflineRecording) {
      return;
    }

    const now: number = Date.now();
    const hasSensorData: boolean = this.isOfflineSensorDataAvailable(now);
    let imu: OfflineImuSample | string = '-';
    if (hasSensorData) {
      imu = {
        acceleration: {
          x: this.wtBLE.ble_sensorData.acceleration.x,
          y: this.wtBLE.ble_sensorData.acceleration.y,
          z: this.wtBLE.ble_sensorData.acceleration.z
        },
        angularVelocity: {
          x: this.wtBLE.ble_sensorData.angularVelocity.x,
          y: this.wtBLE.ble_sensorData.angularVelocity.y,
          z: this.wtBLE.ble_sensorData.angularVelocity.z
        },
        angle: {
          roll: this.wtBLE.ble_sensorData.angle.roll,
          pitch: this.wtBLE.ble_sensorData.angle.pitch,
          yaw: this.wtBLE.ble_sensorData.angle.yaw
        },
        rawData: [...this.wtBLE.ble_sensorData.rawData]
      };
    }

    const sample: OfflineRawSample = {
      schemaVersion: 3,
      timestamp: now,
      heartRate: this.heartRate,
      gps: {
        longitude: this.location[0],
        latitude: this.location[1],
        speed: this.speed,
        headingT: this.headingT,
        accuracy: this.gps_accuracy
      },
      imu: imu
    };

    try {
      this.offlineStore.appendSample(sample);
      this.offlineSampleCount += 1;
      if (hasSensorData) {
        this.updateRecentTiltAverage(this.wtBLE.ble_sensorData.angle.roll);
        this.hasRecentTiltData = true;
      } else {
        this.recentTiltValues = [];
        this.recentTiltAverage = 0;
        this.hasRecentTiltData = false;
      }
      this.offlineElapsedSeconds = Math.max(0, Math.floor((Date.now() - this.offlineStartedAt) / 1000));
      this.offlineStatus = `记录中 ${formatDuration(this.offlineSampleCount)}`;
    } catch (error) {
      this.offlineStatus = '写入失败';
      console.error(`写入离线样本失败: ${JSON.stringify(error)}`);
    }
  }

  getSelectedReportDateText(): string {
    const report: TrainingReport | null = this.selectedReport;
    if (report === null) {
      return '';
    }
    return formatShortDateTime(report.startedAt);
  }

  getSelectedReportSummaryText(): string {
    const report: TrainingReport | null = this.selectedReport;
    if (report === null) {
      return '';
    }
    return `${formatDuration(report.durationSec)}  ${report.sampleCount}点`;
  }

  getSelectedReportHeartText(): string {
    const report: TrainingReport | null = this.selectedReport;
    if (report === null) {
      return '';
    }
    return `均心 ${report.averageHeartRate}  最高 ${report.maxHeartRate}  最低 ${report.minHeartRate}`;
  }

  getSelectedReportTiltText(): string {
    const report: TrainingReport | null = this.selectedReport;
    if (report === null) {
      return '';
    }
    if (report.tiltSeries.length === 0) {
      return '倾角曲线  均值 ---  峰值 ---';
    }
    return `倾角曲线  均值 ${this.formatSignedAngle(report.averageTilt)}  峰值 ${this.formatSignedAngle(report.maxTilt)}`;
  }

  getSelectedReportDistanceText(): string {
    const report: TrainingReport | null = this.selectedReport;
    if (report === null) {
      return '';
    }
    return `距离 ${report.distanceMeter} m`;
  }

  hasHeartSeries(report: TrainingReport | null): boolean {
    return report !== null && report.heartSeries.length > 0;
  }

  hasTiltSeries(report: TrainingReport | null): boolean {
    return report !== null && report.tiltSeries.length > 0;
  }

  buildHeartLinePath(report: TrainingReport | null): string {
    if (report === null) {
      return '';
    }
    return this.buildSeriesLinePath(report.heartSeries, 160, 54);
  }

  buildTiltLinePath(report: TrainingReport | null): string {
    if (report === null) {
      return '';
    }
    return this.buildSignedSeriesLinePath(report.tiltSeries, 160, 54);
  }

  buildSignedSeriesLinePath(series: ChartPoint[], width: number, height: number): string {
    if (series.length === 0) {
      return '';
    }

    let maxAbsoluteValue: number = 0;
    for (let i: number = 0; i < series.length; i++) {
      maxAbsoluteValue = Math.max(maxAbsoluteValue, Math.abs(series[i].value));
    }

    const margin: number = 4;
    const step: number = Math.max(1, Math.ceil(series.length / 48));
    const pointCount: number = Math.ceil(series.length / step);
    const safeMaxAbsoluteValue: number = Math.max(maxAbsoluteValue, 0.001);
    let pointIndex: number = 0;
    let commands: string = '';
    for (let i: number = 0; i < series.length; i += step) {
      const x: number = pointCount === 1 ? width / 2 :
        margin + pointIndex / (pointCount - 1) * (width - margin * 2);
      const y: number = margin +
        (safeMaxAbsoluteValue - series[i].value) / (safeMaxAbsoluteValue * 2) * (height - margin * 2);
      commands += pointIndex === 0 ? `M ${x.toFixed(1)} ${y.toFixed(1)}` :
        ` L ${x.toFixed(1)} ${y.toFixed(1)}`;
      pointIndex += 1;
    }
    return commands;
  }

  buildSeriesLinePath(series: ChartPoint[], width: number, height: number): string {
    if (series.length === 0) {
      return '';
    }

    let minValue: number = series[0].value;
    let maxValue: number = series[0].value;
    for (let i: number = 1; i < series.length; i++) {
      minValue = Math.min(minValue, series[i].value);
      maxValue = Math.max(maxValue, series[i].value);
    }

    const margin: number = 4;
    const step: number = Math.max(1, Math.ceil(series.length / 48));
    const pointCount: number = Math.ceil(series.length / step);
    const valueRange: number = Math.max(maxValue - minValue, 0.001);
    let pointIndex: number = 0;
    let commands: string = '';
    for (let i: number = 0; i < series.length; i += step) {
      const x: number = pointCount === 1 ? width / 2 :
        margin + pointIndex / (pointCount - 1) * (width - margin * 2);
      const y: number = maxValue === minValue ? height / 2 :
        margin + (maxValue - series[i].value) / valueRange * (height - margin * 2);
      commands += pointIndex === 0 ? `M ${x.toFixed(1)} ${y.toFixed(1)}` :
        ` L ${x.toFixed(1)} ${y.toFixed(1)}`;
      pointIndex += 1;
    }
    return commands;
  }

  updateRecentTiltAverage(roll: number): void {
    this.recentTiltValues.push(roll);
    while (this.recentTiltValues.length > this.offlineTiltAverageSeconds) {
      this.recentTiltValues.shift();
    }
    let total: number = 0;
    for (let i: number = 0; i < this.recentTiltValues.length; i++) {
      total += this.recentTiltValues[i];
    }
    this.recentTiltAverage = this.recentTiltValues.length > 0 ?
      total / this.recentTiltValues.length : 0;
  }

  isOfflineSensorDataAvailable(now: number): boolean {
    const sensorTimestamp: number = this.wtBLE.ble_sensorData.timestamp;
    return this.isbleConnected && sensorTimestamp > 0 && now - sensorTimestamp <= 5000;
  }

  formatSignedAngle(value: number): string {
    const prefix: string = value > 0 ? '+' : '';
    return `${prefix}${value.toFixed(1)}°`;
  }

  wtBLE: BleManagement = new BleManagement(); // 用于连接并读取wt姿态传感器

  mylevel: level_rec = {
    success: false,
    errCode: "null",
    errMessage: "err",
    data: [
      {
        levelId: "err",
        levelName: "err"
      }
    ]
  };

  mygroup: group_rec = {
    success: false,
    errCode: "null",
    errMessage: "err",
    data: [
      {
        groupId: "err",
        groupName: "err",
        color: "err",
        mhmId: "err",
        mhmName: "err"
      }
    ]
  };

  myboat_data: sailboat_data = {
    mHmName: "000",
    color: "000",

    longitude: "000",
    latitude: "000",

    headingT: -1,
    headingM: -1,
    sailStatus: null,
    leeway: null,

    speed: -1,
    standardSpeed: null,
    customStandardSpeed: null,

    angle: null,
    vmg: null,
    standardVmg: null,

    customAngle: null,
    customVmg: null,
    customStandardVmg: null,

    windSourceBoatCode: "000",
    windSpeed: -1,
    windDirection: -1,
    customWindSpeed: -1,
    customWindDirection: -1,

    yaw: -1,
    rol: -1,
    pitch: -1,
    posture: null,
    pitchPosture: null,

    hr: [0,0]
  }

  myMqttUploadData: mqttUploadData = {
    mHmId: "000",
    ts: "000",
    data: this.myboat_data
  }

  //mqtt发送管理器
  mqttManager: MqttManagement = new MqttManagement(
    "fudan top3",
    1883,
    false
  );


  //请求位置信息的参数
  gnss_request: geoLocationManager.ContinuousLocationRequest= {
    //高功耗定位
    locationScenario: geoLocationManager.PowerConsumptionScenario.HIGH_POWER_CONSUMPTION,
    //实时上报定位
    interval:0,
  };

  //定时器中请求单次位置信息参数
  timer_request: geoLocationManager.LocationRequest = {
    priority: geoLocationManager.LocationRequestPriority.FIRST_FIX, //快速定位
    maxAccuracy: 50,
    scenario: geoLocationManager.LocationRequestScenario.NAVIGATION  // 使用高精度模式
  };



  // 加载级别
  async loadLevels() {

    this.isLoading = true;
    try {
      const levelData = await get_level(tenantCode, is_test);
      if (levelData.success && levelData.data.length > 0) {
        // 明确指定类型
        this.levelButtons = levelData.data.map((item) => ({
          levelId: item.levelId,
          levelName: item.levelName,
          selected: false
        } as LevelButton)); // 使用类型断言
      } else {
        console.error('获取级别数据失败');
      }
    } catch (error) {
      console.error('加载级别数据错误:', error);
    } finally {
      this.isLoading = false;
    }
  }

  // 修改 selectLevel 方法 - 修复跳转
  async selectLevel(levelId: string) {
    this.levelButtons = this.levelButtons.map(item => ({
      levelId: item.levelId,
      levelName: item.levelName,
      selected: item.levelId === levelId
    } as LevelButton));

    this.selectedLevelId = levelId;
    this.isLoading = true;

    try {
      const groupData = await get_group(this.selectedLevelId, is_test);
      if (groupData.success && groupData.data.length > 0) {
        this.groupButtons = groupData.data.map((item) => ({
          groupId: item.groupId,
          mhmName: item.mhmName,
          mhmId: item.mhmId,
          selected: false,
          color: item.color || '#317aff'
        } as GroupButton));

        // 使用正确的方法跳转
        this.pushPage('GroupSelection');
      } else {
        console.error('获取分组数据失败');
      }
    } catch (error) {
      console.error('加载分组数据错误:', error);
    } finally {
      this.isLoading = false;
    }
  }

  // 选择组别
  selectGroup(groupId: string, mhmId: string, mhmName: string, groupColor: string) {
    this.groupButtons = this.groupButtons.map(item => ({
      groupId: item.groupId,
      mhmName: item.mhmName,
      mhmId: item.mhmId,
      color: item.color,
      selected: item.groupId === groupId
    } as GroupButton));

    this.selectedGroupId = groupId;
    this.selectedmhmName = mhmName;
    this.selectedGroupColor = groupColor;
    this.selectedmhmId = mhmId;

    // 更新mygroup中的数据
    this.mygroup.data[0].groupId = groupId;
    this.mygroup.data[0].mhmId = mhmId;
    this.mygroup.data[0].mhmName = mhmName;
    this.mygroup.data[0].color = groupColor;

    this.saveOnlineTrainingConfig();

    // 切换到主界面 - 使用正确的方法名
    this.pushPage('BleDeviceSelection');
  }

  //监测时间3s，屏幕常量关闭
  aboutToAppear() {
    if (!this.hasInitiatedJump) {
      this.hasInitiatedJump = true;
      this.pushPage('ModeSelection')
    }
    this.setupBleCallbacks();
    try {
      this.offlineStore.setup(this.getAbilityContext().filesDir);
      this.onlineConfigStore.setup(this.getAbilityContext().filesDir);
      this.offlineModeConfigStore.setup(this.getAbilityContext().filesDir);
      this.refreshOfflineReports();
    } catch (error) {
      console.error(`初始化离线存储失败: ${JSON.stringify(error)}`);
    }
    notificationManager.requestEnableNotification(requestEnableNotificationCallback);
    this.stopNotificationTimer();
    this.notificationTimer = startTimerNotification(1000); // 每 1 秒发送一次通知

    // this.listenToScreen();
    this.check_test();
    this.mqttManager.setHost(user_url);
    this.requestPermissionAndStart();
    // this.loadLevels();
    this.startCheckTimer(3000);
    this.keepScreenOn(true);
  }

  async listenToScreen() {
    let callback = (id: number) => {
      let disp = display.getDisplayByIdSync(id);
      console.info(`Display ${id} state changed : ${disp.state}`);
    }

    let displayClass: Array<display.Display> = [];
    display.getAllDisplays((err: BusinessError, data: Array<display.Display>) => {
      displayClass = data;
      const errCode: number = err.code;
      if (errCode) {
        console.error(`Failed to obtain all the display objects. Code: ${err.code}, message: ${err.message}`);
        return;
      }
      // console.info(`Succeeded in obtaining all the display objects. Data: ${JSON.stringify(data)}`);
    });

    display.on('change', callback);
    console.log(`start listen to screen change`)
  }

  //设置屏幕常亮
  async keepScreenOn(enable: boolean) {
    try {
      const win = await window.getLastWindow(this.getAbilityContext());
      await win.setWindowKeepScreenOn(enable);
    } catch (err) {
      console.error('设置屏幕常亮失败:', JSON.stringify(err));
    }
  }

  //权限获取
  async requestPermissionAndStart() {
    const atManager = abilityAccessCtrl.createAtManager();
    const context = this.getAbilityContext();

    const permissions: Permissions[] = [
      'ohos.permission.READ_HEALTH_DATA' as Permissions,
      'ohos.permission.LOCATION' as Permissions,
      'ohos.permission.APPROXIMATELY_LOCATION' as Permissions,
      'ohos.permission.ACCELEROMETER' as Permissions,
      'ohos.permission.INTERNET' as Permissions,
      'ohos.permission.ACCESS_BLUETOOTH' as Permissions,
      'ohos.permission.DISCOVER_BLUETOOTH' as Permissions,
      'ohos.permission.USE_BLUETOOTH' as Permissions,
      'ohos.permission.KEEP_BACKGROUND_RUNNING' as Permissions
    ];

    atManager.requestPermissionsFromUser(
      context,
      permissions,
      (err: BusinessError, data: PermissionRequestResult) => {
        if (err) {
          console.error(`权限请求失败: code=${err.code}, message=${err.message}`);
          this.isPermissionRequestCompleted = true;
          this.hasBluetoothPermission = false;
          if (this.isBleSelectionVisible) {
            this.bleScanStatus = '蓝牙权限请求失败';
          }
          return;
        }

        // 遍历授权结果
        let bluetoothPermissionFound: boolean = false;
        let bluetoothPermissionGranted: boolean = true;
        for (let i = 0; i < data.authResults.length; i++) {
          const permissionName: string = data.permissions[i];
          if (permissionName === 'ohos.permission.ACCESS_BLUETOOTH' ||
            permissionName === 'ohos.permission.DISCOVER_BLUETOOTH' ||
            permissionName === 'ohos.permission.USE_BLUETOOTH') {
            bluetoothPermissionFound = true;
            if (data.authResults[i] !== 0) {
              bluetoothPermissionGranted = false;
            }
          }
          if (data.authResults[i] !== 0) {
            console.warn(`权限 ${data.permissions[i]} 被拒绝!`);
          }
          else {
            console.log(`权限 ${data.permissions[i]} 被通过`);
          }
        }

        this.isPermissionRequestCompleted = true;
        this.hasBluetoothPermission = bluetoothPermissionFound && bluetoothPermissionGranted;
        if (this.isBleSelectionVisible) {
          if (this.hasBluetoothPermission) {
            this.startBleDeviceScan();
          } else {
            this.bleScanStatus = '未获得蓝牙权限';
          }
        }

        // 判断是否全部授权
        const allGranted = data.authResults.every(result => result === 0);
        if (allGranted) {
          console.info('所有权限已授权,开始监测');
          this.startHeartRateSensor(); // 心率订阅函数
          this.startLocationService(); // 定位
          // this.startAccelerometer();//加速度传感器
          // this.startUploadTimer_queue(this.uploadInterval);//通过队列上传(http)
          // this.startCheckTimer();//定时监测服务器是否连接成功
          // this.startGpsTimer(300);//通过定时器定位
          // this.uploadData_test();//上传数据（测试用）
          // this.startUploadTimer(this.uploadInterval);//定时上传数据
          // this.runCapacityTests();//上传数据容量测试
          // BLE 由设备选择页启动扫描并连接。
        } else {
          console.warn('部分权限未授权，功能可能受限');
        }
      }
    );
  }

  calcLeeway(attitude: string | null, w: number): string {
    let leeway: number;

    if (w === 0) {
      leeway = 0;
    } else {
      switch (attitude) {
        case "U_P":
          leeway = w > 0 ? -w : Math.abs(w);
          break;
        case "U_S":
        case "D_P":
        case "D_S":
          leeway = w > 0 ? w : -Math.abs(w);
          break;
        default:
          throw new Error(`未知姿态: ${attitude}`);
      }
    }

    return leeway.toString(); // 转为字符串
  }


  async startMqttSend(intervalMs: number = 1000) {
    if (this.MqttTimer !== undefined) {
      console.info('MQTT上传定时器已启动');
      return;
    }

    this.MqttTimer = setInterval(async () => {
      try {

      // MQTT publish 会在断线时进入管理器的离线队列。
      if(!this.mqttManager.isConnected){
        console.error('fail to connect to the server')
      }

      let myWindData: WindDataMessage = this.mqttManager.getLatestWindData();
      //三次数据一样
      if(myWindData === last_wind && last_wind == last_last_wind && !is_test){
        // console.error("wind lost")
        // this.mqttManager.subscribe(`gateway/env/wind/${tenantCode}/${windBoatsource}`,1);
      }
      if(myWindData.windSourceBoatCode === "null"){
        this.mqttManager.subscribe(`gateway/env/wind/${tenantCode}/${windBoatsource}`,1);
      }

      this.myMqttUploadData.mHmId = this.selectedmhmId;
      this.myMqttUploadData.ts = formatDateTime(new Date());

      this.myMqttUploadData.data.mHmName = this.selectedmhmName;
      this.myMqttUploadData.data.color = this.selectedGroupColor;

      this.myMqttUploadData.data.longitude = String(this.location[0].toFixed(6));
      this.myMqttUploadData.data.latitude = String(this.location[1].toFixed(6));

      this.myMqttUploadData.data.yaw = Math.trunc(this.wtBLE.transYaw());
      this.myMqttUploadData.data.rol = Math.trunc(( - this.wtBLE.ble_sensorData.angle.roll));
      this.myMqttUploadData.data.pitch = Math.trunc((- this.wtBLE.ble_sensorData.angle.pitch));

      this.myMqttUploadData.data.speed = toFixedNumber(this.speed * 100); //cm/s，保留4位小数

      this.myMqttUploadData.data.headingT = this.headingT;

      this.myMqttUploadData.data.windSourceBoatCode = myWindData.windSourceBoatCode;
      this.myMqttUploadData.data.windSpeed = myWindData.windSpeed;
      this.myMqttUploadData.data.windDirection = myWindData.windDirection;
      this.myMqttUploadData.data.customWindSpeed = myWindData.customWindSpeed;
      this.myMqttUploadData.data.customWindDirection = myWindData.customWindDirection;

      //航向存在时，0° 是有效航向，不能用 truthy 判断。
      if(this.headingT !== null){
        const headingTValue: number = Math.trunc(this.headingT);
        const headingMValue: number = Math.trunc((headingTValue - declination + 360) % 360);
        this.myMqttUploadData.data.headingT = headingTValue;
        this.myMqttUploadData.data.headingM = headingMValue;

        let A : number = headingMValue - this.myMqttUploadData.data.windDirection
        if( ( 90 < A && A <= 180) || (-270 < A && A < -180)){
          this.myMqttUploadData.data.sailStatus = "D_P" //顺风左舷
        }else if ((-180 < A && A < -90)||(180 < A && A < 270)){
          this.myMqttUploadData.data.sailStatus = "D_S" //顺风右舷
        }else if((0 <= A && A <= 90)||(-360 < A && A <= 270)){
          this.myMqttUploadData.data.sailStatus = "U_P" //迎风左舷
        }else if((270 <= A && A < 360)||(-90 <= A && A < 0)){
          this.myMqttUploadData.data.sailStatus = "U_S" //迎风右舷
        }
        if(Math.abs(this.myMqttUploadData.data.rol) <= postureThreshold){
          this.myMqttUploadData.data.posture = "平衡"
        }else{
          if(this.myMqttUploadData.data.sailStatus == "U_S" || this.myMqttUploadData.data.sailStatus == "D_S"){
            if (this.myMqttUploadData.data.rol < -postureThreshold) {
              this.myMqttUploadData.data.posture = "反扣";
            }else {
              this.myMqttUploadData.data.posture = "倾斜";
            }
          }else {
            if (this.myMqttUploadData.data.rol < -postureThreshold) {
              this.myMqttUploadData.data.posture = "倾斜";
            }else {
              this.myMqttUploadData.data.posture = "反扣";
            }
          }
        }

        let w: number = 0;
        //漂角计算
        if(Math.abs(headingMValue - this.myMqttUploadData.data.yaw) <= 90){
          w= headingMValue - this.myMqttUploadData.data.yaw;
        }else if(headingMValue - this.myMqttUploadData.data.yaw > 90){
          w= headingMValue - this.myMqttUploadData.data.yaw - 360;
        }else if(headingMValue - this.myMqttUploadData.data.yaw < -90){
          w = 360 + headingMValue - this.myMqttUploadData.data.yaw
        }

        this.myMqttUploadData.data.leeway = this.calcLeeway(this.myMqttUploadData.data.sailStatus, w);

        //角度和VMG计算
        let angleValue: number;
        if(Math.abs(headingMValue - this.myMqttUploadData.data.windDirection) <= 180){
          angleValue = Math.abs(headingMValue - this.myMqttUploadData.data.windDirection);
        }else {
          angleValue = 360 - Math.abs(headingMValue - this.myMqttUploadData.data.windDirection);
        }
        this.myMqttUploadData.data.angle = angleValue;
        this.myMqttUploadData.data.vmg = toFixedNumber(this.myMqttUploadData.data.speed * Math.cos(degreesToRadians(angleValue)));

        //自定义角度和自定义VMG计算
        let customAngleValue: number;
        if(Math.abs(headingMValue - this.myMqttUploadData.data.customWindDirection) <= 180){
          customAngleValue = Math.abs(headingMValue - this.myMqttUploadData.data.customWindDirection);
        }else {
          customAngleValue = 360 - Math.abs(headingMValue - this.myMqttUploadData.data.customWindDirection);
        }
        this.myMqttUploadData.data.customAngle = customAngleValue;
        this.myMqttUploadData.data.customVmg = toFixedNumber(this.myMqttUploadData.data.speed * Math.cos(degreesToRadians(customAngleValue))); //保留四位小数

        let windddddd: number = Math.abs(this.myMqttUploadData.data.windSpeed);
        let standardspeedddddd: number = -1;
        let standardvmgggggg: number = -1;
        //顺风时给出标准
        if(this.myMqttUploadData.data.sailStatus === "D_P" || this.myMqttUploadData.data.sailStatus === "D_S"){
          if(windddddd <= 5){
            standardspeedddddd = 0.01;
            standardvmgggggg = 0.01;
          }else if(5 < windddddd && windddddd <= 8.00){
            standardspeedddddd = 4.07;
            standardvmgggggg = 0.08;
          }else if(8 < windddddd && windddddd <= 12.00){
            standardspeedddddd = 5.43;
            standardvmgggggg = 5.00;
          }else if(12 < windddddd && windddddd <= 15.00){
            standardspeedddddd = 7.24;
            standardvmgggggg = 6.67;
          }else if(windddddd > 15){
            standardspeedddddd = 9.31;
            standardvmgggggg = 8.57;
          }
        }else if(this.myMqttUploadData.data.sailStatus === "U_S" || this.myMqttUploadData.data.sailStatus === "U_P"){
          if(windddddd <= 5){
            standardspeedddddd = 0.01;
            standardvmgggggg = 0.01;
          }else if(5 < windddddd && windddddd <= 8.00){
            standardspeedddddd = 4.25;
            standardvmgggggg = 3.16;
          }else if(8 < windddddd && windddddd <= 12.00){
            standardspeedddddd = 4.75;
            standardvmgggggg = 3.53;
          }else if(12 < windddddd && windddddd <= 15.00){
            standardspeedddddd = 5.05;
            standardvmgggggg = 3.75;
          }else if(windddddd > 15){
            standardspeedddddd = 4.89;
            standardvmgggggg = 3.64;
          }
        }
        this.myMqttUploadData.data.standardSpeed = standardspeedddddd;
        this.myMqttUploadData.data.standardVmg = standardvmgggggg;

        windddddd = Math.abs(this.myMqttUploadData.data.customWindSpeed);
        standardspeedddddd = -1;
        standardvmgggggg = -1;
        //顺风时给出标准
        if(this.myMqttUploadData.data.sailStatus === "D_P" || this.myMqttUploadData.data.sailStatus === "D_S"){
          if(windddddd <= 5){
            standardspeedddddd = 0.01;
            standardvmgggggg = 0.01;
          }else if(5 < windddddd && windddddd <= 8.00){
            standardspeedddddd = 4.07;
            standardvmgggggg = 0.08;
          }else if(8 < windddddd && windddddd <= 12.00){
            standardspeedddddd = 5.43;
            standardvmgggggg = 5.00;
          }else if(12 < windddddd && windddddd <= 15.00){
            standardspeedddddd = 7.24;
            standardvmgggggg = 6.67;
          }else if(windddddd > 15){
            standardspeedddddd = 9.31;
            standardvmgggggg = 8.57;
          }
        }else if(this.myMqttUploadData.data.sailStatus === "U_S" || this.myMqttUploadData.data.sailStatus === "U_P"){
          if(windddddd <= 5){
            standardspeedddddd = 0.01;
            standardvmgggggg = 0.01;
          }else if(5 < windddddd && windddddd <= 8.00){
            standardspeedddddd = 4.25;
            standardvmgggggg = 3.16;
          }else if(8 < windddddd && windddddd <= 12.00){
            standardspeedddddd = 4.75;
            standardvmgggggg = 3.53;
          }else if(12 < windddddd && windddddd <= 15.00){
            standardspeedddddd = 5.05;
            standardvmgggggg = 3.75;
          }else if(windddddd > 15){
            standardspeedddddd = 4.89;
            standardvmgggggg = 3.64;
          }
        }
        this.myMqttUploadData.data.customStandardSpeed = standardspeedddddd;
        this.myMqttUploadData.data.customStandardVmg = standardvmgggggg;
      }
      //航向不存在
      else {
        this.myMqttUploadData.data.headingT = "";
        this.myMqttUploadData.data.headingM = "";
        this.myMqttUploadData.data.sailStatus = null;
        this.myMqttUploadData.data.posture = null;
        this.myMqttUploadData.data.angle = null;
        this.myMqttUploadData.data.vmg = null;
        this.myMqttUploadData.data.customAngle = null;
        this.myMqttUploadData.data.customVmg = null;
        if(Math.abs(this.myMqttUploadData.data.rol) <= postureThreshold){
          this.myMqttUploadData.data.posture = "平衡"
        }
      }
      //风不存在
      if(this.myMqttUploadData.data.windSpeed == -1){
        this.myMqttUploadData.data.sailStatus = null;
        this.myMqttUploadData.data.angle = null;
        this.myMqttUploadData.data.vmg = null;
        this.myMqttUploadData.data.customAngle = null;
        this.myMqttUploadData.data.customVmg = null;
      }

      if(this.heartRate != 255 && this.heartRate != 0){
        this.myMqttUploadData.data.hr = [this.heartRate,-1];
      }
      else {
        this.myMqttUploadData.data.hr = [-1,-1];
      }

      if(Math.abs(this.myMqttUploadData.data.pitch) <= pitchpostureThreshold){
        this.myMqttUploadData.data.pitchPosture = "平衡"
      }else if(this.myMqttUploadData.data.pitch > pitchpostureThreshold){
        this.myMqttUploadData.data.pitchPosture = "后仰"
      }else if(this.myMqttUploadData.data.pitch < -pitchpostureThreshold){
        this.myMqttUploadData.data.pitchPosture = "前俯"
      }

      // 发布航行数据消息
      await this.mqttManager.publish(`mobile/up/general-train/${tenantCode}/${this.selectedLevelId}/${this.selectedmhmId}`, JSON.stringify(this.myMqttUploadData),1);

      let gps_valid: string = "V";
      if(this.gps_accuracy < gps_accuracy_set){
        gps_valid = "A";
      }
      let gps_original_data: original_data = {
        mHmId: this.myMqttUploadData.mHmId,
        ts: this.myMqttUploadData.ts,
        dataType: "gps",
        data: `${gps_valid},${this.myMqttUploadData.data.longitude},${this.myMqttUploadData.data.latitude},${(this.speed * 100).toFixed(4)},${this.myMqttUploadData.data.headingT},${declination}`
      }
      if(this.myMqttUploadData.data.speed === 0){
        gps_original_data.data = `${gps_valid},${this.myMqttUploadData.data.longitude},${this.myMqttUploadData.data.latitude},${(this.speed * 100).toFixed(1)},${this.myMqttUploadData.data.headingT},${declination}`
      }

      // 发布航行原始数据
      await this.mqttManager.publish(`mobile/up/original/${tenantCode}/${this.selectedLevelId}/${this.selectedmhmId}`, JSON.stringify(gps_original_data),1);

      let last1sSensorData: wt_SensorData[] = this.wtBLE.getLast1sData();
      let last1sSensorString: string = this.wtBLE.formatAngleDataForPosture(last1sSensorData)
      let posture_original_data: original_data = {
        mHmId: this.myMqttUploadData.mHmId,
        ts: this.myMqttUploadData.ts,
        dataType: "posture",
        data: `${this.wtBLE.formatAngleDataForPosture(last1sSensorData)}`
      }
      //姿态数据不为空才上传
      if(last1sSensorString != ""){
        // 发布姿态原始数据
        await this.mqttManager.publish(`mobile/up/original/${tenantCode}/${this.selectedLevelId}/${this.selectedmhmId}`, JSON.stringify(posture_original_data),1);
      }

      let heartRate_original_data: original_data = {
        mHmId: this.myMqttUploadData.mHmId,
        ts: this.myMqttUploadData.ts,
        dataType: "heartrate",
        data: `${this.myMqttUploadData.data.hr}|-1`
      }
      //发布心率原始数据
      await this.mqttManager.publish(`mobile/up/original/${tenantCode}/${this.selectedLevelId}/${this.selectedmhmId}`, JSON.stringify(heartRate_original_data),1);

      let wind_original_data: original_data = {
        mHmId: this.myMqttUploadData.mHmId,
        ts: this.myMqttUploadData.ts,
        dataType: "wind",
        data: this.myMqttUploadData.data.windSourceBoatCode
      }
      if(wind_original_data.data != "null"){
        //发布风来源原始数据
        await this.mqttManager.publish(`mobile/up/original/${tenantCode}/${this.selectedLevelId}/${this.selectedmhmId}`, JSON.stringify(wind_original_data),1);
      }

      last_last_wind = last_wind;
      last_wind = myWindData;

      // let winddatalist: WindDataMessage[] = [];
      // winddatalist = this.mqttManager.getAllWindData();
      // console.log(JSON.stringify(winddatalist));


      } catch (error) {
        console.error(`MQTT上传循环异常: ${JSON.stringify(error)}`);
      }
    }, intervalMs);
  }

  //定时监测网络状态
  async startCheckTimer(intervalMs : number = 1000) {
    this.stopCheckTimer();

    // "longitude":"121.493807","latitude":"31.300226"

    this.checkTimer = setInterval(async () => {

      let success = false;
      if (this.appMode === APP_MODE_SERVER) {
        success = this.mqttManager.isConnected;

      if(success == true){
        console.error('已连接')
        this.isConnected = true;
        this.connectionStatusColor = Color.Green;
        // this.dataUploader.tryStartUpload();
      }
      else {

        this.isConnected = false;
        this.connectionStatusColor = Color.Red;
        if(windBoatsource != -1 && !this.mqttManager.isConnecting()){
          await this.connectWatchMqtt();
          console.error('重新连接中')
        }
        if(this.isStartUpload && this.MqttTimer === undefined){
          this.startMqttSend()
        }

      }

      } else {
        this.isConnected = false;
        this.connectionStatusColor = Color.Gray;
      }

      if (this.selectedBleDeviceId.length === 0) {
        return;
      }
      success = false;
      success =  await this.wtBLE.checkDeviceName()
      if(success == true){
        console.error('蓝牙已连接')
        this.isbleConnected = true;
        this.bleconnectionStatusColor = Color.Green;
        // this.dataUploader.tryStartUpload();
      }
      else {
        console.error('蓝牙重新连接中')
        this.isbleConnected = false;
        this.bleconnectionStatusColor = Color.Red;
        this.wtBLE.checkDevice()
        // this.startMqttSend()
      }

    }, intervalMs);
    console.info(`启动定时监测，间隔: ${intervalMs}ms`);
  }

  stopCheckTimer(): void {
    if (this.checkTimer !== undefined) {
      clearInterval(this.checkTimer);
      this.checkTimer = undefined;
    }
  }

  //添加定时上传(队列)
  startUploadTimer_queue(intervalMs : number = 5000) {

    this.stopUploadTimer();

    console.log(`角度: roll: ${this.wtBLE.ble_sensorData.angle.roll},pitch: ${this.wtBLE.ble_sensorData.angle.pitch},yaw: ${this.wtBLE.ble_sensorData.angle.yaw}`);

    this.uploadTimer = setInterval(() => {

      let ble_Data: ble_SensorData = {
        header : this.wtBLE.ble_sensorData.header,
        flag : this.wtBLE.ble_sensorData.flag,
        acceleration : {
          x : this.wtBLE.ble_sensorData.acceleration.x,
          y : this.wtBLE.ble_sensorData.acceleration.y,
          z : this.wtBLE.ble_sensorData.acceleration.z
        },
        angularVelocity : {
          x : this.wtBLE.ble_sensorData.angularVelocity.x,
          y : this.wtBLE.ble_sensorData.angularVelocity.y,
          z : this.wtBLE.ble_sensorData.angularVelocity.z
        },
        angle : {
          roll : this.wtBLE.ble_sensorData.angle.roll,
          pitch : this.wtBLE.ble_sensorData.angle.pitch,
          yaw : this.wtBLE.ble_sensorData.angle.yaw
        },
        rawData : [],
        timestamp : Date.now()
      }

      let sensor_data: UploadData = {
        heartRate: this.heartRate,
        location: [...this.location],
        speed: this.speed,
        sensorData: [...this.sensor_data.slice(0,3)],
        timestamp: Date.now(),
        lag_time: dur_time,
        gps_change: location_change,
        ble_SensorData: ble_Data
      };

      this.dataUploader.addDataToQueue(sensor_data);
      this.dataQueueLength = this.dataUploader.dataQueueLength;
      // this.dataUploader.addDataToQueue(sensor_data);

      // if(this.dataUploader.isNetworkAvailable){
      //   this.isConnected = true;
      //   this.connectionStatusColor = Color.Green;
      // }
      // else {
      //   this.isConnected = false;
      //   this.connectionStatusColor = Color.Red;
      // }

    }, intervalMs);
    console.info(`启动定时上传，间隔: ${intervalMs}ms`);
  }

  stopUploadTimer() {
    if (this.uploadTimer !== undefined) {
      clearInterval(this.uploadTimer);
      this.uploadTimer = undefined;
    }
    if (this.uploadTimer_buffer !== undefined) {
      clearInterval(this.uploadTimer_buffer);
      this.uploadTimer_buffer = undefined;
    }
    if (this.MqttTimer !== undefined) {
      clearInterval(this.MqttTimer);
      this.MqttTimer = undefined;
    }
    console.info('停止定时上传');
  }

  stopNotificationTimer(): void {
    if (this.notificationTimer !== undefined) {
      clearInterval(this.notificationTimer);
      this.notificationTimer = undefined;
    }
  }

  async startAccelerometer() {
    // 使用try catch对可能出现的异常进行捕获
    try {
      sensor.on(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
        // console.info('Succeeded in invoking on. X-coordinate component: ' + data.x);
        // console.info('Succeeded in invoking on. Y-coordinate component: ' + data.y);
        // console.info('Succeeded in invoking on. Z-coordinate component: ' + data.z);
        this.sensor_data[0] = data.x;
        this.sensor_data[1] = data.y;
        this.sensor_data[2] = data.z;
        // last_time = now_time;
        // now_time = new Date().getTime();
        // let time_diff : number = now_time - last_time;
        // if(last_time != 0){
        //   // console.info('两次读取加速度传感器间隔：' , now_time - last_time);
        // }
      }, { interval: this.sensorInterval });
    } catch (error) {
      let e: BusinessError = error as BusinessError;
      console.error(`Failed to invoke on. Code: ${e.code}, message: ${e.message}`);
    }
  }

  async startLocationService() {
    try{
      geoLocationManager.on('locationChange',this.gnss_request, (location: geoLocationManager.Location) => {
        // console.log('实时定位：纬度=', location.latitude, ' 经度=', location.longitude, '速度=', location.speed)
        if (location.longitude != this.location[0] || location.latitude != this.location[1]){
          this.location[0] = location.longitude;
          this.location[1] = location.latitude;
          location_change += 1;
        }
        if(location.speed != this.speed){
          this.speed = location.speed;
        }
        this.gps_accuracy = location.accuracy;

        if(location.directionAccuracy){
          if(location.directionAccuracy > 0){
            this.headingT = location.direction;
          }
          else {
            this.headingT = null
          }//不可信
        }
        // console.log(`位置精度： ${location.accuracy}，航向精度：${location.directionAccuracy}`)
      })
    }
    catch(error){
      let e: BusinessError = error as BusinessError;
      console.error(`定位失败：${e.message}`);}
    // throw new Error('Method not implemented.');
  }

  //通过定时器读取位置信息
  async startGpsTimer(intervalMs: number = 1000) {
    this.stopGpsTimer();
    gpsTimer = setInterval(async () => {
      try {
        const location = await geoLocationManager.getCurrentLocation(this.timer_request);
        // console.info(`经度：${location.longitude}, 纬度：${location.latitude}`);
        this.location[0] = location.longitude;
        this.location[1] = location.latitude;
        console.log('实时定位：纬度=', location.latitude, ' 经度=', location.longitude, '速度=', location.speed)
      } catch (err) {
        console.error(`获取GPS失败: ${JSON.stringify(err)}`);
      }
    }, intervalMs);
  }
  async stopGpsTimer() {
    if (gpsTimer !== undefined) {
      clearInterval(gpsTimer);
      gpsTimer = undefined;
    }
  }

  startHeartRateSensor() {
    try {
      sensor.on(sensor.SensorId.HEART_RATE, (data: sensor.HeartRateResponse) => {
        this.heartRate = data.heartRate;
        // console.log(`心率:${this.heartRate}`);
      }, { interval: this.heartInterval }); // 每1000ms更新一次
    } catch (err) {
      let e = err as BusinessError;
      console.error(`心率订阅失败，错误码: ${e.code}, 信息: ${e.message}`);
    }
  }

  // 测试上传方法
  async testUploadCap(sizeKB: number): Promise<ITestResult> {
    const testData: uploadCap = {
      payload: generateTestData(sizeKB),
      timestamp: Date.now()
    };
    const testUploadCapRequest = http.createHttp();

    try {
      const start = Date.now();
      await testUploadCapRequest.request(
        "http://124.222.53.152:8080/api/upload",
        {
          method: http.RequestMethod.POST,
          connectTimeout: 3000,
          header: {"Content-Type" : "application.json"},
          extraData: testData.payload
        }
      );
      const duration = Date.now() - start;
      // console.info(`上传用时: ${duration}`)


      return {
        success: true,
        sizeKB,
        duration
      } as ITestResult;

    } catch (error) {
      return {
        success: false,
        sizeKB,
        error: JSON.stringify(error)
      } as ITestResult;
    } finally {
      testUploadCapRequest.destroy();
    }
  }

  async runCapacityTests() {
    const testSizes = [1, 10, 100, 1024, 5120, 10240, 51200]; // KB单位: 1KB,10KB,100KB,1MB,5MB,10MB,50MB

    for (const sizeKB of testSizes) {
      try {
        console.log(`开始测试 ${sizeKB}KB 数据上传...`);
        const result = await this.testUploadCap(sizeKB);

        console.log(
          `测试结果: ${sizeKB}KB | ` +
            `状态: ${result.success ? '成功' : '失败'} | ` +
            `耗时: ${result.duration || 0}ms`
        );

        // 失败时停止后续更大容量测试
        if (!result.success) break;

      } catch (error) {
        console.error(`${sizeKB}KB 测试异常:`, error);
        break;
      }

      // 间隔2秒避免服务器过载
      await new Promise<void>(resolve =>
      setTimeout(resolve, 2000));
    }
  }

  async connectWatchMqtt() {

    if (!this.selectedLevelId || !this.selectedGroupId) {
      console.warn('请先选择级别和分组');
      return;
    }

    this.mqttManager.setCredentials('sailboat_watch', 'sailboat_watch_2024');

    this.mqttManager.setKeepalive(10);

    const clientId = `sailboat_watch_${this.selectedGroupId}`;

    this.mqttManager.setClientId(clientId);

    if (windBoatsource != -1) {
      await this.mqttManager.subscribe(`gateway/env/wind/${tenantCode}/${windBoatsource}`, 1);
    }

    const connected = await this.mqttManager.connect();

    if(connected) {
      console.info('手表端MQTT连接成功');
    } else if (windBoatsource == -1) {
      console.error("no windboat selection")
    }
  }

  async aboutToDisappear() {
    try {
      this.stopLongPressDetection();
      this.stopOfflineLongPressDetection();
      if (this.coolDownTimer !== undefined) {
        clearTimeout(this.coolDownTimer);
        this.coolDownTimer = undefined;
      }
      this.stopNotificationTimer();
      this.stopCheckTimer();
      this.stopOfflineRecording();
      this.stopUploadTimer();
      sensor.off(sensor.SensorId.HEART_RATE);
      sensor.off(sensor.SensorId.ACCELEROMETER);
      this.dataUploader.dispose();
      if (this.mqttManager) {
        await this.mqttManager.destroy(); // 必须等待彻底断开
      }
      this.wtBLE.clearDeviceDiscoveryCallback();
      this.wtBLE.clearOnConnectCallback();
      this.wtBLE.clearOnDisconnectCallback();
      this.hasSetupBleCallbacks = false;
      this.wtBLE.disconnect();
      geoLocationManager.off('locationChange');
      console.log('定位服务关闭');
    } catch (err) {
      console.error("errCode:" + JSON.stringify(err));
    }
    this.keepScreenOn(false);
    this.stopGpsTimer();
  }
}

function formatDateTime(date: Date): string {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  const hours = String(date.getHours()).padStart(2, "0");
  const minutes = String(date.getMinutes()).padStart(2, "0");
  const seconds = String(date.getSeconds()).padStart(2, "0");

  return `${year}-${month}-${day} ${hours}:${minutes}:${seconds}`;
}

function formatShortDateTime(timestamp: number): string {
  const date = new Date(timestamp);
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  const hours = String(date.getHours()).padStart(2, "0");
  const minutes = String(date.getMinutes()).padStart(2, "0");
  return `${month}-${day} ${hours}:${minutes}`;
}

function formatDuration(seconds: number): string {
  const safeSeconds: number = Math.max(0, seconds);
  const minutes: number = Math.floor(safeSeconds / 60);
  const remainSeconds: number = safeSeconds % 60;
  return `${minutes}分${String(remainSeconds).padStart(2, "0")}秒`;
}

// 通用方法，保留指定小数位数
function toFixedNumber(value: number, decimalPlaces: number = 4): number {
  const factor = Math.pow(10, decimalPlaces);
  return Math.round(value * factor) / factor;
}

function degreesToRadians(degrees: number): number {
  return degrees * Math.PI / 180;
}
