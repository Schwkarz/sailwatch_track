import { abilityAccessCtrl, common, PermissionRequestResult ,Permissions } from '@kit.AbilityKit';
import { sensor } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import window from '@ohos.window';
import { geoLocationManager } from '@kit.LocationKit';
import http from '@ohos.net.http';
import Queue from '@ohos.util.Queue';
import { ble } from '@kit.ConnectivityKit';
import {BleManagement} from '../utils/bluetoothManage'
import {MqttManagement, mqttUploadData, get_level, level_rec, get_group, group_rec, sailboat_data, original_data} from '../utils/mqtt'

const tenantCode: number = 1188;

//测试延时用
let now_time: number = 0;
let dur_time: number = 0;

//测试gps更新次数
let location_change: number = 0;

//gps定时器
let gpsTimer: number | undefined = undefined;

//定义DataUploader类，完成数据包入队列和排队上传任务
class DataUploader {
  private dataQueue: Queue<UploadData_check> = new Queue(); // 缓冲队列

  public  isNetworkAvailable: boolean = false;
  public  dataQueueLength: number = 0;

  private isUploading: boolean = false;
  private readonly MAX_QUEUE_SIZE = 3000; // 队列最大容量
  private tryupload_times: number = 0;
  private success: boolean = false;

  // 数据采集后调用此方法入队
  public addDataToQueue(sensorData: UploadData): void {
    // 1. 构造带校验的数据包
    const dataPacket: UploadData_check = {
      uploaddata: sensorData,
      check: xorChecksum(uploadDataToString(sensorData))
    };

    // 2. 入队前检查队列容量
    if (this.dataQueue.length >= this.MAX_QUEUE_SIZE) {
      console.warn('队列已满，丢弃最旧数据');
      this.dataQueue.pop(); // 移除队首数据
    }

    // 3. 数据入队
    this.dataQueue.add(dataPacket);
    console.log(`数据已入队，当前队列大小: ${this.dataQueue.length}`);


    // 4. 尝试触发上传
    this.tryStartUpload();
  }

  // 网络状态检测方法
  public async checkNetwork(): Promise<boolean> {
    this.dataQueueLength = this.dataQueue.length;
    try {
      const httpRequest = http.createHttp();

      let ble_Data: ble_SensorData = {
        header : 99,
        flag : 99,
        acceleration : {
          x : 99,
          y : 99,
          z : 99
        },
        angularVelocity : {
          x : 99,
          y : 99,
          z : 99
        },
        angle : {
          roll : 99,
          pitch : 99,
          yaw : 99
        },
        rawData : [],
        timestamp : 99
      }


      const data: UploadData = {
        heartRate: 99,
        location: [99,99,99],
        speed: 99,
        sensorData: [99,99,99],
        timestamp: 99,
        lag_time: 99,
        gps_change: 99,
        ble_SensorData: ble_Data
      }
      const data_check: UploadData_check = {
        uploaddata: data,
        check: xorChecksum(uploadDataToString(data))
      }

      const response = await httpRequest.request(
        "http://124.222.53.152:8080/api/data", // 测试接口
        {
          method: http.RequestMethod.POST,
          connectTimeout: 3000,
          extraData: JSON.stringify(data_check),
          header: { "Content-Type": "application/json" }
        }
      );
      httpRequest.destroy();
      return response.responseCode === http.ResponseCode.OK;
    } catch(err) {
      // console.error(err.message)
      return false;
    }
  }

  // 上传控制逻辑
  public async tryStartUpload(): Promise<void> {
    // 避免重复上传
    if (this.isUploading) return;

    // 检查网络
    this.isNetworkAvailable = await this.checkNetwork();
    // console.log(String(this.isNetworkAvailable))


    if (this.isNetworkAvailable && this.dataQueue.length > 0) {
      this.startUploadFromQueue();
    }
  }

  // 从队列上传数据
  private async startUploadFromQueue(): Promise<void> {
    this.isUploading = true;

    while (this.dataQueue.length > 0 && this.isNetworkAvailable) {
      const dataPacket = this.dataQueue.getFirst(); // 查看队首元素但不移除

      try {
        if (this.tryupload_times < 3){
          this.success = await this.uploadSinglePacket(dataPacket);
          if (this.success) {
            this.dataQueue.pop(); // 上传成功才移除
            console.log(`数据上传成功，剩余队列: ${this.dataQueue.length}`);
          } else {
            this.tryupload_times += 1;
            console.error('上传失败')
            break; // 上传失败终止循环
          }
        }
        else {
          this.dataQueue.pop();
          console.warn('队头错误，移除')
          this.tryupload_times = 0;
        }

      } catch (error) {
        console.error('上传异常:', error);
        break;
      }
    }

    this.isUploading = false;
  }

