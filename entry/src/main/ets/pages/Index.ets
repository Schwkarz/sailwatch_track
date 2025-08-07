import { abilityAccessCtrl, common, PermissionRequestResult ,Permissions } from '@kit.AbilityKit';
import { sensor } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import window from '@ohos.window';
import { geoLocationManager } from '@kit.LocationKit';
import http from '@ohos.net.http';

//测试延时用
let now_time: number = 0;
let last_time: number = 0;

//上传数据包校验位
let check: number = 0;

//gps定时器
let gpsTimer: number | undefined = undefined;

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

interface UploadData {
  heartRate: number;
  location: number[];    // [经度, 纬度]
  sensorData: number[];  // [x, y, z] 加速度
  timestamp: number;     // 添加时间戳
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

function uploadDataToString(data: UploadData): string {
  // 按固定顺序拼接所有字段
  return [
    data.heartRate.toString(),
    data.location.join(','),
    data.sensorData.join(','),
    data.timestamp.toString()
  ].join('|'); // 使用|分隔不同字段
}

// 异或校验
function xorChecksum(str: string): number {
  let checksum = 0;
  for (let i = 0; i < str.length; i++) {
    checksum ^= str.charCodeAt(i);
  }
  return checksum & 0xFF; // 返回单字节校验值 (0-255)
}

@Entry
@Component
struct Index {
  @State heartRate: number = 0;
  @State location: Array<number> = [0,0]; //[0]经度 [1]纬度
  @State sensor_data: Array<number> = [0,0,0,0,0,0]; //x,y,z加速度
  //上传数据的定时器变量
  @State uploadTimer: number | undefined = undefined;
  @State uploadInterval: number = 100; // 0.1秒上传一次

  @State sensorInterval: number = 100000000; //加速度传感器读取间隔
  @State heartInterval: number = 100000000; //心率读取间隔

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
      Text(`📍 经度：${this.location[0].toFixed(10)}`)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
        .margin({ bottom: 10 })
      Text(`📍 纬度：${this.location[1].toFixed(10)}`)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
        .margin({ bottom: 10 })
      Text(`x:${this.sensor_data[0].toFixed(2)},y:${this.sensor_data[1].toFixed(2)},z:${this.sensor_data[2].toFixed(2)}`)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(0x000000)
  }

