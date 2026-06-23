import { MqttClient, MqttConnectOptions, MqttMessage, MqttQos, MqttSubscribeOptions } from '@ohos/mqtt';
import http from '@ohos.net.http';
import { JSON } from '@kit.ArkTS';

interface PendingMqttMessage {
  topic: string;
  payload: string;
  qos: MqttQos;
}

interface MqttSubscription {
  topic: string;
  qos: MqttQos;
}

function formatErrorMessage(error: Error): string {
  return error.message ? error.message : JSON.stringify(error);
}

export interface WindDataMessage {
  windSourceBoatCode: string;    // 风来源教练艇编号
  windSpeed: number;             // 平均风速 (cm/s,保留4位小数)
  windDirection: number;         // 平均风向°
  customWindSpeed: number;       // 自定义风速 (cm/s,保留4位小数)
  customWindDirection: number;   // 自定义风向°
  longitude: number;             // 经度 WGS 84 坐标系
  latitude: number;              // 纬度 WGS 84 坐标系
  ts: string;                    // 数据GPS时间
}

export interface original_data {
  mHmId: string,
  ts: string,
  dataType: string,
  data: string
}

interface level_data {
  levelId: string,
  levelName: string
}

//级别
export interface level_rec {
  success: boolean,
  errCode: string,
  errMessage: string
  data: level_data[]
}

interface group_data {
  groupId: string,
  groupName: string,
  color: string,
  mhmId: string,
  mhmName: string
}

//船组
export interface group_rec {
  success: boolean,
  errCode: string,
  errMessage: string,
  data: group_data[]
}

export interface sailboat_data {
  mHmName: string, //主舵手姓名
  color: string,   //船组颜色

  longitude: string, //GPS经度
  latitude: string,  //GPS纬度

  headingT: number | null | string,  //航向 °（真北）
  headingM: number | null | string,  //航向 °（磁北） headingM = (headingT - declination) % 360
  sailStatus: string | null,//&航行状态
  leeway: string | null,    //&漂角

  speed: number,                //航速          （cm/s,保留4位小数）
  standardSpeed: number | null,        //&标准船速      （cm/s,保留4位小数）
  customStandardSpeed:number | null,   //&自定义标准船速 （cm/s,保留4位小数）

  angle: number | null,
  vmg: number | null,
  standardVmg: number | null,

  customAngle: number | null,
  customVmg: number | null,
  customStandardVmg: number | null,

  windSourceBoatCode: string,       //风数据来源
  windSpeed: number,                //平均风速        (cm/s,保留4位小数)
  windDirection: number,            //平均风向°
  customWindSpeed: number,          //自定义风速      (cm/s,保留4位小数)
  customWindDirection: number,      //自定义风向°

  yaw: number,        //船首向
  rol: number,        //平衡（横滚角X轴）
  pitch: number,      //俯仰角（Y轴）
  posture: string | null,    //&航行姿态   倾斜、反扣和平衡
  pitchPosture: string | null,       //&俯仰姿态   前仰、后仰和平衡

  hr: number[]      //舵手心率    第一个为主舵手 [65, -1]
}

export interface mqttUploadData {
  mHmId: string,      //主舵手ID
  ts: string,         //数据生成时间
  data: sailboat_data
}

export class MqttManagement {
  private mqttClient: MqttClient | null = null;
  private reconnectTimer: number | null = null;
  public isConnected = false;

  private disposed = false;         // 已销毁标记
  private connecting = false;       // 正在连接标记
  private closing = false;          // 正在断开/销毁，阻止并发操作
  private manualReconnect = true;   // 与 automaticReconnect 二选一
  private clientGeneration = 0;     // 使旧 client 的 JS 回调失效
  private activeSubscriptions: Set<string> = new Set<string>();
  private subscribingTopics: Set<string> = new Set<string>();

  private clientId: string = '';    //客户端ID
  private readonly MAX_PENDING_MESSAGES: number = 3600;
  private readonly RECONNECT_DELAY_MS: number = 3000;
  private pendingMessages: PendingMqttMessage[] = [];
  private publishDrainActive: boolean = false;
  private subscriptions: MqttSubscription[] = [];
  private diagnosticLogger: ((level: string, tag: string, message: string) => void) | null = null;
  private lastOfflineQueueLogAt: number = 0;

