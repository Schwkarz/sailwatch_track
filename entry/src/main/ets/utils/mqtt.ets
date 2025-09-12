import { MqttClient, MqttConnectOptions, MqttResponse, MqttMessage, MqttQos, MqttSubscribeOptions } from '@ohos/mqtt';
import http from '@ohos.net.http';
import { JSON } from '@kit.ArkTS';

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

  headingT: number,  //航向 °（真北）
  headingM: number,  //航向 °（磁北） headingM = (headingT - declination) % 360
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

  public isConnected: boolean = false;

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


  // 连接配置选项（用户名密码可选）
  private connectOptions: MqttConnectOptions = {
    userName: undefined,      // 设置为undefined表示可选
    password: undefined,      // 设置为undefined表示可选
    connectTimeout: 30,
    sslOptions: {
      enableServerCertAuth: true
    },
    keepAliveInterval: 60,
    cleanSession: true,
    automaticReconnect: true,
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



  async connect(customClientId? : string): Promise<boolean> {
    try {
      const clientId: string = customClientId ?? `mqtt_${Math.random().toString(16).slice(3)}`;
      const protocol = this.useSSL ? 'mqtts' : 'mqtt';

      // const clientId = `mqtt_${Math.random().toString(16).slice(3)}`;
      // const protocol = this.useSSL ? 'mqtts' : 'mqtt';
      const url = `${protocol}://${this.host}:${this.port}`;

      // 创建MQTT客户端实例
      this.mqttClient = new MqttClient({
        url: url,
        clientId: clientId,
        persistenceType: 1,
      });

      // 设置事件监听器
      this.setupEventListeners();

      // 构建连接选项
      const finalOptions: MqttConnectOptions = {
        connectTimeout: this.connectOptions.connectTimeout || 30,
        sslOptions: {
          enableServerCertAuth: true
        },
        keepAliveInterval: this.connectOptions.keepAliveInterval || 60,
        cleanSession: this.connectOptions.cleanSession ?? true,
        automaticReconnect: this.connectOptions.automaticReconnect ?? true
      };

      // 可选添加用户名密码
      if (this.connectOptions.userName) {
        finalOptions.userName = this.connectOptions.userName;
      }
      if (this.connectOptions.password) {
        finalOptions.password = this.connectOptions.password;
      }

      // 建立连接
      const response: MqttResponse = await this.mqttClient.connect(finalOptions);

      // 连接成功处理
      const authType = this.hasCredentials() ? '认证连接' : '匿名连接';
      console.info(`MQTT${authType}成功: ${JSON.stringify(response)}`);
      this.isConnected = true;

      return true;
    } catch (error) {
      console.error(`MQTT连接失败: ${JSON.stringify(error)}`);
      this.isConnected = false;
      this.scheduleReconnect();
      return false;
    }
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
  private setupEventListeners(): void {
    if (!this.mqttClient) return;

    // 1. 连接丢失回调 - 参数是 Error 类型
    this.mqttClient.connectLost((err: Error) => {
      console.info('MQTT连接已断开');
      if (err) {
        console.error(`连接断开原因: ${err.message}`);
      }
      this.isConnected = false;
      this.scheduleReconnect();
    });

    // 2. 消息到达回调 - 参数是 MqttMessage 类型
    this.mqttClient.messageArrived(
      (err: Error, message: MqttMessage) => {
        if(err) {
          console.error(`接收数据出错：${err.message}`)
        }

        // 假设 MqttMessage 包含 topic 和 payload 属性
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
      if (!parsedData.windSourceBoatCode ||
        !parsedData.windSpeed ||
        !parsedData.windDirection ||
        !parsedData.longitude ||
        !parsedData.latitude ||
        !parsedData.ts) {
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
      console.error(`风数据消息解析失败: ${error.message}`);
      return null;
    }
  }

  /**
   * 处理接收到的消息
   */
  private handleIncomingMessage(topic: string, message: string): void {
    // console.info(`处理消息 [${topic}]: ${message}`);
    try {
      // 根据主题类型处理不同的消息
      if (topic.includes('wind') || topic.includes('sailboat')) {
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
      console.error(`消息处理失败: ${error.message}`);
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

  async publish(topic: string, payload: string, qos: MqttQos = 1): Promise<void> {
    if (this.mqttClient && this.isConnected) {
      try {
        await this.mqttClient.publish({
          topic: topic,
          payload: payload,
          qos: qos,
        });
        console.info(`消息已发布 [${topic}]: ${payload}`);
      } catch (err) {
        console.error(`发布失败: ${JSON.stringify(err)}`);
      }
    }
  }

  async subscribe(topic: string, qos: MqttQos = 1): Promise<void> {
    if (this.mqttClient && this.isConnected) {
      try {
        await this.mqttClient.subscribe({ topic, qos });
        console.info(`已订阅: ${topic}`);
      } catch (err) {
        console.error(`订阅失败: ${JSON.stringify(err)}`);
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

  /**
   * 获取连接信息（用于调试）
   */
  getConnectionInfo(): string {
    return `连接状态: ${this.isConnected ? '已连接' : '未连接'}, ` +
      `认证方式: ${this.hasCredentials() ? '用户名密码' : '匿名'}, ` +
      `服务器: ${this.useSSL ? 'mqtts' : 'mqtt'}://${this.host}:${this.port}`;
  }

  /**
   * 安排重连
   */
  private scheduleReconnect(): void {
    // 先清除现有的重连定时器
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }

    this.reconnectTimer = setTimeout(() => {
      console.info('尝试重新连接MQTT服务器...');
      this.connect().catch((err: Error) => {
        console.error('重连失败:', err);
      });
    }, 5000);
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

  /**
   * 断开连接（需要调用清理方法）
   */
  async disconnect(): Promise<void> {
    this.clearReconnectTimer(); // 清理重连定时器

    if (this.mqttClient && this.isConnected) {
      try {
        await this.mqttClient.disconnect();
        console.info('MQTT连接已正常断开');
      } catch (error) {
        console.error(`断开连接失败: ${JSON.stringify(error)}`);
      } finally {
        this.isConnected = false;
        this.mqttClient = null;
      }
    }
  }

  /**
   * 销毁资源
   */
  destroy(): void {
    this.clearReconnectTimer(); // 清理重连定时器
    this.disconnect(); // 断开连接
  }
}

export async function get_level() : Promise<level_rec>{

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

  try{
    const httpRequest = http.createHttp();

    const response = await httpRequest.request(
      "https://test.ironmanapi.com:8046/sailboat-api/basic/watch/sailboat/level?tenantCode=1188",
      {
        method: http.RequestMethod.GET,
        connectTimeout: 3000
      }
    )

    // 转换为 level_rec 类型
    const result = JSON.parse(String(response.result)) as level_rec;
    // console.log(JSON.stringify(result.data))
    // console.log(String(response.result));
    httpRequest.destroy();
    return result;
  } catch (err) {
    console.error(err.message)
    return err_level
  }

}

export async function get_group(levelId: string) : Promise<group_rec>{

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

  try{
    const httpRequest = http.createHttp();

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
    httpRequest.destroy();
    return result;
  } catch (err) {
    console.error(err.message)
    return err_group
  }

}