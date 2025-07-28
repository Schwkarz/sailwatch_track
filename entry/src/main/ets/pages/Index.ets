import { abilityAccessCtrl, common, Context, PermissionRequestResult ,Permissions } from '@kit.AbilityKit';
import { sensor } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {power} from '@kit.BasicServicesKit';
import window from '@ohos.window';
import { geoLocationManager } from '@kit.LocationKit';

@Entry
@Component
struct Index {
  @State heartRate: number = 0;
  @State location: Array<number> = [0,0]; //[0]经度 [1]纬度
  //请求位置信息的参数
  request: geoLocationManager.ContinuousLocationRequest= {
    //高功耗定位
    locationScenario: geoLocationManager.PowerConsumptionScenario.HIGH_POWER_CONSUMPTION,
    //实时上报定位
    interval:0
  };

  build() {
    Column() {
      Text(`水上运动监测`)
        .fontSize(25)
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
        .margin({ bottom: 15 })
      Text(`❤️ 心率：${this.heartRate} bpm`)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
        .margin({ bottom: 12 })
      Text(`📍 经度：${this.location[0].toFixed(6)}`)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
        .margin({ bottom: 12 })
      Text(`📍 纬度：${this.location[1].toFixed(6)}`)
        .fontSize(20)
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
      'ohos.permission.APPROXIMATELY_LOCATION' as Permissions
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
          console.info('所有权限已授权，开始心率与定位功能');
          this.startHeartRateSensor(); // 心率订阅函数
          this.startLocationService(); // 定位
        } else {
          console.warn('部分权限未授权，功能可能受限');
          this.startHeartRateSensor();
          this.startLocationService();
        }
      }
    );
  }

  async startLocationService() {
    try{
      geoLocationManager.on('locationChange',this.request, (location: geoLocationManager.Location) => {
        console.log('实时定位：纬度=', location.latitude, ' 经度=', location.longitude)
        this.location[0] = location.longitude;
        this.location[1] = location.latitude;
      })
    }
    catch(error){
      console.error('定位失败：'+ error.message);}
    // throw new Error('Method not implemented.');
  }

  startHeartRateSensor() {
    try {
      sensor.on(sensor.SensorId.HEART_RATE, (data: sensor.HeartRateResponse) => {
        this.heartRate = data.heartRate;
      }, { interval: 100000000 }); // 每100ms更新一次
    } catch (err) {
      let e = err as BusinessError;
      console.error(`心率订阅失败，错误码: ${e.code}, 信息: ${e.message}`);
    }
  }

  aboutToDisappear() {
    try {
      sensor.off(sensor.SensorId.HEART_RATE);
      geoLocationManager.off('locationChange');
      console.log('定位服务关闭');
    } catch (err) {
      let e = err as BusinessError;
      console.error("errCode:" + JSON.stringify(err));
    }
    this.keepScreenOn(false);
  }

}