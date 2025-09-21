import { abilityAccessCtrl, common, PermissionRequestResult ,Permissions } from '@kit.AbilityKit';
import { sensor } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import window from '@ohos.window';
import { geoLocationManager } from '@kit.LocationKit';
import http from '@ohos.net.http';
import { JSON } from '@kit.ArkTS';


import {BleManagement, wt_SensorData} from '../utils/bluetoothManage'
import {MqttManagement, mqttUploadData, get_level, level_rec, get_group, group_rec, sailboat_data, original_data, WindDataMessage} from '../utils/mqtt'
import {DataUploader} from '../utils/updataloader'

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
const gps_accuracy_set: number = 30;
//选择教练艇
let windBoatsource: number = -1;

//测试延时用
let now_time: number = 0;
let dur_time: number = 0;

//测试gps更新次数
let location_change: number = 0;

//gps定时器
let gpsTimer: number | undefined = undefined;


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

//上传服务器数据内容格式
interface UploadData {
  heartRate: number;
  location: number[];    // [经度, 纬度]
  speed: number;
  sensorData: number[];  // [x, y, z] 加速度
  timestamp: number;     // 添加时间戳
  lag_time: number;
  gps_change: number;
  ble_SensorData: ble_SensorData;
}

// 上传数据格式（带校验）
interface UploadData_check {
  uploaddata: UploadData;
  check: number;
}

// 服务器发回数据格式
interface ServerResponse {
  status: string;
  message: string;
  received_data: UploadData;
}

// 上传接口
interface IUploadResult {
  success: boolean;
  error?: string;  // 可选字段
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

interface acceleration {
  x : number;
  y : number;
  z : number;
}

interface angularVelocity {
  x : number;
  y : number;
  z : number;
}

interface angle {
  roll : number;
  pitch : number;
  yaw : number;
}

interface ble_SensorData {
  header: number;          // 数据包头 0x55
  flag: number;            // 标志位 0x61
  acceleration: acceleration;         // 加速度 (单位: m/s^2)
  angularVelocity: angularVelocity;   // 角速度 (单位: °/s)
  angle: angle;            // 角度 (单位: °)
  rawData: number[];       // 原始数据数组
  timestamp: number;       // 解析时间戳
}



function uploadDataToString(data: UploadData): string {
  // 按固定顺序拼接所有字段
  return [
    data.heartRate.toString(),
    data.location.join(','),
    data.speed.toString(),
    data.sensorData.join(','),
    data.timestamp.toString(),
    // data.lag_time.toString() // 新增字段
  ].join('|'); // 使用 | 分隔不同字段
}

// 异或校验
function xorChecksum(str: string): number {
  let checksum = 0;
  for (let i = 0; i < str.length; i++) {
    checksum ^= str.charCodeAt(i);
  }
  return checksum & 0xFF; // 返回单字节校验值 (0-255)
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



@Entry
@Component
struct Index {
  @Provide pageStackForComponentSharedPages: NavPathStack = new NavPathStack();

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

  @State sensorInterval: number = 50000000; //加速度传感器读取间隔 ns
  @State heartInterval: number = 1000000000; //心率读取间隔 ns

  //显示网络连接状态
  @State isConnected: boolean = false;
  @State connectionStatusColor: Color = Color.Red
  @State isbleConnected: boolean = false
  @State bleconnectionStatusColor: Color = Color.Red

  //显示上传状态
  @State isStartUpload: boolean = false;
  @State buttonString: string = '开始'

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
    this.mqttManager.destroy();

    this.isStartUpload = false;
    this.buttonString = '开始';
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
        // 第一次点击，开始上传
        this.connectWatchMqtt();
        this.startMqttSend();
        this.isStartUpload = true;
        this.buttonString = '停止';
      }
    }
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

  // 新增的状态变量
  @State currentStep: number = 0; // 0:测试 1: 选择level, 2: 选择group, 3: 主界面
  @State levelButtons: LevelButton[] = [];
  @State groupButtons: GroupButton[] = [];
  @State selectedLevelId: string = '';
  @State selectedGroupId: string = '';
  @State selectedmhmName: string = '';
  @State selectedmhmId: string = '';
  @State isLoading: boolean = false;
  @State selectedGroupColor: string = "#000000"; //默认黑色