  // 单包上传逻辑
  private async uploadSinglePacket(packet: UploadData_check): Promise<boolean> {
    const httpRequest = http.createHttp();

    try {
      const response = await httpRequest.request(
        "http://124.222.53.152:8080/api/data",
        {
          method: http.RequestMethod.POST,
          header: { "Content-Type": "application/json" },
          extraData: JSON.stringify(packet),
          connectTimeout: 5000
        }
      );

      return response.responseCode === http.ResponseCode.OK;
    } catch (error) {
      this.isNetworkAvailable = false; // 标记网络不可用
      return false;
    } finally {
      httpRequest.destroy();
    }
  }

  // 在类初始化时启动定时器
  private setupRetryTimer(timeInterval:number = 3000): void {
    setInterval(async () => {
      if (!this.isUploading && this.dataQueue.length > 0) {
        await this.tryStartUpload();
      }
    }, timeInterval); // 默认每3秒尝试一次
  }

}








// 1. 定义必要的接口
interface TestData {
  key1: string;
  key2: string;
}

interface HttpHeaders {
  "Content-Type": string;
}

interface RequestContent {
  content: string;
  headers: HttpHeaders;
}

//上传服务器数据内容格式
interface UploadData {
  heartRate: number;
  location: number[];    // [经度, 纬度]
  speed: number;
  sensorData: number[];  // [x, y, z] 加速度
  timestamp: number;     // 添加时间戳
  lag_time;
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

// 数据容量HTTP请求配置类型
interface IHttpRequestConfig {
  method: string;
  body: string;
  headers?: Record<string, string>;
  timeout?: number;
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
  @State heartRate: number = 0;
  @State location: Array<number> = [0,0]; //[0]经度 [1]纬度
  sensor_data: Array<number> = [0,0,0,0,0,0]; //x,y,z加速度
  @State speed: number = 0;
  //上传数据的定时器变量
  @State uploadTimer: number | undefined = undefined;
  @State uploadTimer_buffer: number | undefined = undefined;
  @State uploadInterval: number = 100; // 100ms上传一次

  @State sensorInterval: number = 50000000; //加速度传感器读取间隔 ns
  @State heartInterval: number = 1000000000; //心率读取间隔 ns

  //显示网络连接状态
  @State isConnected: boolean = false;
  @State connectionStatusColor: Color = Color.Red

  //显示上传状态
  @State isStartUpload: boolean = false;
  @State buttonString: string = '开始上传'

  dataUploader: DataUploader = new DataUploader();
  @State dataQueueLength : number = 0;

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

    headingT: 0,
    headingM: 0,
    sailStatus: null,
    leeway: null,

    speed: 0,
    standardSpeed: null,
    customStandardSpeed: null,

    angle: null,
    vmg: null,
    standardVmg: null,

    customAngle: null,
    customVmg: null,
    customStandardVmg: null,

    windSourceBoatCode: "000",
    windSpeed: 0,
    windDirection: 0,
    customWindSpeed: 0,
    customWindDirection: 0,

    yaw: 0,
    rol: 0,
    posture: null,

    hr: [0,0]
  }

  myMqttUploadData: mqttUploadData = {
    mHmId: "000",
    ts: "000",
    data: this.myboat_data
  }

  //mqtt发送管理器
  mqttManager: MqttManagement = new MqttManagement(
    '180.107.109.102',
    1883,
    false
  );

  //缓存文件用
  //获取应用沙箱路径
  context = this.getUIContext().getHostContext() as common.UIAbilityContext;
  // CACHE_FILE_PATH = `${this.context.getApplicationContext()}/cache/data_cache.json`;
  CACHE_FILE_PATH = 'internal://cache/cache.txt';

  //请求位置信息的参数
  request: geoLocationManager.ContinuousLocationRequest= {
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
        Text(`服务器连接状态：`)
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
        Circle()
          .width(8)
          .height(8)
          .fill(this.connectionStatusColor)
          .margin({ left: 3 })
      }
      .justifyContent(FlexAlign.Center)
      .margin({ bottom: 10 })

      Text(`水上运动监测`)
        .fontSize(23)
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
        .margin({ bottom: 12 })
      Text(`❤️ 心率：${this.heartRate} bpm`)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
        .margin({ bottom: 10 })

