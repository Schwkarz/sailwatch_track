import json
import matplotlib.pyplot as plt
import numpy as np

# 设置中文字体（显示坐标轴标签用）
plt.rcParams['font.sans-serif'] = ['SimHei']
plt.rcParams['axes.unicode_minus'] = False

def plot_speed_data(json_file):
    # 读取JSON文件
    with open(json_file, 'r') as f:
        data = json.load(f)
    
    # 提取speed数据和时间戳
    speeds = []
    timestamps = []
    for entry in data:
        if 'speed' in entry and 'timestamp' in entry:
            speeds.append(entry['speed'])
            timestamps.append(entry['timestamp'])
    
    if not speeds:
        print("文件中没有找到speed数据")
        return
    
    # 将时间戳转换为相对时间（秒）
    timestamps = np.array(timestamps)
    relative_time = (timestamps - timestamps[0]) / 1000  # 转换为秒
    
    # 计算统计信息
    avg_speed = np.mean(speeds)
    max_speed = max(speeds)
    min_speed = min(speeds)
    
    print(f"速度统计信息：")
    print(f"数据点数量: {len(speeds)}")
    print(f"平均速度: {avg_speed:.2f} m/s")
    print(f"最大速度: {max_speed:.2f} m/s")
    print(f"最小速度: {min_speed:.2f} m/s")
    
    # 创建图表
    plt.figure(figsize=(12, 6))
    
    # 绘制速度曲线
    plt.plot(relative_time, speeds, 
             color='#1f77b4', 
             linewidth=1.5, 
             marker='o',
             markersize=4,
             label='速度变化')
    
    # 添加平均线
    plt.axhline(y=avg_speed, 
                color='red', 
                linestyle='--', 
                linewidth=1.2,
                label=f'平均速度 ({avg_speed:.2f} m/s)')
    
    # 标记最大/最小速度
    plt.scatter(relative_time[speeds.index(max_speed)], max_speed,
               color='green', 
               s=100,
               label=f'最大速度 ({max_speed:.2f} m/s)')
    plt.scatter(relative_time[speeds.index(min_speed)], min_speed,
               color='purple', 
               s=100,
               label=f'最小速度 ({min_speed:.2f} m/s)')
    
    # 设置图表属性
    plt.title('速度变化趋势', fontsize=14, pad=20)
    plt.xlabel('时间 (秒)', fontsize=12)
    plt.ylabel('速度 (m/s)', fontsize=12)
    plt.grid(True, linestyle='--', alpha=0.6)
    plt.legend(loc='upper right', fontsize=10)
    
    # 自动调整坐标轴范围
    plt.xlim(left=0)
    plt.ylim(bottom=max(0, min_speed-0.5), top=max_speed+0.5)
    
    # 保存和显示图表
    plt.tight_layout()
    plt.savefig('speed_analysis.png', dpi=300)
    plt.show()

# 使用示例
if __name__ == "__main__":
    json_file = "sensor_data_1.json"  # 替换为你的JSON文件路径
    plot_speed_data(json_file)