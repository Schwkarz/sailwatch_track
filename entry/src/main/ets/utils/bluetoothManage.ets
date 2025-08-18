import {ble} from '@kit.ConnectivityKit'
import { JSON } from '@kit.ArkTS';

export class bleManagement {

  public checkDevice(): void {

    ble.on('BLEDeviceFind', this.printBLE.bind(this));


    let scanFilter: ble.ScanFilter = {}
    ble.startBLEScan([scanFilter])

  }

  private printBLE(scanResults: ble.ScanResult[]): void {
    // console.log(JSON.stringify(scanResults));
    for(let i = 0; i < scanResults.length; i++){
      // const device = scanResults[i];
      // //打印所有设备名称
      // console.log('Found device:', device.deviceName);
      //找到了姿态传感器
      if(scanResults[i].deviceName == 'WT901BLE67'){
        console.log(JSON.stringify(scanResults[i]));
        this.tryConnect(scanResults[i].deviceId);
      }
    }
    // console.warn('WT901BLE NOT FIND')
  }

  private tryConnect(deviceID: string) : void {
    console.log('try connect')
    let device: ble.GattClientDevice = ble.createGattClientDevice(deviceID);
    device.on('BLEConnectionStateChange',this.confirmConnect)
    device.connect();
  }

  private confirmConnect(state: ble.BLEConnectionChangeState):void{
    console.info(`bluetooth connect state changed: ${state.state}`);
  }

}