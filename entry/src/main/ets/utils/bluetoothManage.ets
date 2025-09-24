import { ble } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const device_name: string = "WT901BLE12";

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

export interface wt_SensorData {
  header: number;          // 数据包头 0x55
  flag: number;            // 标志位 0x61
  acceleration: acceleration;         // 加速度 (单位: m/s^2)
  angularVelocity: angularVelocity;   // 角速度 (单位: °/s)
  angle: angle;            // 角度 (单位: °)
  rawData: number[];       // 原始数据数组
  timestamp: number;       // 解析时间戳
}

export class BleManagement {

  // 保存连接的设备实例
  private connectedDevice: ble.GattClientDevice | null = null;
  // 用一个数组保存一秒内读取到的传感器数据
  private last1sData: wt_SensorData[] = [];

  private isScanning: boolean = false;

  public ble_sensorData: wt_SensorData = {
    header : 0,
    flag : 0,
    acceleration : {
      x : 0,
      y : 0,
      z : 0
    },
    angularVelocity : {
      x : 0,
      y : 0,
      z : 0
    },
    angle : {
      roll : 0,
      pitch : 0,
      yaw : 0
    },
    rawData : [],
    timestamp : 0
  }

  public isConnected(): boolean {

    if(this.connectedDevice){

      let name: Promise<string> = this.connectedDevice?.getDeviceName();
      console.log(`getDeviceName: ${name}`)
      return true;

    }
    else {
      return false;
    }
  }

  // 新增：断开连接回调函数
  private onDisconnectCallback: (() => void) | null = null;

  // 设置断开连接回调
  public setOnDisconnectCallback(callback: () => void): void {
    this.onDisconnectCallback = callback;
  }

  // 清除断开连接回调
  public clearOnDisconnectCallback(): void {
    this.onDisconnectCallback = null;
  }

  // 修改 confirmConnect 方法
  private confirmConnect(state: ble.BLEConnectionChangeState): void {
    if (state.state === 2) { // 2 表示已连接
      console.log('connected');
      this.readData();
      this.isScanning = false;
    } else if (state.state === 0) { // 0 表示断开连接
      console.log('disconnected');
      this.handleDisconnection();
    }
  }

  private handleDisconnection(): void {
    console.log('设备连接已断开');
    this.connectedDevice = null;

    // 调用断开连接回调
    if (this.onDisconnectCallback) {
      try {
        this.onDisconnectCallback();
      } catch (error) {
        console.error('断开连接回调执行错误:', error);
      }
    }
  }

  async checkDeviceName(): Promise<boolean> {
    try {
      const name: string | undefined = await this.connectedDevice?.getDeviceName();
      if(!name){
        return false;
      }
      console.log(`getDeviceName: ${name}`);

      // 与普通字符串比较
      if (name === device_name) {
        return true;
      } else {
        return false;
      }
    } catch (error) {
      console.error("Error getting device name:", error);
      return false;
    }
  }

  public checkDevice(): void {
    if(!this.isScanning){
      this.isScanning = true;
      console.log("start scan");
      ble.on('BLEDeviceFind', this.printBLE.bind(this));
      let scanFilter: ble.ScanFilter = {
        name: device_name,
      };
      ble.startBLEScan([scanFilter]);
    }
  }

  //获取最近1s的数据并清空
  public getLast1sData(): wt_SensorData[] {
    let result: wt_SensorData[] = this.last1sData;
    this.last1sData = [];
    return result;
  }

  private printBLE(scanResults: ble.ScanResult[]): void {
    console.log(JSON.stringify(scanResults[0]));
    let result = scanResults[0];
    this.tryConnect(scanResults[0].deviceId);
  }

  private tryConnect(deviceID: string): void {
    console.log('try connect');
    this.connectedDevice = ble.createGattClientDevice(deviceID);
    this.connectedDevice.on('BLEConnectionStateChange', this.confirmConnect.bind(this));
    this.connectedDevice.connect();
  }

  // 实现读取数据的核心方法
  private readData(): void {
    if (!this.connectedDevice) {
      console.error('No connected device');
      return;
    }

    // 1. 获取所有服务
    this.connectedDevice.getServices((err: BusinessError, services: Array<ble.GattService>) => {
      if (err) {
        console.error('Failed to get services:', JSON.stringify(err));
        return;
      }

      // 2. 查找目标服务（根据你的设备特性修改UUID）
      const targetService = services.find(service =>
      service.serviceUuid === '0000FFE5-0000-1000-8000-00805F9A34FB' // 替换为你的服务UUID
      );

      if (!targetService) {
        console.error('Target service not found');
        return;
      }

      // 3. 查找目标特征（根据你的设备特性修改UUID）
      const targetCharacteristic = targetService.characteristics.find(char =>
      char.characteristicUuid === '0000FFE4-0000-1000-8000-00805F9A34FB' // 替换为你的特征UUID
      );

      if (!targetCharacteristic) {
        console.error('Target characteristic not found');
        return;
      }

      // 4. 启用通知（假设数据通过通知发送）
      this.enableNotifications(targetCharacteristic);
    });
  }