  private windData: WindDataMessage = {
    windSourceBoatCode: 'null',
    windSpeed: -1,
    windDirection: -1,
    customWindSpeed: -1,
    customWindDirection: -1,
    longitude: -1,
    latitude: -1,
    ts: 'null'
  };
  private windDataUpdateTime: number = 0;

  // 声明类字段
  private host: string;
  private port: number;
  private useSSL: boolean;

  private connectOptions: MqttConnectOptions = {
    // 建议：若使用手动重连则关闭自动重连
    automaticReconnect: false,              // ← 与手动重连二选一
    connectTimeout: 5,
    keepAliveInterval: 60,
    cleanSession: true,
    sslOptions: { enableServerCertAuth: true },
  };

  /**
   * 构造函数
   * @param host MQTT服务器地址
   * @param port 端口号
   * @param useSSL 是否使用SSL
   */
  constructor(
    host: string = 'broker.example.com',
    port: number = 8883,
    useSSL: boolean = true) {
    this.host = host;
    this.port = port;
    this.useSSL = useSSL;
  }

  setDiagnosticLogger(logger: (level: string, tag: string, message: string) => void): void {
    this.diagnosticLogger = logger;
  }

  private diagnostic(level: string, message: string): void {
    if (this.diagnosticLogger) {
      this.diagnosticLogger(level, 'MQTT', message);
    }
  }

  //设置id
  setClientId(id: string): void {
    this.clientId = id;
  }

  //设置url
  setHost(url: string): void {
    this.host = url;
  }

  //设置心跳
  setKeepalive(keepalive: number): void {
    this.connectOptions.keepAliveInterval = keepalive;
  }

  /**
   * 设置认证信息（可选）
   * @param username 用户名（可选）
   * @param password 密码（可选）
   */
  setCredentials(username?: string, password?: string): void {
    this.connectOptions.userName = username;
    this.connectOptions.password = password;
  }

  /**
   * 清除认证信息（允许匿名连接）
   */
  clearCredentials(): void {
    this.connectOptions.userName = undefined;
    this.connectOptions.password = undefined;
  }

  /**
   * 检查是否设置了认证信息
   */
  hasCredentials(): boolean {
    return !!this.connectOptions.userName && !!this.connectOptions.password;
  }



  async connect(): Promise<boolean> {
    if (this.disposed || this.closing) return false;
    if (this.isConnected) return true;
    if (this.connecting) return false;

    this.manualReconnect = true;
    this.connecting = true;
    try {
      // 必须完整销毁旧 native client，不能仅把 JS 引用置空。
      if (this.mqttClient) {
        await this.safeDisconnectAndClear("preconnect");
      }
      if (this.disposed || this.closing) return false;

      const clientId = this.clientId;
      const protocol = this.useSSL ? 'mqtts' : 'mqtt';
      const url = `${protocol}://${this.host}:${this.port}`;
      const generation = ++this.clientGeneration;
      const client = new MqttClient({
        url,
        clientId,
        persistenceType: 1,
      });
      this.mqttClient = client;
      this.activeSubscriptions.clear();
      this.subscribingTopics.clear();
      this.setupEventListeners(client, generation);

      const finalOptions: MqttConnectOptions = {
        connectTimeout: this.connectOptions.connectTimeout ?? 5,
        keepAliveInterval: this.connectOptions.keepAliveInterval ?? 60,
        cleanSession: this.connectOptions.cleanSession ?? true,
        sslOptions: { enableServerCertAuth: true },
        automaticReconnect: false,
        userName: this.connectOptions.userName,
        password: this.connectOptions.password,
      };

      const response = await client.connect(finalOptions);
      if (this.disposed || generation !== this.clientGeneration || this.mqttClient !== client) {
        try { await client.destroy(); } catch (_) {}
        return false;
      }

      console.info(`MQTT连接成功: ${JSON.stringify(response)}`);
      this.diagnostic('INFO', `connected host=${this.host}:${this.port} pending=${this.pendingMessages.length}`);
      this.isConnected = true;
      this.clearReconnectTimer();
      await this.restoreSubscriptions();
      this.flushPendingMessages().catch((error: Error) => {
        console.error(`启动MQTT发送队列失败: ${formatErrorMessage(error)}`);
      });
      return true;
    } catch (error) {
      console.error(`MQTT连接失败: ${JSON.stringify(error)}`);
      this.diagnostic('ERROR', `connect failed host=${this.host}:${this.port} error=${JSON.stringify(error)}`);
      this.isConnected = false;
      return false;
    } finally {
      this.connecting = false;
      if (!this.isConnected && this.manualReconnect && !this.disposed && !this.closing) {
        this.scheduleReconnect();
      }
    }
  }