  aboutToAppear() {
    this.requestHeartRatePermissionAndStart();
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
  async requestHeartRatePermissionAndStart() {
    const atManager = abilityAccessCtrl.createAtManager();
    const context = getContext(this) as common.UIAbilityContext;

    const permissions: Permissions[] = [
      'ohos.permission.READ_HEALTH_DATA' as Permissions,
      'ohos.permission.LOCATION' as Permissions,
      'ohos.permission.APPROXIMATELY_LOCATION' as Permissions,
      'ohos.permission.ACCELEROMETER' as Permissions,
      'ohos.permission.INTERNET' as Permissions
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
          // this.startGpsTimer(300);//通过定时器定位
          // this.uploadData_test();//上传数据（测试用）
          this.startUploadTimer(this.uploadInterval);//定时上传数据
        } else {
          console.warn('部分权限未授权，功能可能受限');
        }
      }
    );
  }



  async uploadData() {
    // 每一个httpRequest对应一个HTTP请求任务，不可复用。
    const httpRequest = http.createHttp();
    const url = "http://124.222.53.152:8080/api/data";
    //需要上传的数据
    const sensor_data : UploadData = {
      heartRate: this.heartRate,
      location: [... this.location], // ...为扩展运算符，用于对数组或对象的浅拷贝
      sensorData: [...this.sensor_data.slice(0,3)],
      timestamp: new Date().getTime() //获取当前时间（ms级）
    }

    //将sensor_data转成字符串后，再进行异或校验
    const dataString : string = uploadDataToString(sensor_data);
    check = xorChecksum(dataString);

    const data : UploadData_check = {
      uploaddata: sensor_data,
      check: check
    }

    const headers : HttpHeaders = {
      "Content-Type" : "application/json"
    };

    try{
      check += 1; //递增校验
      const response = await httpRequest.request(
        url,
        {
          method: http.RequestMethod.POST,
          header: headers,
          // 当使用POST请求时此字段用于传递请求体内容，具体格式与服务器端一致。
          extraData: JSON.stringify(data),
          connectTimeout: 10000, // 可选，默认为60000ms。
          readTimeout: 10000, // 可选，默认为60000ms。
        }
      );

      //处理响应
      if(response.responseCode === http.ResponseCode.OK) {
        // console.info('上传成功', JSON.stringify(data))
        try{
          //接收服务器发回的数据
          const serverResponse: ServerResponse = JSON.parse(String(response.result));
          now_time = new Date().getTime();
          console.info('上传+下载延时', now_time - serverResponse.received_data.timestamp); //ms延迟
          // console.info('上传成功，服务器响应：', serverResponse);
        } catch (parseError) {
          console.error('服务器响应解析失败:', parseError);
        }
      } else {
        console.error(`上传失败，状态码：${response.responseCode}`);
      }
    } catch(error) {
      console.error('上传失败：', JSON.stringify(error));
    } finally {
      httpRequest.destroy();
    }
  }

  //添加定时上传
  startUploadTimer(intervalMs : number = 5000) {
    this.stopUploadTimer();
    this.uploadTimer = setInterval(() => {
      this.uploadData();
    }, intervalMs);
    console.info(`启动定时上传，间隔: ${intervalMs}ms`);
  }

  stopUploadTimer() {
    if (this.uploadTimer !== undefined) {
      clearInterval(this.uploadTimer);
      this.uploadTimer = undefined;
      console.info('停止定时上传');
    }
  }

  // //测试用上传函数，成功与服务器通信
  // async uploadData_test() {
  //   // 3. 创建 HTTP 请求
  //   const httpRequest = http.createHttp();
  //   // 4. 准备请求数据
  //   const url = "http://124.222.53.152:8080/api/data"; // 确保路径正确
  //   // const url = "http://192.168.1.103:8080/api/data"; //lab_device 局域网测试用
  //   const data: TestData = {
  //     key1: "value1",
  //     key2: "value2"
  //   };
  //
  //   const headers: HttpHeaders = {
  //     "Content-Type": "application/json"
  //   };
  //
  //   try {
  //     // 5. 发送 POST 请求
  //     const response = await httpRequest.request(
  //       url,
  //       {
  //         method: http.RequestMethod.POST,
  //         header: headers,
  //         extraData: JSON.stringify(data)
  //       }
  //     );
  //     // 6. 处理响应
  //     if (response.responseCode === http.ResponseCode.OK) {
  //       console.info('请求成功:', JSON.stringify(response.result));
  //       try {
  //         let responseData:string = JSON.parse(String(response.result));
  //         console.info('服务器返回数据:', responseData);
  //       } catch (parseError) {
  //         console.error('JSON解析错误:', parseError);
  //       }
  //     } else {
  //       console.error(`请求失败，状态码: ${response.responseCode}`);
  //       console.error('响应内容:', response.result);
  //     }
  //   } catch (error) {
  //     // 7. 错误处理
  //     console.error('请求发生错误:', JSON.stringify(error));
  //     if (error) {
  //       console.error(`业务错误代码: ${error.code}, 信息: ${error.message}`);
  //     }
  //   } finally {
  //     // 8. 销毁请求对象
  //     httpRequest.destroy();
  //   }
  // }

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
        last_time = now_time;
        now_time = new Date().getTime();
        // console.info('读取用时：' , now_time - last_time);
      }, { interval: this.sensorInterval });//200ms
    } catch (error) {
      let e: BusinessError = error as BusinessError;
      console.error(`Failed to invoke on. Code: ${e.code}, message: ${e.message}`);
    }
  }

  async startLocationService() {
    try{
      geoLocationManager.on('locationChange',this.request, (location: geoLocationManager.Location) => {
        // console.log('实时定位：纬度=', location.latitude, ' 经度=', location.longitude)
        this.location[0] = location.longitude;
        this.location[1] = location.latitude;
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