      Row() {
        Column(){
          Text(`经度：${this.location[0].toFixed(3)}`)
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .textAlign(TextAlign.Center)
            .margin({ bottom: 10 })
          Text(`纬度：${this.location[1].toFixed(3)}`)
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .textAlign(TextAlign.Center)
            .margin({ bottom: 10 })
        }
        .margin({ right: 20})
        Text(`队列：${this.dataQueueLength}`)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center)
          .margin({ bottom: 10 })
      }
      // Text(`x:${this.sensor_data[0].toFixed(2)},y:${this.sensor_data[1].toFixed(2)},z:${this.sensor_data[2].toFixed(2)}`)
      //   .fontSize(18)
      //   .fontWeight(FontWeight.Medium)
      //   .textAlign(TextAlign.Center)
      Button(this.buttonString)
        .fontSize(15)
        .buttonStyle(0)
        .type(ButtonType.Capsule)
        .stateEffect(true)
        .backgroundColor(0x317aff)
        .fontColor(0xCCCCCC)
        .onClick((event?: ClickEvent)=> {
          if(event){
            if(this.isStartUpload)
            {
              this.stopUploadTimer();
              this.isStartUpload = false;
              this.buttonString = '开始上传'
            }
            else {
              this.startUploadTimer_queue(this.uploadInterval);
              this.isStartUpload = true;
              this.buttonString = '停止上传'
            }

          }
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(0x000000)
  }

  aboutToAppear() {
    this.requestPermissionAndStart();
    this.startCheckTimer();
    this.keepScreenOn(true);
    // this.wtBLE.checkDevice();
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
      // 'ohos.permission.MANAGE_BLUETOOTH' as Permissions,
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
          this.startAccelerometer();//加速度传感器
          // this.startUploadTimer_queue(this.uploadInterval);//通过队列上传
          this.startCheckTimer();//定时监测服务器是否连接成功
          // this.startGpsTimer(300);//通过定时器定位
          // this.uploadData_test();//上传数据（测试用）
          // this.startUploadTimer(this.uploadInterval);//定时上传数据
          // this.runCapacityTests();//上传数据容量测试
          this.wtBLE.checkDevice();

          this.connectWatchMqtt();

        } else {
          console.warn('部分权限未授权，功能可能受限');
        }
      }
    );
  }

  // 网络状态检测
  async checkNetwork(): Promise<boolean> {
    try {
      const httpRequest = http.createHttp();
      const response = await httpRequest.request(
        "http://124.222.53.152:8080/api/data",
        {
          method: http.RequestMethod.POST,
          connectTimeout: 6000,
          header: { "Content-Type": "application/json" },
        }
      );
      this.isConnected = response.responseCode === http.ResponseCode.OK;
      this.connectionStatusColor = this.isConnected ? Color.Green : Color.Red;
      return this.isConnected;
    } catch (error) {
      this.isConnected = false;
      this.connectionStatusColor = Color.Red;
      return false;
    }
  }

  private async tryUpload(httpRequest: http.HttpRequest): Promise<IUploadResult> {

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

    const sensor_data: UploadData = {
      heartRate: this.heartRate,
      location: [...this.location],
      speed: this.speed,
      sensorData: [...this.sensor_data.slice(0,3)],
      timestamp: Date.now(),
      lag_time: dur_time,
      gps_change: location_change,
      ble_SensorData: ble_Data
    };

    // console.log(uploadDataToString(sensor_data))

    const data: UploadData_check = {
      uploaddata: sensor_data,
      check: xorChecksum(uploadDataToString(sensor_data))
    };

    try {
      const response = await httpRequest.request(
        "http://124.222.53.152:8080/api/data",
        {
          method: http.RequestMethod.POST,
          header: { "Content-Type": "application/json" },
          extraData: JSON.stringify(data),
          connectTimeout: 8000,  // 适当缩短超时时间
          readTimeout: 8000
        }
      );
      let serverResponse: ServerResponse = JSON.parse(String(response.result));
      now_time = new Date().getTime();
      dur_time = now_time - serverResponse.received_data.timestamp;
      // const result: string = `${now_time},${serverResponse.received_data.timestamp},${dur_time}`;
      // console.log(result);

      return { success: response.responseCode === http.ResponseCode.OK };
    } catch (error) {
      console.error(`上传尝试失败: ${JSON.stringify(error)}`);
      return {
        success: false,
        error: error.message
      };
    }
  }

  //优化后上传方案
  async uploadData() {

    //先检查网络连接
    if (!await this.checkNetwork()) {
      console.warn('网络不可用，跳过上传');
      return;
    }

    const httpRequest = http.createHttp();
    try {
      // 重试机制（最多3次）
      let retryCount = 0;
      while (retryCount < 3) {
        const result = await this.tryUpload(httpRequest);
        if (result.success) {
          this.isConnected = true;
          this.connectionStatusColor = Color.Green;
          return;
        }
        retryCount++;
        // 明确指定Promise的泛型参数为void
        await new Promise<void>(resolve => setTimeout(resolve, 1000 * retryCount)); // 指数退避
      }
      this.isConnected = false;
      this.connectionStatusColor = Color.Red;
    } finally {
      httpRequest.destroy();
    }
  }

  //定时监测网络状态
  async startCheckTimer(intervalMs : number = 1000) {

    // "longitude":"121.493807","latitude":"31.300226"

    let checkTimer = setInterval(async () => {

      this.myMqttUploadData.mHmId = this.mygroup.data[0].mhmId;
      this.myMqttUploadData.ts = formatDateTime(new Date());

      this.myMqttUploadData.data.mHmName = this.mygroup.data[0].mhmName;
      this.myMqttUploadData.data.color = this.mygroup.data[0].color;

      this.myMqttUploadData.data.longitude = String(this.location[0].toFixed(6));
      this.myMqttUploadData.data.latitude = String(this.location[1].toFixed(6));

      this.myMqttUploadData.data.speed = this.speed;

      this.myMqttUploadData.data.yaw = this.wtBLE.ble_sensorData.angle.yaw;
      this.myMqttUploadData.data.rol = this.wtBLE.ble_sensorData.angle.roll;

      this.myMqttUploadData.data.hr = [this.heartRate,-1];

      // 发布航行数据消息
      await this.mqttManager.publish(`mobile/up/general-train/${tenantCode}/1964940865353916418/${this.mygroup.data[0].mhmId}`, JSON.stringify(this.myMqttUploadData),1);

      let gps_original_data: original_data = {
        mHmId: this.myMqttUploadData.mHmId,
        ts: this.myMqttUploadData.ts,
        dataType: "gps",
        data: `A,${this.myMqttUploadData.data.longitude},${this.myMqttUploadData.data.latitude},${this.speed.toFixed(4)},${this.myMqttUploadData.data.headingT},${this.myMqttUploadData.data.headingM}`
      }
      // 发布原始数据
      // await this.mqttManager.publish(`mobile/up/orignal/${tenantCode}/${this.mylevel.data[0].levelId}/${this.mygroup.data[0].mhmId}`, JSON.stringify(gps_original_data),1);


      this.dataQueueLength = this.dataUploader.dataQueueLength;

      let success = await this.dataUploader.checkNetwork();

      if(success == true){
        this.isConnected = true;
        this.connectionStatusColor = Color.Green;
        this.dataUploader.tryStartUpload();
      }
      else {
        this.isConnected = false;
        this.connectionStatusColor = Color.Red;
      }
    }, intervalMs);
    console.info(`启动定时监测，间隔: ${intervalMs}ms`);
  }

  //添加定时上传
  startUploadTimer(intervalMs : number = 5000) {
    this.stopUploadTimer();
    this.uploadTimer = setInterval(() => {
      this.uploadData();
    }, intervalMs);
    console.info(`启动定时上传，间隔: ${intervalMs}ms`);
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

      const sensor_data: UploadData = {
        heartRate: this.heartRate,
        location: [...this.location],
        speed: this.speed,
        sensorData: [...this.sensor_data.slice(0,3)],
        timestamp: Date.now(),
        lag_time: dur_time,
        gps_change: location_change,
        ble_SensorData: ble_Data
      };
      // console.log(uploadDataToString(sensor_data))

      const data: UploadData_check = {
        uploaddata: sensor_data,
        check: xorChecksum(uploadDataToString(sensor_data))
      };

      this.dataUploader.addDataToQueue(sensor_data);

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
      this.uploadTimer = undefined;
      this.uploadTimer_buffer = undefined;
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
      geoLocationManager.on('locationChange',this.request, (location: geoLocationManager.Location) => {
        // console.log('实时定位：纬度=', location.latitude, ' 经度=', location.longitude)
        if (location.longitude != this.location[0] || location.latitude != this.location[1]){
          this.location[0] = location.longitude;
          this.location[1] = location.latitude;
          location_change += 1;
        }
        if(location.speed != this.speed){
          this.speed = location.speed;
        }
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
      const response = await testUploadCapRequest.request(
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
    //拿到level数据
    this.mylevel = await get_level();
    //拿到group数据
    this.mygroup = await get_group();

    this.mqttManager.setCredentials('sailboat_watch', 'sailboat_watch_2024');

    const clientId = `sailboat_watch_${generateRandomNum()}`;

    const connected = await this.mqttManager.connect(clientId);

    if(connected) {
      console.info('手表端MQTT连接成功');
      console.info(this.mqttManager.getConnectionInfo());

      this.myMqttUploadData.ts = formatDateTime(new Date())
      // 示例发布一条测试消息
      await this.mqttManager.publish(`mobile/up/general-train/${tenantCode}/1964940865353916418/000`, JSON.stringify(this.myMqttUploadData),1);
    }
  }



  aboutToDisappear() {
    try {
      sensor.off(sensor.SensorId.HEART_RATE);
      sensor.off(sensor.SensorId.ACCELEROMETER_UNCALIBRATED);
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