  public isConnecting(): boolean {
    return this.connecting;
  }

  // 完整关闭 native client。messageArrived/connectLost 没有 off API，不能用“空回调”冒充注销。
  private async safeDisconnectAndClear(tag = ""): Promise<void> {
    const client = this.mqttClient;
    if (!client) {
      this.isConnected = false;
      return;
    }

    // 先使旧回调失效，并阻止新的 publish/subscribe 使用该实例。
    ++this.clientGeneration;
    this.mqttClient = null;
    this.isConnected = false;
    this.activeSubscriptions.clear();
    this.subscribingTopics.clear();

    try {
      // 即使本地状态已经是 false，也要让 native 层完成断开。
      await client.disconnect();
      console.info(`MQTT连接已断开(${tag})`);
    } catch (e) {
      console.warn(`MQTT disconnect(${tag})未完成: ${JSON.stringify(e)}`);
    }

    try {
      // 关键：释放 native client、工作线程和 EventListener。
      await client.destroy();
      console.info(`MQTT客户端已销毁(${tag})`);
    } catch (e) {
      console.error(`销毁MQTT客户端失败(${tag}): ${JSON.stringify(e)}`);
    }
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer !== null || this.disposed || this.isConnected) return;

    this.diagnostic('WARN', `reconnect scheduled delayMs=${this.RECONNECT_DELAY_MS} pending=${this.pendingMessages.length}`);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      if (this.disposed || this.isConnected) return;
      if (this.connecting) {
        this.scheduleReconnect();
        return;
      }
      console.info('尝试重新连接MQTT服务器...');
      this.connect().catch((err: Error) => {
        console.error('重连失败:', err);
      });
    }, this.RECONNECT_DELAY_MS);
  }

  /**
   * 连接到支持匿名访问的公共MQTT服务器
   */
  async connectToPublicBroker(): Promise<boolean> {
    this.clearCredentials();
    return this.connect();
  }

  /**
   * 连接到需要认证的私有MQTT服务器
   */
  async connectToPrivateBroker(username: string, password: string): Promise<boolean> {
    this.setCredentials(username, password);
    return this.connect();
  }

  /**
   * 设置事件监听器（基于回调函数）
   */
  private setupEventListeners(client: MqttClient, generation: number): void {
    client.connectLost((err: Error) => {
      // 旧 client 的延迟回调不能修改新连接状态。
      if (this.disposed || generation !== this.clientGeneration || this.mqttClient !== client) return;

      console.info('MQTT连接已断开');
      this.diagnostic('ERROR', `connection lost reason=${err ? err.message : 'unknown'} pending=${this.pendingMessages.length}`);
      if (err) {
        console.error(`连接断开原因: ${err.message}`);
      }
      this.isConnected = false;
      this.activeSubscriptions.clear();
      this.subscribingTopics.clear();
      if (this.manualReconnect && !this.closing) {
        this.scheduleReconnect();
      }
    });

    client.messageArrived((err: Error, message: MqttMessage) => {
      if (this.disposed || generation !== this.clientGeneration || this.mqttClient !== client) return;
      if (err) {
        console.error(`接收数据出错：${err.message}`);
        return;
      }
      if (!message) return;

      const topic = message.topic;
      const messageData = message.payload;
      console.info(`收到消息 [${topic}]: ${messageData}`);
      this.handleIncomingMessage(topic, messageData);
    });
  }

  /**
   * 获取最新的风数据
   */
  getLatestWindData(): WindDataMessage {
    return this.windData;
  }

  /**
   * 获取风数据更新时间
   */
  getWindDataUpdateTime(): number {
    return this.windDataUpdateTime;
  }

  /**
   * 解析风数据消息
   */
  private parseWindDataMessage(message: string): WindDataMessage | null {
    try {
      const parsedData: WindDataMessage = JSON.parse(message) as WindDataMessage;

      // 验证必要字段是否存在
      if (parsedData.windSourceBoatCode === undefined ||
        parsedData.windSpeed === undefined ||
        parsedData.windDirection === undefined ||
        parsedData.longitude === undefined ||
        parsedData.latitude === undefined ||
        parsedData.ts === undefined) {
        console.warn('风数据消息缺少必要字段');
        return null;
      }

      const windData: WindDataMessage = {
        windSourceBoatCode: String(parsedData.windSourceBoatCode),
        windSpeed: Number(parsedData.windSpeed),
        windDirection: Number(parsedData.windDirection),
        customWindSpeed: Number(parsedData.customWindSpeed || 0),
        customWindDirection: Number(parsedData.customWindDirection || 0),
        longitude: Number(parsedData.longitude),
        latitude: Number(parsedData.latitude),
        ts: String(parsedData.ts)
      };

      return windData;
    } catch (error) {
      console.error(`风数据消息解析失败: ${formatErrorMessage(error as Error)}`);
      return null;
    }
  }

  /**
   * 处理接收到的消息
   */
  private async handleIncomingMessage(topic: string, message: string): Promise<void> {
    // console.info(`处理消息 [${topic}]: ${message}`);
    try {
      // 根据主题类型处理不同的消息
      if (topic.includes('wind')) {
        // 解析风数据消息
        const windData = this.parseWindDataMessage(message);
        if (windData) {
          this.windData = windData;
          this.windDataUpdateTime = Date.now();
          console.info('风数据更新成功:', windData);

          // 触发数据更新事件（如果需要）
          this.triggerWindDataUpdate(windData);
        }
      }

    } catch (error) {
      console.error(`消息处理失败: ${formatErrorMessage(error as Error)}`);
    }

  }

  /**
   * 触发风数据更新事件（可选）
   */
  private triggerWindDataUpdate(data: WindDataMessage): void {
    // 这里可以添加事件触发逻辑，比如通知其他组件
    console.info('风数据已更新，时间:', data.ts);
  }
  /**
   * 格式化显示风数据
   */
  formatWindDataForDisplay(): string {
    if (!this.windData) {
      return '暂无风数据';
    }

    const data = this.windData;
    return `风速: ${data.windSpeed.toFixed(2)} cm/s\n` +
      `风向: ${data.windDirection}°\n` +
      `位置: ${data.latitude.toFixed(6)}, ${data.longitude.toFixed(6)}\n` +
      `时间: ${data.ts}\n` +
      `来源: ${data.windSourceBoatCode}`;
  }

  async publish(topic: string, payload: string, qos: MqttQos = 1): Promise<boolean> {
    const message: PendingMqttMessage = {
      topic,
      payload,
      qos
    };
    this.enqueuePendingMessage(message);
    this.flushPendingMessages().catch((error: Error) => {
      console.error(`MQTT发送队列异常: ${formatErrorMessage(error)}`);
    });
    return true;
  }

  private enqueuePendingMessage(message: PendingMqttMessage): void {
    if (this.pendingMessages.length >= this.MAX_PENDING_MESSAGES) {
      this.pendingMessages.shift();
      console.warn('MQTT离线队列已满，丢弃最旧消息');
      this.diagnostic('ERROR', `queue full, oldest message dropped capacity=${this.MAX_PENDING_MESSAGES}`);
    }
    this.pendingMessages.push(message);
    if (!this.isConnected) {
      console.warn(`MQTT消息已进入离线队列，当前数量: ${this.pendingMessages.length}`);
      const now: number = Date.now();
      if (now - this.lastOfflineQueueLogAt >= 10000 || this.pendingMessages.length === 1) {
        this.lastOfflineQueueLogAt = now;
        this.diagnostic('WARN', `offline queue pending=${this.pendingMessages.length}`);
      }
    }
  }

  private async publishDirect(message: PendingMqttMessage): Promise<boolean> {
    const client = this.mqttClient;
    const generation = this.clientGeneration;
    if (!client || !this.isConnected || this.closing || this.disposed) return false;

    try {
      await client.publish({
        topic: message.topic,
        payload: message.payload,
        qos: message.qos,
      });
      if (generation !== this.clientGeneration || this.mqttClient !== client) return false;
      console.info(`消息已发布 [${message.topic}]: ${message.payload}`);
      return true;
    } catch (err) {
      console.error(`发布失败: ${JSON.stringify(err)}`);
      this.diagnostic('ERROR', `publish failed topic=${message.topic} pending=${this.pendingMessages.length} error=${JSON.stringify(err)}`);

      // 单次 publish 超时不等同于连接一定断开，以 native 状态为准。
      let connected = false;
      try {
        connected = await client.isConnected();
      } catch (_) {
        connected = false;
      }
      if (generation === this.clientGeneration && this.mqttClient === client) {
        this.isConnected = connected;
        if (!connected && this.manualReconnect && !this.disposed && !this.closing) {
          this.scheduleReconnect();
        }
      }
      return false;
    }
  }

  private async flushPendingMessages(): Promise<void> {
    if (this.publishDrainActive) {
      return;
    }
    this.publishDrainActive = true;
    try {
      while (this.pendingMessages.length > 0 && this.mqttClient && this.isConnected) {
        const message: PendingMqttMessage = this.pendingMessages[0];
        const published: boolean = await this.publishDirect(message);
        if (!published) {
          break;
        }
        this.pendingMessages.shift();
      }
    } finally {
      this.publishDrainActive = false;
    }
    if (this.pendingMessages.length > 0 && this.mqttClient && this.isConnected) {
      this.flushPendingMessages().catch((error: Error) => {
        console.error(`继续MQTT发送队列失败: ${formatErrorMessage(error)}`);
      });
    }
  }

  getPendingMessageCount(): number {
    return this.pendingMessages.length;
  }

  async subscribe(topic: string, qos: MqttQos = 1): Promise<void> {
    this.rememberSubscription(topic, qos);
    const key = `${topic}|${qos}`;
    if (this.activeSubscriptions.has(key) || this.subscribingTopics.has(key)) return;

    const client = this.mqttClient;
    const generation = this.clientGeneration;
    if (!client || !this.isConnected || this.closing || this.disposed) return;

    this.subscribingTopics.add(key);
    try {
      await client.subscribe({ topic, qos });
      if (generation === this.clientGeneration && this.mqttClient === client) {
        this.activeSubscriptions.add(key);
        console.info(`已订阅: ${topic}`);
      }
    } catch (err) {
      console.error(`订阅失败: ${JSON.stringify(err)}`);
    } finally {
      this.subscribingTopics.delete(key);
    }
  }

  private rememberSubscription(topic: string, qos: MqttQos): void {
    for (let i: number = 0; i < this.subscriptions.length; i++) {
      if (this.subscriptions[i].topic === topic) {
        this.subscriptions[i].qos = qos;
        return;
      }
    }
    const subscription: MqttSubscription = {
      topic: topic,
      qos: qos
    };
    this.subscriptions.push(subscription);
  }

  private async restoreSubscriptions(): Promise<void> {
    const client = this.mqttClient;
    const generation = this.clientGeneration;
    if (!client || !this.isConnected) return;

    for (let i: number = 0; i < this.subscriptions.length; i++) {
      const subscription: MqttSubscription = this.subscriptions[i];
      const key = `${subscription.topic}|${subscription.qos}`;
      if (this.activeSubscriptions.has(key)) continue;
      try {
        await client.subscribe({ topic: subscription.topic, qos: subscription.qos });
        if (generation !== this.clientGeneration || this.mqttClient !== client) return;
        this.activeSubscriptions.add(key);
        console.info(`已恢复订阅: ${subscription.topic}`);
      } catch (error) {
        console.error(`恢复订阅失败: ${formatErrorMessage(error as Error)}`);
      }
    }
  }

  async unsubscribe(topic: MqttSubscribeOptions): Promise<void> {
    if (this.mqttClient && this.isConnected) {
      try {
        await this.mqttClient.unsubscribe(topic);
        console.info(`已取消订阅: ${topic}`);
      } catch (err) {
        console.error(`取消订阅失败: ${JSON.stringify(err)}`);
      }
    }
  }

  clearSubscriptions(): void {
    this.subscriptions = [];
  }

  /**
   * 获取连接信息（用于调试）
   */
  getConnectionInfo(): string {
    return `连接状态: ${this.isConnected ? '已连接' : '未连接'}, ` +
      `认证方式: ${this.hasCredentials() ? '用户名密码' : '匿名'}, ` +
      `服务器: ${this.useSSL ? 'mqtts' : 'mqtt'}://${this.host}:${this.port}`;
  }

  /**
   * 清理重连定时器
   */
  private clearReconnectTimer(): void {
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  async disconnect(): Promise<void> {
    this.manualReconnect = false;
    this.closing = true;
    this.clearReconnectTimer();
    try {
      await this.safeDisconnectAndClear("manual");
    } finally {
      this.closing = false;
    }
  }

  async destroy(): Promise<void> {
    // 顺序很重要：先阻止所有新任务和重连，再销毁 native client。
    this.disposed = true;
    this.manualReconnect = false;
    this.closing = true;
    this.clearReconnectTimer();
    await this.safeDisconnectAndClear("destroy");
  }
}

