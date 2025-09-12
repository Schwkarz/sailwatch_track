import http from '@ohos.net.http';
import Queue from '@ohos.util.Queue';

export function uploadDataToString(data: UploadData): string {
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
export function xorChecksum(str: string): number {
  let checksum = 0;
  for (let i = 0; i < str.length; i++) {
    checksum ^= str.charCodeAt(i);
  }
  return checksum & 0xFF; // 返回单字节校验值 (0-255)
}

export interface acceleration {
  x : number;
  y : number;
  z : number;
}

export interface angularVelocity {
  x : number;
  y : number;
  z : number;
}

export interface angle {
  roll : number;
  pitch : number;
  yaw : number;
}


export interface ble_SensorData {
  header: number;          // 数据包头 0x55
  flag: number;            // 标志位 0x61
  acceleration: acceleration;         // 加速度 (单位: m/s^2)
  angularVelocity: angularVelocity;   // 角速度 (单位: °/s)
  angle: angle;            // 角度 (单位: °)
  rawData: number[];       // 原始数据数组
  timestamp: number;       // 解析时间戳
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
export interface UploadData_check {
  uploaddata: UploadData;
  check: number;
}

//定义DataUploader类，完成数据包入队列和排队上传任务
export class DataUploader {
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