  // 启用特征通知
  private enableNotifications(characteristic: ble.BLECharacteristic): void {
    if (!this.connectedDevice) return;

    // 设置特征变化通知
    this.connectedDevice.setCharacteristicChangeNotification(
      characteristic,
      true,
      (err: BusinessError) => {
        if (err) {
          console.error('Enable notification failed:', JSON.stringify(err));
          return;
        }

        console.log('Notifications enabled');

        // 5. 订阅特征变化事件
        this.connectedDevice!.on('BLECharacteristicChange', (changedChar: ble.BLECharacteristic) => {
          if (changedChar.characteristicUuid === characteristic.characteristicUuid) {
            this.handleReceivedData(changedChar.characteristicValue);
          }
        });
      }
    );
  }

  // 处理接收到的数据
  private handleReceivedData(data: ArrayBuffer): void {
    // 将ArrayBuffer转换为可操作的数据视图
    const dataView = new DataView(data);

    const values: number[] = [];

    // 数据包以0x55开头
    if (dataView.getUint8(0) === 0x55) {
      // 解析数据包
      for (let i: number = 0; i < data.byteLength; i++) {
        values.push(dataView.getUint8(i));
      }

      this.ble_sensorData = this.parseWT901Data(values);
      // 把数据包放入数组中
      this.last1sData.push(this.ble_sensorData);

      // console.log(`角度: roll: ${this.ble_sensorData.angle.roll},pitch: ${this.ble_sensorData.angle.pitch},yaw: ${this.ble_sensorData.angle.yaw}`);

      // console.log('=== 传感器数据 ===');
      // console.log(`加速度: x: ${this.ble_sensorData.acceleration.x},y: ${this.ble_sensorData.acceleration.y},z: ${this.ble_sensorData.acceleration.z}`);
      // console.log(`角速度: x: ${this.ble_sensorData.angularVelocity.x},y: ${this.ble_sensorData.angularVelocity.y},z: ${this.ble_sensorData.angularVelocity.z}`);
      // console.log(`角度: roll: ${this.ble_sensorData.angle.roll},pitch: ${this.ble_sensorData.angle.pitch},yaw: ${this.ble_sensorData.angle.yaw}`);
      // console.log('时间戳:', new Date(this.ble_sensorData.timestamp).toLocaleString('zh-CN'));
      // console.log('=================');
      // console.log(`加速度: x:  ${this.ble_sensorData.acceleration.x},y:  ${this.ble_sensorData.acceleration.y},z:  ${this.ble_sensorData.acceleration.z}`)
    }
  }

  // 主动读取特征值（如果需要）
  private readCharacteristicValue(characteristic: ble.BLECharacteristic): void {
    if (!this.connectedDevice) return;
    this.connectedDevice.readCharacteristicValue(
      characteristic,
      (err: BusinessError, charWithValue: ble.BLECharacteristic) => {
        if (err) {
          console.error('Read failed:', JSON.stringify(err));
          return;
        }
        this.handleReceivedData(charWithValue.characteristicValue);
      }
    );
  }