export async function get_level(tenantCode: number, is_test: boolean) : Promise<level_rec>{

  let err_level : level_rec = {
    success: false,
    errCode: "null",
    errMessage: "err",
    data: [
      {
        levelId: "err",
        levelName: "err"
      }
    ]
  }
  let url: string = ""
  if(is_test){
    url = `https://test.ironmanapi.com:8046/sailboat-api/basic/watch/sailboat/level?tenantCode=${tenantCode}`
  }else {
    url = `https://sport.ironmanapi.com:8046/sailboat-api/basic/watch/sailboat/level?tenantCode=${tenantCode}`
  }

  const httpRequest = http.createHttp();
  try{
    const response = await httpRequest.request(
      url,
      {
        method: http.RequestMethod.GET,
        connectTimeout: 3000
      }
    )

    // 转换为 level_rec 类型
    const result = JSON.parse(String(response.result)) as level_rec;
    // console.log(JSON.stringify(result.data))
    // console.log(String(response.result));
    return result;
  } catch (err) {
    console.error(formatErrorMessage(err as Error))
    return err_level
  } finally {
    httpRequest.destroy();
  }

}

export async function get_group(levelId: string, is_test: boolean) : Promise<group_rec>{

  let err_group : group_rec = {
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
  }

  let url: string = ""
  if(is_test){
    url = `https://test.ironmanapi.com:8046/sailboat-api/basic/watch/sailboat/group?levelId=${levelId}`
  }else {
    url = `https://sport.ironmanapi.com:8046/sailboat-api/basic/watch/sailboat/group?levelId=${levelId}`
  }


  const httpRequest = http.createHttp();
  try{
    const response = await httpRequest.request(
      url,
      {
        method: http.RequestMethod.GET,
        connectTimeout: 3000
      }
    )

    // 转换为 level_rec 类型
    const result = JSON.parse(String(response.result)) as group_rec;
    // console.log(JSON.stringify(result.data))
    // console.log(String(response.result));
    return result;
  } catch (err) {
    console.error(formatErrorMessage(err as Error))
    return err_group
  } finally {
    httpRequest.destroy();
  }

}

export async function get_group_test(levelId: string) : Promise<group_rec>{

  let err_group : group_rec = {
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
  }

  const httpRequest = http.createHttp();
  try{
    const response = await httpRequest.request(
      `https://test.ironmanapi.com:8046/sailboat-api/basic/watch/sailboat/group?levelId=${levelId}`,
      {
        method: http.RequestMethod.GET,
        connectTimeout: 3000
      }
    )

    // 转换为 level_rec 类型
    const result = JSON.parse(String(response.result)) as group_rec;
    // console.log(JSON.stringify(result.data))
    // console.log(String(response.result));
    return result;
  } catch (err) {
    console.error(formatErrorMessage(err as Error))
    return err_group
  } finally {
    httpRequest.destroy();
  }

}
