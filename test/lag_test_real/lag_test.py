import json
import matplotlib.pyplot as plt
import matplotlib as mpl
import numpy as np

# 设置中文字体
mpl.rcParams['font.sans-serif'] = ['SimHei']  # 使用黑体
mpl.rcParams['axes.unicode_minus'] = False  # 解决负号显示问题

# 然后在绘制图表前设置字体
plt.rcParams['font.family'] = 'SimHei'

def analyze_time_differences(json_file):
    # 读取JSON文件
    with open(json_file, 'r') as f:
        data = json.load(f)
    
    # 提取所有时间差数据并过滤异常值
    time_diffs = []
    for entry in data:
        if 'lag_time' in entry:
            lag_time = entry['lag_time']
            # 定义正常范围（可根据实际情况调整）
            if 0 < lag_time < 6000:  # 假设6000ms是合理上限
                time_diffs.append(lag_time)
            else:
                print(f"发现异常值已过滤: {lag_time}")
        if 'speed' in entry:
            speed = entry['speed']
            # 定义正常范围（可根据实际情况调整）
            if 0 < speed:
                print(f"速度: {speed}")
    
    if not time_diffs:
        print("文件中没有有效的时间差数据")
        return


    
    # 计算统计信息
    average = np.mean(time_diffs)
    minimum = min(time_diffs)
    maximum = max(time_diffs)
    
    print(f"延时统计信息：")
    print(f"数据点数量: {len(time_diffs)}")
    print(f"平均值: {average:.2f}")
    print(f"最小值: {minimum}")
    print(f"最大值: {maximum}")
    
    # 绘制折线图
    plt.figure(figsize=(10, 6))
    plt.plot(time_diffs, marker='o', linestyle='-', color='b', label='延迟')
    
    # 添加平均线
    plt.axhline(y=average, color='r', linestyle='--', label=f'平均值 ({average:.2f})')
    
    # 设置图表标题和标签
    plt.title('延时变化趋势', fontsize=14)
    plt.xlabel('数据点序号', fontsize=12)
    plt.ylabel('延时', fontsize=12)
    plt.grid(True, linestyle='--', alpha=0.7)
    plt.legend()
    
    # 显示图表
    plt.tight_layout()
    plt.savefig('lag_test_1.png')
    # plt.show()

# 使用示例
if __name__ == "__main__":
    json_file = "sensor_data_1.json"  # 替换为您的JSON文件路径
    analyze_time_differences(json_file)
    