  /**
   * 解析WT901传感器数据包
   * @param values 数据包数组，包含完整的传感器数据
   * @returns 解析后的传感器数据对象
   */
  private parseWT901Data(values: number[]): wt_SensorData {

    let null_data : wt_SensorData= {
      header : 0,
      flag : 0,
      acceleration : {
        x : 0,
        y : 0,
        z : 0
      },
      angularVelocity : {
        x : 0,
        y : 0,
        z : 0
      },
      angle : {
        roll : 0,
        pitch : 0,
        yaw : 0
      },
      rawData : [],
      timestamp : 0
    }

    // 检查数据包长度和包头
    if (values.length < 19) {
      console.error('数据包长度不足，期望至少19字节，实际收到:', values.length);
      return null_data;
    }

    if (values[0] !== 0x55) {
      console.error('无效的数据包头，期望0x55，实际收到:', values[0].toString(16));
      return null_data;
    }

    if (values[1] !== 0x61) {
      console.error('无效的标志位，期望0x61，实际收到:', values[1].toString(16));
      return null_data;
    }

    try {
      // 解析加速度数据 (通常范围: ±16g)
      const accelX = this.parse16Bit(values[2], values[3]) / 32768 * 16 * 9.80665;
      const accelY = this.parse16Bit(values[4], values[5]) / 32768 * 16 * 9.80665;
      const accelZ = this.parse16Bit(values[6], values[7]) / 32768 * 16 * 9.80665;

      // 解析角速度数据 (通常范围: ±2000°/s)
      const gyroX = this.parse16Bit(values[8], values[9]) / 32768 * 2000;
      const gyroY = this.parse16Bit(values[10], values[11]) / 32768 * 2000;
      const gyroZ = this.parse16Bit(values[12], values[13]) / 32768 * 2000;

      // 解析角度数据 (通常范围: ±180°)
      const angleRoll = this.parse16Bit(values[14], values[15]) / 32768 * 180;
      const anglePitch = this.parse16Bit(values[16], values[17]) / 32768 * 180;
      const angleYaw = this.parse16Bit(values[18], values[19]) / 32768 * 180;

      return {
        header: values[0],
        flag: values[1],
        acceleration: {
          x: parseFloat(accelX.toFixed(4)),
          y: parseFloat(accelY.toFixed(4)),
          z: parseFloat(accelZ.toFixed(4))
        },
        angularVelocity: {
          x: parseFloat(gyroX.toFixed(2)),
          y: parseFloat(gyroY.toFixed(2)),
          z: parseFloat(gyroZ.toFixed(2))
        },
        angle: {
          roll: parseFloat(angleRoll.toFixed(2)),
          pitch: parseFloat(anglePitch.toFixed(2)),
          yaw: parseFloat(angleYaw.toFixed(2))
        },
        rawData: [...values],
        timestamp: Date.now()
      };
    } catch (error) {
      console.error('解析数据包时发生错误:', error);
      return null_data;
    }
  }

  /**
   * 将两个8位字节组合成16位有符号整数
   * @param lowByte 低8位
   * @param highByte 高8位
   * @returns 16位有符号整数
   */
  private parse16Bit(lowByte: number, highByte: number): number {
    const value = (highByte << 8) | lowByte;
    // 处理有符号数（二进制补码）
    return value > 32767 ? value - 65536 : value;
  }

  //转换成适合发送的原始数据内容
  public formatAngleDataForPosture(sensorDataArray: wt_SensorData[]): string {
    if (!sensorDataArray || sensorDataArray.length === 0) {
      return '';
    }

    // 提取各个角度的数据
    const rollValues: number[] = [];
    const yawValues: number[] = [];
    const pitchValues: number[] = [];

    // 遍历数组，收集所有数据点
    sensorDataArray.forEach((data, index) => {
      // 只取前10个数据点（如果数组长度超过10）
      if (index < 10) {
        rollValues.push(data.angle.roll);
        yawValues.push(data.angle.yaw);
        pitchValues.push(data.angle.pitch);
      }
    });

    // 如果数据点不足10个，用最后一个值填充（或者可以根据需求用其他方式处理）
    while (rollValues.length < 10) {
      rollValues.push(rollValues.length > 0 ? rollValues[rollValues.length - 1] : 0);
    }
    while (yawValues.length < 10) {
      yawValues.push(yawValues.length > 0 ? yawValues[yawValues.length - 1] : 0);
    }
    while (pitchValues.length < 10) {
      pitchValues.push(pitchValues.length > 0 ? pitchValues[pitchValues.length - 1] : 0);
    }

    // 格式化字符串：Rol1|Rol2...Rol10,Yaw1|Yaw2...Yaw10,Pitch1|Pitch2...Pitch10
    const rollString = rollValues.map(val => val.toFixed(3)).join('|');
    const yawString = yawValues.map(val => val.toFixed(3)).join('|');
    const pitchString = pitchValues.map(val => val.toFixed(3)).join('|');

    return `${rollString},${yawString},${pitchString}`;
  }

  public transYaw(): number {
    let z: number = this.ble_sensorData.angle.yaw;
    let z1: number = -1;

    if( -180 <= z && z < 90){
      z1 = 90 - z;
    }
    else {
      z1 = 450 - z;
    }

    return z1;
  }

  // 断开连接和清理
  public disconnect(): void {
    if (this.connectedDevice) {
      this.connectedDevice.disconnect();
      this.connectedDevice = null;
    }
  }
}