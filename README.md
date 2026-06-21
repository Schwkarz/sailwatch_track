# SailWatch Track

SailWatch Track 是面向华为 HarmonyOS 穿戴设备的水上运动数据采集应用。应用可连接 WT901 系列 BLE 姿态传感器，并采集手表 GPS、心率与运动数据，支持服务器在线训练和本地离线训练两种模式。

用户操作说明见 [用户使用手册](USER_MANUAL.md)。

## 功能

### 在线模式

- 选择教练艇、训练级别和运动员分组。
- 在线选择结果保存在应用沙箱的 `online_training_config.json`；下次进入服务器模式时直接复用并跳转到 WT901 选择页。
- 未开始训练时可在实时页面点击“重新设置”，训练开始后该按钮禁用。
- 扫描附近名称以 `WT901` 开头的 BLE 设备，显示设备名、MAC 地址和 RSSI。
- 在线模式也可在 WT901 选择页跳过传感器，直接进入实时监控并连接服务器。
- 采集 GPS、心率、手表加速度和外置 IMU 姿态数据。
- 通过 MQTT 上报航行数据和原始数据。
- MQTT 断开后使用 3 秒重试定时器手动重连，单次连接超时为 5 秒。
- 重连成功后恢复风数据订阅，并发送断线期间进入内存队列的消息。

### 离线模式

- 不选择教练艇、训练级别或运动员，不连接 MQTT。
- 姿态传感器可选择连接或跳过，实时页面用圆点显示连接状态。
- 每秒将 IMU、GPS、船速、航向、定位精度和心率快照写入应用沙箱。
- 未连接姿态传感器或连续 5 秒没有新数据时，JSONL 中的 `imu` 写为 `"-"`，最近平均倾角显示 `---`。
- 每次停止记录后生成训练报告。
- 在手表上查看历史报告、心率折线、横滚倾角折线、航行距离和训练时长。
- 长按 2 秒停止记录，记录期间禁止进入历史页面，降低误触风险。

## 技术环境

- 设备类型：`wearable`
- 目标系统：HarmonyOS
- Target SDK：`5.1.0(18)`
- Compatible SDK：`5.1.0(18)`
- 开发语言：ArkTS / ArkUI
- MQTT 依赖：`@ohos/mqtt ^2.0.24`
- 已使用 HUAWEI WATCH 5 进行真机调试

## 项目结构

```text
entry/src/main/ets/
├── entryability/                 # UIAbility 入口
├── pages/Index.ets               # 页面、传感器和训练流程编排
└── utils/
    ├── bluetoothManage.ets       # WT901 扫描、连接和数据解析
    ├── mqtt.ets                  # MQTT 连接、重连、订阅和消息队列
    ├── offlineTrainingStore.ets  # 离线原始数据与训练报告
    └── updataloader.ets          # HTTP 数据上传工具
```

其他目录：

- `gps/`：GPS 调研资料。
- `test/gps_test/`：GPS 数据分析脚本。
- `test/sensor_test/`：传感器日志与分析脚本。

## 运行流程

应用启动后请求定位、健康数据、加速度计、蓝牙、网络和后台运行权限。权限通过后订阅手表传感器，并进入模式选择页。

在线模式：

```text
连接服务器 -> 选择教练艇 -> 选择级别 -> 选择分组 -> 选择 WT901 -> 在线训练
```

离线模式：

```text
离线模式 -> 连接 WT901 或跳过 -> 开始记录 -> 长按停止 -> 查看报告
```

## 开发配置

服务器和租户配置位于 [`entry/src/main/ets/pages/Index.ets`](entry/src/main/ets/pages/Index.ets)：

- `is_test`
- `test_tenantCode` / `product_tenantCode`
- `test_url` / `product_url`
- `declination`
- `gps_accuracy_set`

MQTT 凭据和客户端 ID 在 `connectWatchMqtt()` 中设置。正式发布前应将凭据迁移到安全配置，不要提交生产密钥。

## 权限

模块权限配置位于 [`entry/src/main/module.json5`](entry/src/main/module.json5)，主要包括：

- `ohos.permission.READ_HEALTH_DATA`
- `ohos.permission.LOCATION`
- `ohos.permission.APPROXIMATELY_LOCATION`
- `ohos.permission.ACCELEROMETER`
- `ohos.permission.ACCESS_BLUETOOTH`
- `ohos.permission.DISCOVER_BLUETOOTH`
- `ohos.permission.USE_BLUETOOTH`
- `ohos.permission.INTERNET`
- `ohos.permission.KEEP_BACKGROUND_RUNNING`

## 构建

推荐在 DevEco Studio 中执行 Sync、Build 和 Run，也可以使用 DevEco Studio 自带的 Hvigor：

```powershell
hvigorw assembleHap --mode module `
  -p module=entry@default `
  -p product=default `
  -p requiredDeviceType=wearable
```

签名 HAP 默认生成在：

```text
entry/build/default/outputs/default/entry-default-signed.hap
```

## 数据与 Topic

在线模式主要使用以下 MQTT Topic：

```text
mobile/up/general-train/{tenant}/{levelId}/{mhmId}
mobile/up/original/{tenant}/{levelId}/{mhmId}
gateway/env/wind/{tenant}/{windBoatSource}
```

离线模式的数据保存在应用沙箱的 `records/` 目录：

```text
records/
├── raw/       # 每次训练的 JSONL 原始数据
├── reports/   # 训练报告 JSON
└── index.json # 历史报告索引
```

在线训练选项保存在应用沙箱根目录的 `online_training_config.json`。在历史报告列表中点击“删除”后再次点击“确认”，会同时删除对应的原始 JSONL、报告 JSON 和索引项。

蓝牙选择页显示的地址来自 HarmonyOS `ScanResult.deviceId`，是扫描时使用的 BLE 设备地址，不保证等于设备标签上的公共 MAC。若外设使用隐私随机地址，该值可能在不同扫描周期中变化。

卸载应用会清除应用沙箱中的离线数据。

## 常见问题

- **扫描不到 WT901**：确认蓝牙和定位权限已授权，传感器已开机且未被其他设备占用，然后点击“扫描”。
- **MQTT 无法恢复**：检查网络、服务器地址、端口、凭据和 clientId。连接失败后应用每 3 秒尝试一次，单次最多等待 5 秒。
- **没有 GPS 或心率数据**：确认系统权限已全部授权，并在室外等待定位稳定。
- **离线报告为空**：确认记录已经正常开始，并通过长按完成停止和报告生成。
- **ArkTS 构建警告**：当前 SDK 会提示部分 `fileIo` API 并非所有设备都支持，离线存储需以目标真机验证为准。

## 关键代码

- 主页面与训练流程：[`Index.ets`](entry/src/main/ets/pages/Index.ets)
- BLE 管理：[`bluetoothManage.ets`](entry/src/main/ets/utils/bluetoothManage.ets)
- MQTT 管理：[`mqtt.ets`](entry/src/main/ets/utils/mqtt.ets)
- 离线存储：[`offlineTrainingStore.ets`](entry/src/main/ets/utils/offlineTrainingStore.ets)
- 上传工具：[`updataloader.ets`](entry/src/main/ets/utils/updataloader.ets)
