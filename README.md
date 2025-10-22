# SailWatch Track — 手表水上运动监测（风筝 / 帆板）

- 设备：华为 WATCH 5
- 测试版本：Harmony OS NEXT 5.1.0.112
- OpenHarmony-SDK 5.1.0.107

项目目的：在鸿蒙手表端实时采集并上报水上运动（以风筝与帆板为主）的传感器与定位数据，结合姿态（IMU/蓝牙姿态传感器）、心率与 GPS，借助 MQTT/HTTP 上传到服务端进行分析与可视化。

主要特性
- 实时读取手表 GPS 与加速度、心率传感器（见入口组件 [`Index`](entry/src/main/ets/pages/Index.ets)）。
- 通过蓝牙读取外置姿态传感器（类/接口：[`BleManagement`], 数据类型：[`wt_SensorData`]，见 [entry/src/main/ets/utils/bluetoothManage](entry/src/main/ets/utils/bluetoothManage)）。
- MQTT 上报航行与原始数据（管理器：[`MqttManagement`]，消息格式示例：[`mqttUploadData`], [`WindDataMessage`]，见 [entry/src/main/ets/utils/mqtt](entry/src/main/ets/utils/mqtt)）。
- 本地队列/批量上传工具（[`DataUploader`]，见 [entry/src/main/ets/utils/updataloader](entry/src/main/ets/utils/updataloader)）。
- 测试与分析脚本、日志（传感器日志： [test/sensor_test/sensor_test_1.txt](test/sensor_test/sensor_test_1.txt)；GPS 分析脚本示例： [test/gps_test/gps_move_test.py](test/gps_test/gps_move_test.py)）。
- 项目调研资料（GPS 模块文档： [gps/gps.md](gps/gps.md)）。

快速开始
1. 打开工程并在 IDE 中定位入口页面：[`entry/src/main/ets/pages/Index.ets`](entry/src/main/ets/pages/Index.ets)（活动文件）。
2. 配置租户与服务器地址（文件顶部变量）：`is_test`、`test_tenantCode`、`product_tenantCode`、`test_url`、`product_url`。
3. 确保 SDK 与设备：在设备或模拟器上部署（请使用你本地的 OpenHarmony / HarmonyOS 开发环境）。
4. 授权权限：应用启动时会请求权限，主要包含：
   - ohos.permission.READ_HEALTH_DATA
   - ohos.permission.LOCATION / APPROXIMATELY_LOCATION
   - ohos.permission.ACCELEROMETER
   - 蓝牙相关权限（ACCESS_BLUETOOTH / DISCOVER_BLUETOOTH / USE_BLUETOOTH）
   权限请求逻辑位于 [`Index`](entry/src/main/ets/pages/Index.ets) 中的 `requestPermissionAndStart()`。

常用流程与入口函数
- 开始定位：`startLocationService()`（见 [`Index`](entry/src/main/ets/pages/Index.ets)）。
- 开始加速度/心率订阅：`startAccelerometer()` / `startHeartRateSensor()`（在 [`Index`](entry/src/main/ets/pages/Index.ets)）。
- 蓝牙设备管理与数据获取：参考 [entry/src/main/ets/utils/bluetoothManage](entry/src/main/ets/utils/bluetoothManage) 中的 [`BleManagement`]、[`wt_SensorData`]。
- MQTT 发布周期和封装逻辑：`startMqttSend()`（在 [`Index`](entry/src/main/ets/pages/Index.ets)），上报 topic 示例：
  - 航行数据：`mobile/up/general-train/{tenant}/{levelId}/{mhmId}`
  - 原始数据：`mobile/up/original/{tenant}/{levelId}/{mhmId}`  
  相关类型与函数在 [entry/src/main/ets/utils/mqtt](entry/src/main/ets/utils/mqtt) 中定义（如 [`MqttManagement`]、[`mqttUploadData`]、[`WindDataMessage`]）。

测试与调试
- 传感器日志：查看 [test/sensor_test/sensor_test_1.txt](test/sensor_test/sensor_test_1.txt) 来分析加速度读取间隔与频率。
- GPS 分析：参考 [test/gps_test/gps_move_test.py](test/gps_test/gps_move_test.py) 的分析/绘图脚本。
- 上传容量测试：项目内实现了 `runCapacityTests()`（[`Index`](entry/src/main/ets/pages/Index.ets)），用于批量测试 HTTP 上传不同大小的数据。

关键配置说明（在 [`Index`](entry/src/main/ets/pages/Index.ets)）
- 地磁偏移 declination：`declination`（用于航向修正）
- 上传间隔、传感器采样间隔：`uploadInterval`、`sensorInterval`、`heartInterval`
- GPS 精度阈值：`gps_accuracy_set`
- 冷却/长按逻辑与按钮行为：长按启动/停止上传与冷却时间在 `startLongPressDetection()` / `stopUpload()` / `startCoolDown()` 中实现

文件与符号索引（快速跳转）
- 入口页面与主逻辑：[`Index`](entry/src/main/ets/pages/Index.ets) — [entry/src/main/ets/pages/Index.ets](entry/src/main/ets/pages/Index.ets)
- 蓝牙姿态管理：[`BleManagement`](entry/src/main/ets/utils/bluetoothManage) / [`wt_SensorData`](entry/src/main/ets/utils/bluetoothManage) — [entry/src/main/ets/utils/bluetoothManage](entry/src/main/ets/utils/bluetoothManage)
- MQTT 管理与消息类型：[`MqttManagement`](entry/src/main/ets/utils/mqtt) / [`mqttUploadData`](entry/src/main/ets/utils/mqtt) / [`WindDataMessage`](entry/src/main/ets/utils/mqtt) — [entry/src/main/ets/utils/mqtt](entry/src/main/ets/utils/mqtt)
- 本地上传队列：[`DataUploader`](entry/src/main/ets/utils/updataloader) — [entry/src/main/ets/utils/updataloader](entry/src/main/ets/utils/updataloader)
- 传感器日志： [test/sensor_test/sensor_test_1.txt](test/sensor_test/sensor_test_1.txt)
- GPS 模块调研： [gps/gps.md](gps/gps.md)
- 分析脚本示例： [test/gps_test/gps_move_test.py](test/gps_test/gps_move_test.py) 、 [test/sensor_test/sensor_test.py](test/sensor_test/sensor_test.py)

常见问题（快速排查）
- 无法获取定位 / 精度异常：检查权限、GPS 模式与 `gnss_request` 配置；也可改为定时获取 `startGpsTimer()`。
- 蓝牙无法连接：检查蓝牙权限与设备名，参考 [`BleManagement`](entry/src/main/ets/utils/bluetoothManage) 的 `checkDevice()`、`checkDeviceName()` 实现。
- MQTT 无法连接：确认 `tenantCode`、`user_url` 与 `connectWatchMqtt()` 中的凭证与 clientId 配置；连接状态由 `mqttManager.isConnected` 校验，定时器 `startCheckTimer()` 会做重连逻辑。

贡献与扩展
- 若需支持更多外设（高频 GPS 或外部 IMU），建议在 [gps/gps.md](gps/gps.md) 的硬件调研基础上扩展数据采集模块，并在 MQTT 上加入新数据类型。
- 日志与测试：增加更多自动化脚本放入 `test/` 目录，便于离线分析（如频率统计、延时分析脚本）。