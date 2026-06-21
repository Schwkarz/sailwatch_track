import { ble } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const WT901_DEVICE_PREFIX: string = "WT901";

export interface BleDeviceItem {
  deviceId: string;
  deviceName: string;
  macAddress: string;
  rssi: number;
  lastSeen: number;
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

  private disposed: boolean = false;

  // 保存连接的设备实例
  private connectedDevice: ble.GattClientDevice | null = null;
  // 用一个数组保存一秒内读取到的传感器数据
  private last1sData: wt_SensorData[] = [];

  private isScanning: boolean = false;
  private selectedDeviceId: string = "";
  private selectedDeviceName: string = "";
  private discoveredDevices: BleDeviceItem[] = [];
  private deviceDiscoveryUpdate: ((devices: BleDeviceItem[]) => void) | null = null;
  private isDeviceFindListenerRegistered: boolean = false;
  private deviceFindCallback: (scanResults: ble.ScanResult[]) => void = (scanResults: ble.ScanResult[]) => {
    try {
      this.printBLE(scanResults);
    } catch (error) {
      const scanError: BusinessError = error as BusinessError;
      console.error(`处理蓝牙扫描结果失败: code=${scanError.code}, message=${scanError.message}`);
    }
  };
  private connectionStateCallback: (state: ble.BLEConnectionChangeState) => void = (state: ble.BLEConnectionChangeState) => {
    try {
      this.confirmConnect(state);
    } catch (error) {
      console.error(`处理蓝牙连接状态失败: ${JSON.stringify(error)}`);
    }
  };
  private characteristicChangeCallback: ((changedChar: ble.BLECharacteristic) => void) | null = null;
  private macQueryLoggingUntil: number = 0;
  private macAddressByDeviceName: Map<string, string> = new Map<string, string>();
  private autoMacProbeQueue: BleDeviceItem[] = [];
  private autoMacProbeAttemptedNames: Set<string> = new Set<string>();
  private autoMacProbeActive: boolean = false;
  private autoMacProbeDeviceId: string = "";
  private autoMacProbeDeviceName: string = "";
  private autoMacProbeStartTimer: number | undefined = undefined;
  private autoMacProbeTimeoutTimer: number | undefined = undefined;
  private macQueryDeviceId: string = "";
  private macQueryDeviceName: string = "";

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
      // console.log(`getDeviceName: ${name}`)
      return true;

    }
    else {
      return false;
    }
  }

  // 新增：断开连接回调函数
  private onConnectCallback: (() => void) | null = null;
  private onDisconnectCallback: (() => void) | null = null;

  public setOnConnectCallback(callback: () => void): void {
    this.onConnectCallback = callback;
  }

  public clearOnConnectCallback(): void {
    this.onConnectCallback = null;
  }

  // 设置断开连接回调
  public setOnDisconnectCallback(callback: () => void): void {
    this.onDisconnectCallback = callback;
  }

  // 清除断开连接回调
  public clearOnDisconnectCallback(): void {
    this.onDisconnectCallback = null;
  }

  public setDeviceDiscoveryCallback(callback: (devices: BleDeviceItem[]) => void): void {
    this.deviceDiscoveryUpdate = callback;
  }

  public clearDeviceDiscoveryCallback(): void {
    this.deviceDiscoveryUpdate = null;
  }

  public hasSelectedDevice(): boolean {
    return this.selectedDeviceId.length > 0;
  }

  public getSelectedDeviceId(): string {
    return this.selectedDeviceId;
  }

  public getSelectedDeviceName(): string {
    return this.selectedDeviceName;
  }

  public selectDevice(deviceId: string, deviceName: string): void {
    this.selectedDeviceId = deviceId;
    this.selectedDeviceName = deviceName;
  }

  public connectDevice(deviceId: string, deviceName: string): boolean {
    this.cancelAutoMacProbe();
    this.selectDevice(deviceId, deviceName);
    this.macQueryDeviceId = deviceId;
    this.macQueryDeviceName = deviceName;
    this.stopScan();
    return this.tryConnect(deviceId);
  }

  public connectSelectedDevice(): boolean {
    if (this.selectedDeviceId.length === 0 || this.connectedDevice) {
      return this.connectedDevice !== null;
    }
    return this.tryConnect(this.selectedDeviceId);
  }

  // 修改 confirmConnect 方法
  private confirmConnect(state: ble.BLEConnectionChangeState): void {
    if (state.state === 2) { // 2 表示已连接
      console.log('connected');
      this.readData();
      this.isScanning = false;
      if (!this.autoMacProbeActive && this.onConnectCallback) {
        this.onConnectCallback();
      }
    } else if (state.state === 0) { // 0 表示断开连接
      console.log('disconnected');
      this.handleDisconnection();
    }
  }

  private handleDisconnection(): void {
    console.log('设备连接已断开');
    this.connectedDevice = null;

    // 调用断开连接回调
    if (!this.autoMacProbeActive && this.onDisconnectCallback) {
      try {
        this.onDisconnectCallback();
      } catch (error) {
        console.error('断开连接回调执行错误:', error);
      }
    }
  }

  private arrayBufferToHex(buffer: ArrayBuffer): string {
    const bytes: Uint8Array = new Uint8Array(buffer);
    let text: string = '';
    for (let i: number = 0; i < bytes.length; i++) {
      let hex: string = bytes[i].toString(16).toUpperCase();
      if (hex.length < 2) {
        hex = `0${hex}`;
      }
      text += i === 0 ? hex : ` ${hex}`;
    }
    return text;
  }

  private arrayBufferToPrintableAscii(buffer: ArrayBuffer): string {
    const bytes: Uint8Array = new Uint8Array(buffer);
    let text: string = '';
    for (let i: number = 0; i < bytes.length; i++) {
      const value: number = bytes[i];
      text += value >= 32 && value <= 126 ? String.fromCharCode(value) : '.';
    }
    return text;
  }

  async checkDeviceName(): Promise<boolean> {
    if (!this.connectedDevice) {
      return false;
    }
    try {
      const name: string | undefined = await this.connectedDevice?.getDeviceName();
      if(!name){
        return this.selectedDeviceId.length > 0;
      }
      console.log(`getDeviceName: ${name}`);

      // 与普通字符串比较
      if (this.selectedDeviceName.length > 0 && name === this.selectedDeviceName) {
        return true;
      }
      return name.toUpperCase().startsWith(WT901_DEVICE_PREFIX);
    } catch (error) {
      console.error("Error getting device name:", error);
      return this.selectedDeviceId.length > 0;
    }
  }

  public checkDevice(): void {
    if (this.hasSelectedDevice()) {
      this.connectSelectedDevice();
      return;
    }
    this.startWt901DeviceScan();
  }

  public startWt901DeviceScan(): boolean {
    if (this.isScanning) {
      return true;
    }

    this.disposed = false;
    this.discoveredDevices = [];
    this.autoMacProbeQueue = [];
    this.autoMacProbeAttemptedNames.clear();
    this.autoMacProbeActive = false;
    console.log("start scan wt901 devices");

    try {
      if (!this.isDeviceFindListenerRegistered) {
        ble.on('BLEDeviceFind', this.deviceFindCallback);
        this.isDeviceFindListenerRegistered = true;
      }
      // SDK 要求无系统过滤条件时传 null；空数组会在部分手表上抛出 401。
      ble.startBLEScan(null);
      this.isScanning = true;
      return true;
    } catch (error) {
      console.error(`启动蓝牙扫描失败: ${JSON.stringify(error)}`);
      this.isScanning = false;
      this.removeDeviceFindListener();
      return false;
    }
  }

  public stopDeviceScan(): void {
    const wasAutoProbing: boolean = this.autoMacProbeActive;
    this.cancelAutoMacProbe();
    if (wasAutoProbing) {
      this.closeConnectedDeviceSilently();
    }
    this.stopScan();
  }

  //获取最近1s的数据并清空
  public getLast1sData(): wt_SensorData[] {
    let result: wt_SensorData[] = this.last1sData;
    this.last1sData = [];
    return result;
  }

  private printBLE(scanResults: ble.ScanResult[]): void {
    if (!scanResults || scanResults.length === 0) {
      return;
    }
    for (let i: number = 0; i < scanResults.length; i++) {
      const item: ble.ScanResult = scanResults[i];
      // console.log(`${JSON.stringify(scanResults[i])}`)
      try {
        const deviceName: string = item.deviceName ? item.deviceName.trim() : "";
        if (deviceName.length === 0 || !deviceName.toUpperCase().startsWith(WT901_DEVICE_PREFIX)) {
          continue;
        }
        const discovered: BleDeviceItem = {
          deviceId: item.deviceId,
          deviceName: deviceName,
          macAddress: this.macAddressByDeviceName.get(deviceName) ?? "",
          rssi: item.rssi,
          lastSeen: Date.now()
        };
        this.upsertDiscoveredDevice(discovered);
        this.queueDeviceForMacProbe(discovered);
      } catch (error) {
        const itemError: BusinessError = error as BusinessError;
        console.error(`跳过异常蓝牙广播: deviceId=${item.deviceId}, code=${itemError.code}, message=${itemError.message}`);
      }
    }
  }

  private tryConnect(deviceID: string): boolean {
    console.log('try connect');
    try {
      if (this.connectedDevice) {
        try {
          this.connectedDevice.off('BLEConnectionStateChange', this.connectionStateCallback);
          this.connectedDevice.disconnect();
        } catch (error) {
          console.error(`清理旧蓝牙连接失败: ${JSON.stringify(error)}`);
        }
        this.connectedDevice = null;
      }
      this.connectedDevice = ble.createGattClientDevice(deviceID);
      this.connectedDevice.on('BLEConnectionStateChange', this.connectionStateCallback);
      this.connectedDevice.connect();
      return true;
    } catch (error) {
      console.error(`连接蓝牙设备失败: ${JSON.stringify(error)}`);
      if (this.connectedDevice) {
        try {
          this.connectedDevice.off('BLEConnectionStateChange', this.connectionStateCallback);
        } catch (offError) {
          console.error(`移除蓝牙连接监听失败: ${JSON.stringify(offError)}`);
        }
      }
      this.connectedDevice = null;
      return false;
    }
  }

  private upsertDiscoveredDevice(device: BleDeviceItem): void {
    let updated: boolean = false;
    const devices: BleDeviceItem[] = [];
    for (let i: number = 0; i < this.discoveredDevices.length; i++) {
      const oldItem: BleDeviceItem = this.discoveredDevices[i];
      if (oldItem.deviceId === device.deviceId) {
        const merged: BleDeviceItem = {
          deviceId: device.deviceId,
          deviceName: device.deviceName,
          macAddress: oldItem.macAddress.length > 0 ? oldItem.macAddress : device.macAddress,
          rssi: device.rssi,
          lastSeen: device.lastSeen
        };
        devices.push(merged);
        updated = true;
      } else {
        devices.push(oldItem);
      }
    }
    if (!updated) {
      devices.push(device);
    }
    this.discoveredDevices = devices;
    this.notifyDeviceDiscovery();
  }

  private copyDiscoveredDevices(): BleDeviceItem[] {
    const devices: BleDeviceItem[] = [];
    for (let i: number = 0; i < this.discoveredDevices.length; i++) {
      const item: BleDeviceItem = this.discoveredDevices[i];
      const copy: BleDeviceItem = {
        deviceId: item.deviceId,
        deviceName: item.deviceName,
        macAddress: item.macAddress,
        rssi: item.rssi,
        lastSeen: item.lastSeen
      };
      devices.push(copy);
    }
    return devices;
  }

  private notifyDeviceDiscovery(): void {
    if (this.deviceDiscoveryUpdate) {
      this.deviceDiscoveryUpdate(this.copyDiscoveredDevices());
    }
  }

  private queueDeviceForMacProbe(device: BleDeviceItem): void {
    if (device.macAddress.length > 0 || this.macAddressByDeviceName.has(device.deviceName) ||
      this.autoMacProbeAttemptedNames.has(device.deviceName) ||
      this.autoMacProbeDeviceName === device.deviceName) {
      return;
    }
    for (let i: number = 0; i < this.autoMacProbeQueue.length; i++) {
      if (this.autoMacProbeQueue[i].deviceName === device.deviceName) {
        return;
      }
    }
    this.autoMacProbeQueue.push(device);
    if (!this.autoMacProbeActive && this.autoMacProbeStartTimer === undefined) {
      this.autoMacProbeStartTimer = setTimeout(() => {
        this.autoMacProbeStartTimer = undefined;
        this.probeNextDeviceMac();
      }, 1200);
    }
  }

  private probeNextDeviceMac(): void {
    if (this.disposed || this.autoMacProbeActive) {
      return;
    }
    if (this.autoMacProbeQueue.length === 0) {
      this.resumeScanAfterMacProbe();
      return;
    }
    const device: BleDeviceItem | undefined = this.autoMacProbeQueue.shift();
    if (!device) {
      this.resumeScanAfterMacProbe();
      return;
    }
    if (this.macAddressByDeviceName.has(device.deviceName)) {
      this.probeNextDeviceMac();
      return;
    }

    this.stopScan();
    this.autoMacProbeActive = true;
    this.autoMacProbeDeviceId = device.deviceId;
    this.autoMacProbeDeviceName = device.deviceName;
    this.autoMacProbeAttemptedNames.add(device.deviceName);
    this.macQueryDeviceId = device.deviceId;
    this.macQueryDeviceName = device.deviceName;
    console.info(`[BLE_MAC_PROBE] connecting device=${device.deviceName}, id=${device.deviceId}`);
    if (!this.tryConnect(device.deviceId)) {
      this.finishAutoMacProbe(false);
      return;
    }
    this.autoMacProbeTimeoutTimer = setTimeout(() => {
      console.warn(`[BLE_MAC_PROBE] timeout device=${this.autoMacProbeDeviceName}`);
      this.finishAutoMacProbe(false);
    }, 15000);
  }

  private finishAutoMacProbe(success: boolean): void {
    if (!this.autoMacProbeActive) {
      return;
    }
    if (this.autoMacProbeTimeoutTimer !== undefined) {
      clearTimeout(this.autoMacProbeTimeoutTimer);
      this.autoMacProbeTimeoutTimer = undefined;
    }
    console.info(`[BLE_MAC_PROBE] finished device=${this.autoMacProbeDeviceName}, success=${success}`);
    this.closeConnectedDeviceSilently();
    this.autoMacProbeActive = false;
    this.autoMacProbeDeviceId = "";
    this.autoMacProbeDeviceName = "";
    this.macQueryDeviceId = "";
    this.macQueryDeviceName = "";
    setTimeout(() => this.probeNextDeviceMac(), 350);
  }

  private resumeScanAfterMacProbe(): void {
    if (this.disposed || this.isScanning || this.connectedDevice) {
      return;
    }
    try {
      if (!this.isDeviceFindListenerRegistered) {
        ble.on('BLEDeviceFind', this.deviceFindCallback);
        this.isDeviceFindListenerRegistered = true;
      }
      ble.startBLEScan(null);
      this.isScanning = true;
      console.info('[BLE_MAC_PROBE] all known devices processed, scan resumed');
    } catch (error) {
      console.error(`[BLE_MAC_PROBE] resume scan failed: ${JSON.stringify(error)}`);
      this.isScanning = false;
      this.removeDeviceFindListener();
    }
  }

  private cancelAutoMacProbe(): void {
    if (this.autoMacProbeStartTimer !== undefined) {
      clearTimeout(this.autoMacProbeStartTimer);
      this.autoMacProbeStartTimer = undefined;
    }
    if (this.autoMacProbeTimeoutTimer !== undefined) {
      clearTimeout(this.autoMacProbeTimeoutTimer);
      this.autoMacProbeTimeoutTimer = undefined;
    }
    this.autoMacProbeQueue = [];
    this.autoMacProbeActive = false;
    this.autoMacProbeDeviceId = "";
    this.autoMacProbeDeviceName = "";
  }

  private closeConnectedDeviceSilently(): void {
    if (!this.connectedDevice) {
      return;
    }
    try {
      this.connectedDevice.off('BLEConnectionStateChange', this.connectionStateCallback);
      if (this.characteristicChangeCallback) {
        this.connectedDevice.off('BLECharacteristicChange', this.characteristicChangeCallback);
        this.characteristicChangeCallback = null;
      } else {
        this.connectedDevice.off('BLECharacteristicChange');
      }
      this.connectedDevice.disconnect();
    } catch (error) {
      console.error(`[BLE_MAC_PROBE] disconnect failed: ${JSON.stringify(error)}`);
    }
    this.connectedDevice = null;
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

      const writeCharacteristic = targetService.characteristics.find(char =>
      char.characteristicUuid === '0000FFE9-0000-1000-8000-00805F9A34FB'
      );

      // 4. 启用通知（假设数据通过通知发送）
      this.enableNotifications(targetCharacteristic, writeCharacteristic);
    });
  }

  // 启用特征通知
  private enableNotifications(
    characteristic: ble.BLECharacteristic,
    writeCharacteristic: ble.BLECharacteristic | undefined
  ): void {
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

        this.characteristicChangeCallback = (changedChar: ble.BLECharacteristic) => {
          if (changedChar.characteristicUuid === characteristic.characteristicUuid) {
            if (Date.now() <= this.macQueryLoggingUntil) {
              const responseHex: string = this.arrayBufferToHex(changedChar.characteristicValue);
              const responseAscii: string = this.arrayBufferToPrintableAscii(changedChar.characteristicValue);
              console.info(`[BLE_MAC_QUERY] notify hex=${responseHex}, ascii=${responseAscii}`);
            }
            const macAddress: string = this.parseMacQueryResponse(changedChar.characteristicValue);
            if (macAddress.length > 0) {
              this.updateSelectedDeviceMac(macAddress);
              return;
            }
            this.handleReceivedData(changedChar.characteristicValue);
          }
        };
        this.connectedDevice!.off('BLECharacteristicChange');
        this.connectedDevice!.on('BLECharacteristicChange', this.characteristicChangeCallback);

        if (writeCharacteristic) {
          const queryDeviceName: string = this.macQueryDeviceName;
          this.queryDeviceMacAddress(writeCharacteristic);
          setTimeout(() => {
            if (this.connectedDevice && this.macQueryDeviceName === queryDeviceName &&
              !this.macAddressByDeviceName.has(queryDeviceName)) {
              console.info(`[BLE_MAC_QUERY] retry device=${queryDeviceName}`);
              this.queryDeviceMacAddress(writeCharacteristic);
            }
          }, 2500);
        } else {
          console.warn('[BLE_MAC_QUERY] FFE9 write characteristic not found');
        }
      }
    );
  }

  private async queryDeviceMacAddress(writeCharacteristic: ble.BLECharacteristic): Promise<void> {
    const client: ble.GattClientDevice | null = this.connectedDevice;
    if (client === null) {
      console.warn('[BLE_MAC_QUERY] skipped because GATT client is disconnected');
      return;
    }

    const commandBuffer: ArrayBuffer = new ArrayBuffer(5);
    const command: Uint8Array = new Uint8Array(commandBuffer);
    command[0] = 0xFF;
    command[1] = 0xAA;
    command[2] = 0x27;
    command[3] = 0x66;
    command[4] = 0x00;
    writeCharacteristic.characteristicValue = commandBuffer;
    this.macQueryLoggingUntil = Date.now() + 3000;
    console.info('[BLE_MAC_QUERY] write command=FF AA 27 66 00 to FFE9');
    try {
      await client.writeCharacteristicValue(
        writeCharacteristic,
        ble.GattWriteType.WRITE_NO_RESPONSE
      );
      console.info('[BLE_MAC_QUERY] write success, waiting for FFE4 response');
    } catch (error) {
      const writeError: BusinessError = error as BusinessError;
      this.macQueryLoggingUntil = 0;
      console.warn(`[BLE_MAC_QUERY] write failed: code=${writeError.code}, message=${writeError.message}`);
    }
  }

  private parseMacQueryResponse(data: ArrayBuffer): string {
    const bytes: Uint8Array = new Uint8Array(data);
    for (let offset: number = 0; offset + 9 < bytes.length; offset++) {
      if (bytes[offset] !== 0x55 || bytes[offset + 1] !== 0x71 ||
        bytes[offset + 2] !== 0x66 || bytes[offset + 3] !== 0x00) {
        continue;
      }

      const macParts: string[] = [];
      for (let i: number = offset + 9; i >= offset + 4; i--) {
        let hex: string = bytes[i].toString(16).toUpperCase();
        if (hex.length < 2) {
          hex = `0${hex}`;
        }
        macParts.push(hex);
      }
      return macParts.join(':');
    }
    return "";
  }

  private updateSelectedDeviceMac(macAddress: string): void {
    const devices: BleDeviceItem[] = [];
    let updated: boolean = false;
    for (let i: number = 0; i < this.discoveredDevices.length; i++) {
      const item: BleDeviceItem = this.discoveredDevices[i];
      if (item.deviceId === this.macQueryDeviceId || item.deviceName === this.macQueryDeviceName) {
        const resolved: BleDeviceItem = {
          deviceId: item.deviceId,
          deviceName: item.deviceName,
          macAddress: macAddress,
          rssi: item.rssi,
          lastSeen: item.lastSeen
        };
        devices.push(resolved);
        updated = true;
      } else {
        devices.push(item);
      }
    }
    this.discoveredDevices = devices;
    if (this.macQueryDeviceName.length > 0) {
      this.macAddressByDeviceName.set(this.macQueryDeviceName, macAddress);
    }
    this.macQueryLoggingUntil = 0;
    console.info(`[BLE_MAC_QUERY] resolved device=${this.macQueryDeviceName}, mac=${macAddress}`);
    if (updated) {
      this.notifyDeviceDiscovery();
    }
    if (this.autoMacProbeActive) {
      this.finishAutoMacProbe(true);
    }
  }

  // 处理接收到的数据
  private handleReceivedData(data: ArrayBuffer): void {
    if (data.byteLength === 0) {
      return;
    }
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
    if (values.length < 20) {
      console.error('数据包长度不足，期望至少20字节，实际收到:', values.length);
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
    this.disposed = true;
    this.cancelAutoMacProbe();
    this.stopScan();
    if (this.connectedDevice) {
      try {
        this.connectedDevice.off('BLEConnectionStateChange', this.connectionStateCallback);
        if (this.characteristicChangeCallback) {
          this.connectedDevice.off('BLECharacteristicChange', this.characteristicChangeCallback);
          this.characteristicChangeCallback = null;
        } else {
          this.connectedDevice.off('BLECharacteristicChange');
        }
        this.connectedDevice.disconnect();
      } catch (error) {
        console.error(`断开蓝牙设备失败: ${JSON.stringify(error)}`);
      }
      this.connectedDevice = null;
    }
  }

  private stopScan(): void {
    if (this.isScanning) {
      try {
        ble.stopBLEScan();
      } catch (error) {
        console.error(`停止蓝牙扫描失败: ${JSON.stringify(error)}`);
      }
      this.isScanning = false;
    }
    this.removeDeviceFindListener();
  }

  private removeDeviceFindListener(): void {
    if (!this.isDeviceFindListenerRegistered) {
      return;
    }
    try {
      ble.off('BLEDeviceFind', this.deviceFindCallback);
    } catch (error) {
      console.error(`移除蓝牙扫描监听失败: ${JSON.stringify(error)}`);
    }
    this.isDeviceFindListenerRegistered = false;
  }

}