  //缓存文件用
  //获取应用沙箱路径
  context = this.getUIContext().getHostContext() as common.UIAbilityContext;
  // CACHE_FILE_PATH = `${this.context.getApplicationContext()}/cache/data_cache.json`;
  CACHE_FILE_PATH = 'internal://cache/cache.txt';

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


  build() {
    Column() {
      Row() {
        Text(`服务器`)
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
        Circle()
          .width(8)
          .height(8)
          .fill(this.connectionStatusColor)
          .margin({ left: 1 })
        Text(` | 姿态`)
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
        Circle()
          .width(8)
          .height(8)
          .fill(this.bleconnectionStatusColor)
          .margin({ left: 1 })
      }
      .justifyContent(FlexAlign.Center)
      .justifyContent(FlexAlign.Start)
      .margin({ top: 10 })

      // 根据当前步骤显示不同的界面
      if (this.currentStep === 1) {
        this.buildLevelSelection()
      } else if (this.currentStep === 2) {
        this.buildGroupSelection()
      } else if (this.currentStep === 3) {
        this.buildMainInterface()
      } else if (this.currentStep === 0) {
        this.buildWindSelection();
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(0x000000)
  }

  @Builder
  buildWindSelection() {
    Row() {
      Button('1').onClick((event: ClickEvent) => {
        windBoatsource = 1;
        this.currentStep = 1;
      })
        .width(50)
        .margin({right : 15})
      Button('2').onClick((event: ClickEvent) => {
        windBoatsource = 2;
        this.currentStep = 1;
      })
        .width(50)
        .margin({right : 15})

      Button('3').onClick((event: ClickEvent) => {
        windBoatsource = 3;
        this.currentStep = 1;
      })
        .width(50)
    }
    .margin({top : 50})
    .margin({bottom : 20})

    Row(){
      Button('4').onClick((event: ClickEvent) => {
        windBoatsource = 4;
        this.currentStep = 1;
      })
        .width(50)
        .margin({right : 15})

      Button('5').onClick((event: ClickEvent) => {
        windBoatsource = 5;
        this.currentStep = 1;
      })
        .width(50)

    }
  }

  // 构建级别选择界面
  @Builder
  buildLevelSelection() {
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
        Scroll(){
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
        .height('60%') // 设置滚动区域高度
        .scrollable(ScrollDirection.Vertical) // 垂直滚动
        .scrollBar(BarState.On) // 显示滚动条
        .scrollBarColor(Color.Gray) // 滚动条颜色
        .edgeEffect(EdgeEffect.Spring) // 滚动边缘效果
      }
    }
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .padding(20)
  }

  // 修改 buildGroupSelection 方法
  @Builder
  buildGroupSelection() {
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
          .onClick(() => this.currentStep = 1)
      } else {
        // 使用 Scroll 组件包装按钮列表
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
                .width('80%') // 限制按钮宽度
                .onClick(() => this.selectGroup(item.groupId, item.mhmId, item.mhmName, item.color))
            })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .height('60%') // 设置滚动区域高度
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.On)
        .scrollBarColor(Color.Gray)
        .edgeEffect(EdgeEffect.Spring)

        Button('返回')
          .fontSize(14)
          .type(ButtonType.Capsule)
          .backgroundColor(0x666666)
          .fontColor(Color.White)
          .margin({ bottom: 10 })
          .onClick(() => this.currentStep = 1)
      }
    }
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .padding(15)
  }

  @Builder
  buildMainInterface() {
    // 使用 NavDestination 包装主界面内容
    NavDestination() {
      Scroll() {
        Column() {
          Text(`${this.selectedmhmName} : ${windBoatsource}`)
            .fontSize(12)
            .fontColor(Color.Gray)

          Text(`${(this.speed * 1.94).toFixed(1)}`)
            .fontSize(100)
            .fontWeight(FontWeight.Medium)
            .textAlign(TextAlign.Center)

          // 上传按钮区域
          Stack() {
            // 上传按钮区域
            Stack() {
              // 背景按钮（冷却时变灰色）
              Button(this.buttonString)
                .fontSize(12)
                .type(ButtonType.Capsule)
                .stateEffect(!this.isCoolingDown) // 冷却时禁用状态效果
                .backgroundColor(this.isCoolingDown ? 0x888888 :
                  (this.isLongPressing ? 0xff0000 : 0x317aff))
                .fontColor(Color.White)
                .width(100)
                .height(30)
                .opacity(this.isCoolingDown ? 0.6 : 1) // 冷却时半透明
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
                    case TouchType.Move:
                      // 可以添加移动时的处理逻辑
                      break;
                  }
                })

              // 长按进度条
              if (this.isLongPressing && this.isStartUpload) {
                Progress({
                  value: this.longPressProgress,
                  total: 100,
                  type: ProgressType.Ring
                })
                  .width(50)
                  .height(50)
                  .color(Color.Red)
                  .backgroundColor(0x00000000)
              }

              // 冷却指示器
              if (this.isCoolingDown) {
                Progress({
                  value: 100,
                  total: 100,
                  type: ProgressType.Ring
                })
                  .width(46)
                  .height(46)
                  .color(Color.Gray)
                  .backgroundColor(0x00000000)
              }
            }
            .width(120)
            .height(40)

            // 提示文字
            if (this.isStartUpload) {
              // Text(this.isLongPressing ?
              //   `松开取消 (${Math.round(this.longPressProgress)}%)` :
              //   (this.isCoolingDown ? '冷却中...' : '长按3秒停止上传'))
              //   .fontSize(12)
              //   .fontColor(this.isCoolingDown ? Color.Gray :
              //     (this.isLongPressing ? Color.Red : Color.Gray))
              //   .margin({ top: 5 })
            }
          }
          .width(120)
          .height(40)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding(10)
      }
      .width('100%')
      .height('100%')
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Auto)
    }
    .onBackPressed(() => {
      // 返回 true 表示已处理返回事件，阻止默认返回行为
      return false;
    })
  }

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

  // 同样，在 selectLevel 方法中加载 group 数据时也要明确类型
  async selectLevel(levelId: string) {
    // 更新选中状态
    this.levelButtons = this.levelButtons.map(item => ({
      levelId: item.levelId,
      levelName: item.levelName,
      selected: item.levelId === levelId
    } as LevelButton));

    this.selectedLevelId = levelId;
    this.isLoading = true;

    try {
      // 根据选中的levelId获取group数据
      const groupData = await get_group(this.selectedLevelId, is_test); // 这里可能需要修改get_group函数来接收levelId参数

      if (groupData.success && groupData.data.length > 0) {
        // 明确指定类型
        this.groupButtons = groupData.data.map((item) => ({
          groupId: item.groupId,
          mhmName: item.mhmName,
          mhmId: item.mhmId,
          selected: false,
          color: item.color || '#317aff'
        } as GroupButton)); // 使用类型断言
        this.currentStep = 2; // 切换到group选择界面
      } else {
        console.error('获取分组数据失败');
      }
    } catch (error) {
      console.error('加载分组数据错误:', error);
    } finally {
      this.isLoading = false;
    }
  }

  // 在 selectGroup 方法中也使用类型断言
  selectGroup(groupId: string, mhmId: string, mhmName: string, groupColor: string) {
    // 找到选中的分组对象来获取颜色
    const selectedGroup = this.groupButtons.find(item => item.groupId === groupId);
    const color = selectedGroup ? selectedGroup.color : '#317aff'; // 默认蓝色
    // 更新选中状态
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
    this.mygroup.data[0].color = color;

    // 切换到主界面
    this.currentStep = 3;

    console.info(`已选择: LevelId=${this.selectedLevelId}, GroupId=${this.selectedGroupId}, MhmName=${this.selectedmhmName}, Color=${this.selectedGroupColor}`);
  }

  // 添加清除选择的方法
  clearAllSelections() {
    // 重置级别选择
    this.levelButtons = this.levelButtons.map(item => ({
      levelId: item.levelId,
      levelName: item.levelName,
      selected: false
    } as LevelButton));

    // 重置分组选择
    this.groupButtons = this.groupButtons.map(item => ({
      groupId: item.groupId,
      mhmName: item.mhmName,
      mhmId: item.mhmId,
      color: item.color,
      selected: false
    } as GroupButton));

    // 清空选择记录
    this.selectedLevelId = '';
    this.selectedGroupId = '';
    this.selectedGroupColor = '#000000';

    // 重置mygroup数据
    this.mygroup.data[0].groupId = "err";
    this.mygroup.data[0].mhmId = "err";
    this.mygroup.data[0].mhmName = "err";
    this.mygroup.data[0].color = "err";

    // 返回到级别选择界面
    this.currentStep = 1;

    console.info('已清除所有选择，可以重新选择');
  }

  //监测时间10s，屏幕常量关闭
  aboutToAppear() {
    this.check_test();
    this.mqttManager.setHost(user_url);
    this.requestPermissionAndStart();
    this.loadLevels();
    this.startCheckTimer(3000);
    this.keepScreenOn(true);
  }

  //设置屏幕常亮
  async keepScreenOn(enable: boolean) {
    try {
      const win = await window.getLastWindow(getContext(this));
      await win.setWindowKeepScreenOn(enable);
    } catch (err) {
      console.error('设置屏幕常亮失败:', JSON.stringify(err));
    }
  }

  //权限获取
  async requestPermissionAndStart() {
    const atManager = abilityAccessCtrl.createAtManager();
    const context = getContext(this) as common.UIAbilityContext;

    const permissions: Permissions[] = [
      'ohos.permission.READ_HEALTH_DATA' as Permissions,
      'ohos.permission.LOCATION' as Permissions,
      'ohos.permission.APPROXIMATELY_LOCATION' as Permissions,
      'ohos.permission.ACCELEROMETER' as Permissions,
      'ohos.permission.INTERNET' as Permissions,
      'ohos.permission.ACCESS_BLUETOOTH' as Permissions,
      'ohos.permission.DISCOVER_BLUETOOTH' as Permissions,
      'ohos.permission.USE_BLUETOOTH' as Permissions
    ];

    atManager.requestPermissionsFromUser(
      context,
      permissions,
      (err: BusinessError, data: PermissionRequestResult) => {
        if (err) {
          console.error(`权限请求失败: code=${err.code}, message=${err.message}`);
          return;
        }

        // 遍历授权结果
        for (let i = 0; i < data.authResults.length; i++) {
          if (data.authResults[i] !== 0) {
            console.warn(`权限 ${data.permissions[i]} 被拒绝!`);
          }
          else {
            console.log(`权限 ${data.permissions[i]} 被通过`);
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
          this.wtBLE.checkDevice();

          if(this.currentStep == 3){
            // this.connectWatchMqtt();
          }

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

    this.MqttTimer = setInterval(async () => {

      let myWindData: WindDataMessage = this.mqttManager.getLatestWindData();
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

      //航向存在时
      if(this.myMqttUploadData.data.headingT){
        this.myMqttUploadData.data.headingT = Math.trunc(this.myMqttUploadData.data.headingT);
        this.myMqttUploadData.data.headingM = Math.trunc( (this.myMqttUploadData.data.headingT - declination) % 360 );

        let A : number = this.myMqttUploadData.data.headingM - this.myMqttUploadData.data.windDirection
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
        if(Math.abs(this.myMqttUploadData.data.headingM - this.myMqttUploadData.data.yaw) <= 90){
          w= this.myMqttUploadData.data.headingM - this.myMqttUploadData.data.yaw;
        }else if(this.myMqttUploadData.data.headingM - this.myMqttUploadData.data.yaw > 90){
          w= this.myMqttUploadData.data.headingM - this.myMqttUploadData.data.yaw - 360;
        }else if(this.myMqttUploadData.data.headingM - this.myMqttUploadData.data.yaw < -90){
          w = 360 + this.myMqttUploadData.data.headingM - this.myMqttUploadData.data.yaw
        }

        this.myMqttUploadData.data.leeway = this.calcLeeway(this.myMqttUploadData.data.sailStatus, w);

        //角度和VMG计算
        if(Math.abs(this.myMqttUploadData.data.headingM - this.myMqttUploadData.data.windDirection) <= 180){
          this.myMqttUploadData.data.angle = Math.abs(this.myMqttUploadData.data.headingM - this.myMqttUploadData.data.windDirection);
        }else {
          this.myMqttUploadData.data.angle = 360 - Math.abs(this.myMqttUploadData.data.headingM - this.myMqttUploadData.data.windDirection);
        }
        this.myMqttUploadData.data.vmg = toFixedNumber(this.myMqttUploadData.data.speed * Math.cos(this.myMqttUploadData.data.angle));

        //自定义角度和自定义VMG计算
        if(Math.abs(this.myMqttUploadData.data.headingM - this.myMqttUploadData.data.customWindDirection) <= 180){
          this.myMqttUploadData.data.customAngle = Math.abs(this.myMqttUploadData.data.headingM - this.myMqttUploadData.data.customWindDirection);
        }else {
          this.myMqttUploadData.data.customAngle = 360 - Math.abs(this.myMqttUploadData.data.headingM - this.myMqttUploadData.data.customWindDirection);
        }
        this.myMqttUploadData.data.customVmg = toFixedNumber(this.myMqttUploadData.data.speed * Math.cos(this.myMqttUploadData.data.customAngle)); //保留四位小数

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
        data: `${this.heartRate}|-1`
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

      // let winddatalist: WindDataMessage[] = [];
      // winddatalist = this.mqttManager.getAllWindData();
      // console.log(JSON.stringify(winddatalist));


    }, intervalMs);
  }

  //定时监测网络状态
  async startCheckTimer(intervalMs : number = 1000) {

    // "longitude":"121.493807","latitude":"31.300226"

    this.checkTimer = setInterval(async () => {

      let success = this.mqttManager.isConnected;

      if(success == true){
        console.error('已连接')
        this.isConnected = true;
        this.connectionStatusColor = Color.Green;
        // this.dataUploader.tryStartUpload();
      }
      else {
        console.error('重新连接中')
        this.isConnected = false;
        this.connectionStatusColor = Color.Red;
        if(windBoatsource != -1){
          await this.connectWatchMqtt();
        }
        // this.startMqttSend()
      }

      success = false;
      success = this.wtBLE.isConnected()
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
        // this.startMqttSend()
      }

    }, intervalMs);
    console.info(`启动定时监测，间隔: ${intervalMs}ms`);
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

      // this.dataUploader.addDataToQueue(sensor_data);
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
    if (this.uploadTimer !== undefined || this.uploadTimer_buffer !== undefined) {
      clearInterval(this.uploadTimer);
      clearInterval(this.uploadTimer_buffer);
      // clearInterval(this.checkTimer);
      clearInterval(this.MqttTimer);
      this.uploadTimer = undefined;
      this.uploadTimer_buffer = undefined;
      // this.checkTimer = undefined;
      this.MqttTimer = undefined;
      console.info('停止定时上传');
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
        // console.log('实时定位：纬度=', location.latitude, ' 经度=', location.longitude)
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
        console.log(`位置精度： ${location.accuracy}，航向精度：${location.directionAccuracy}`)
      })
    }
    catch(error){
      console.error('定位失败：'+ error.message);}
    // throw new Error('Method not implemented.');
  }

  //通过定时器读取位置信息
  async startGpsTimer(intervalMs: number = 1000) {
    gpsTimer = setInterval(async () => {
      try {
        const location = await geoLocationManager.getCurrentLocation(this.timer_request);
        // console.info(`经度：${location.longitude}, 纬度：${location.latitude}`);
        this.location[0] = location.longitude;
        this.location[1] = location.latitude;
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

    try {
      const testUploadCapRequest = http.createHttp();
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
        error
      } as ITestResult;
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

    const connected = await this.mqttManager.connect(clientId);

    if(connected) {
      console.info('手表端MQTT连接成功');
      //订阅风速
      if(windBoatsource != -1){
        this.mqttManager.subscribe(`gateway/env/wind/${tenantCode}/${windBoatsource}`,1);
      }
      // console.info(this.mqttManager.getConnectionInfo());
    }
  }

  aboutToDisappear() {
    try {
      sensor.off(sensor.SensorId.HEART_RATE);
      sensor.off(sensor.SensorId.ACCELEROMETER_UNCALIBRATED);
      this.stopUploadTimer();
      this.mqttManager.destroy();
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

// 通用方法，保留指定小数位数
function toFixedNumber(value: number, decimalPlaces: number = 4): number {
  const factor = Math.pow(10, decimalPlaces);
  return Math.round(value * factor) / factor;
}