import re
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from datetime import datetime
import matplotlib as mpl

check_time = 15

# 设置中文字体
mpl.rcParams['font.sans-serif'] = ['SimHei']  # 使用黑体
mpl.rcParams['axes.unicode_minus'] = False  # 解决负号显示问题

def extract_sensor_intervals(log_file):
    """
    从日志文件中提取加速度传感器间隔时间
    :param log_file: 日志文件路径
    :return: 包含时间间隔的列表（单位：毫秒）
    """
    pattern = r"两次读取加速度传感器间隔：\s*(\d+)"
    intervals = []
    
    with open(log_file, 'r', encoding='utf-8') as file:
        for line in file:
            match = re.search(pattern, line)
            if match:
                interval = int(match.group(1))
                intervals.append(interval)
    
    return intervals

def analyze_intervals(intervals):
    """
    分析并可视化时间间隔数据
    :param intervals: 时间间隔列表（毫秒）
    """
    # 转换为DataFrame
    df = pd.DataFrame(intervals, columns=['interval_ms'])
    
    # 计算统计指标
    stats = df['interval_ms'].describe()
    stats['jitter'] = df['interval_ms'].std()  # 抖动（标准差）
    
    print("="*50)
    print("传感器时间间隔统计分析")
    print("="*50)
    print(f"数据点数: {len(df)}")
    print(f"平均值: {stats['mean']:.2f} ms")
    print(f"中位数: {stats['50%']:.2f} ms")
    print(f"最小值: {stats['min']} ms")
    print(f"最大值: {stats['max']} ms")
    print(f"标准差: {stats['jitter']:.2f} ms")
    
    # 可视化
    plt.figure(figsize=(14, 10))
    
    # 1. 时间间隔变化趋势
    plt.subplot(2, 1, 1)
    plt.plot(df.index, df['interval_ms'], 'b-o', markersize=4)
    plt.axhline(y=check_time, color='r', linestyle='--', label='目标间隔')
    plt.xlabel('样本序号')
    plt.ylabel('间隔时间 (ms)')
    plt.title('加速度传感器读取间隔变化')
    plt.grid(True, linestyle='--', alpha=0.7)
    plt.legend()
    
    # 2. 间隔分布直方图（修正此处）
    plt.subplot(2, 1, 2)
    bin_edges = np.arange(0, int(max(intervals)) + 5)  # 使用numpy数组替代range
    plt.hist(df['interval_ms'], bins=bin_edges, edgecolor='k', alpha=0.7, color='green')
    plt.axvline(x=check_time, color='r', linestyle='--', label='目标值')
    plt.xlabel('间隔时间 (ms)')
    plt.ylabel('出现次数')
    plt.title('间隔时间分布直方图')
    plt.grid(True, linestyle='--', alpha=0.7)
    plt.legend()
    
    plt.tight_layout()
    plt.savefig('sensor_test_4.png', dpi=300)
    plt.show()

# 使用示例
if __name__ == "__main__":
    try:
        log_file = "sensor_test_4.txt"  # 替换为您的日志文件路径
        
        # 步骤1: 从日志提取间隔数据
        intervals = extract_sensor_intervals(log_file)
        if not intervals:
            print("警告：未提取到任何间隔数据！")
        else:
            print(f"提取到 {len(intervals)} 个间隔数据点")
            print("前10个数据点:", intervals[:10])
            
            # 步骤2: 分析并可视化
            analyze_intervals(intervals)
    except MemoryError:
        print("内存不足，请尝试处理更小的数据集")
    except Exception as e:
        print(f"发生错误: {str(e)}")