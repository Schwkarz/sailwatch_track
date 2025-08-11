# import json
# import matplotlib.pyplot as plt
# from mpl_toolkits.basemap import Basemap
# import numpy as np

# # 1. 读取JSON文件
# def load_gps_data(file_path):
#     with open(file_path, 'r') as f:
#         data = json.load(f)
#     return [(item['location'][0], item['location'][1]) for item in data]

# # 2. 绘制轨迹曲线
# def plot_gps_trajectory(coordinates):
#     # 提取经纬度
#     lons, lats = zip(*coordinates)
    
#     # 创建地图底图
#     plt.figure(figsize=(12, 8))
#     m = Basemap(projection='merc',
#                 llcrnrlat=min(lats)-0.01, urcrnrlat=max(lats)+0.01,
#                 llcrnrlon=min(lons)-0.01, urcrnrlon=max(lons)+0.01,
#                 resolution='h')
    
#     # 绘制地图元素
#     m.drawcoastlines()
#     m.drawcountries()
#     m.fillcontinents(color='lightgray', lake_color='aqua')
#     m.drawmapboundary(fill_color='aqua')
    
#     # 转换坐标
#     x, y = m(lons, lats)
    
#     # 绘制轨迹
#     m.plot(x, y, 'r-', linewidth=2, label='Trajectory')
#     m.plot(x[0], y[0], 'go', markersize=10, label='Start')
#     m.plot(x[-1], y[-1], 'bo', markersize=10, label='End')
    
#     # 添加标注点（每隔N个点标注一个）
#     for i in range(0, len(x), len(x)//5):
#         plt.text(x[i], y[i], f'{i+1}', fontsize=10, color='black')
    
#     plt.title('GPS Trajectory Visualization')
#     plt.legend()
#     plt.show()

# # 3. 主程序
# if __name__ == '__main__':
#     # 文件路径
#     json_file = 'move_gps_data_2.json'
    
#     # 加载数据
#     try:
#         gps_coords = load_gps_data(json_file)
#         print(f"成功加载 {len(gps_coords)} 个GPS点")
        
#         # 绘制轨迹
#         plot_gps_trajectory(gps_coords)
        
#     except Exception as e:
#         print(f"处理失败: {str(e)}")

# import json
# import numpy as np
# import matplotlib.pyplot as plt
# import matplotlib as mpl

# # 设置中文字体
# mpl.rcParams['font.sans-serif'] = ['SimHei']  # 使用黑体
# mpl.rcParams['axes.unicode_minus'] = False  # 解决负号显示问题

# def analyze_gps_update_frequency(file_path):
#     # 加载数据
#     with open(file_path, 'r') as f:
#         data = json.load(f)
    
#     # 提取位置和时间戳
#     locations = [item['location'] for item in data]
#     timestamps = [item['timestamp'] for item in data]
    
#     # 计算有效更新点（仅当位置变化时）
#     valid_updates = []
#     last_location = None
    
#     for i, (loc, ts) in enumerate(zip(locations, timestamps)):
#         if last_location is None or loc != last_location:
#             valid_updates.append({
#                 'index': i,
#                 'timestamp': ts,
#                 'location': loc
#             })
#             last_location = loc
    
#     # 计算有效更新的时间间隔（毫秒）
#     intervals = []
#     for i in range(1, len(valid_updates)):
#         delta = valid_updates[i]['timestamp'] - valid_updates[i-1]['timestamp']
#         intervals.append(delta)
    
#     # 转换为秒和频率
#     intervals_sec = np.array(intervals) / 1000.0
#     frequencies = 1.0 / intervals_sec  # 瞬时频率（Hz）
    
#     # 统计结果
#     stats = {
#         'total_points': len(locations),
#         'valid_updates': len(valid_updates),
#         'update_ratio': len(valid_updates) / len(locations),
#         'min_interval': np.min(intervals_sec),
#         'max_interval': np.max(intervals_sec),
#         'mean_interval': np.mean(intervals_sec),
#         'mean_frequency': np.mean(frequencies),
#         'median_frequency': np.median(frequencies)
#     }
    
#     return stats, valid_updates, intervals_sec

# def plot_frequency_analysis(intervals_sec, stats):
#     plt.figure(figsize=(12, 6))
    
#     # 绘制时间间隔分布
#     plt.subplot(1, 2, 1)
#     plt.hist(intervals_sec, bins=20, edgecolor='black', alpha=0.7)
#     plt.xlabel('有效更新时间间隔 (秒)')
#     plt.ylabel('出现次数')
#     plt.title('有效更新间隔分布')
#     plt.grid(True)
    
#     # 绘制统计信息
#     plt.subplot(1, 2, 2)
#     stats_text = (
#         f"总数据点: {stats['total_points']}\n"
#         f"有效更新点: {stats['valid_updates']}\n"
#         f"有效更新比例: {stats['update_ratio']:.1%}\n"
#         f"平均间隔: {stats['mean_interval']:.3f} 秒\n"
#         f"平均频率: {stats['mean_frequency']:.2f} Hz\n"
#         f"中位频率: {stats['median_frequency']:.2f} Hz"
#     )
#     plt.text(0.1, 0.5, stats_text, fontsize=12, 
#              bbox=dict(facecolor='white', alpha=0.8))
#     plt.axis('off')
    
#     plt.tight_layout()
#     plt.show()

# if __name__ == '__main__':
#     json_file = 'move_gps_data_1 copy.json'
    
#     try:
#         stats, valid_updates, intervals = analyze_gps_update_frequency(json_file)
        
#         print("GPS更新频率分析结果:")
#         print(f"- 总数据点: {stats['total_points']}")
#         print(f"- 有效更新点: {stats['valid_updates']} (比例: {stats['update_ratio']:.1%})")
#         print(f"- 平均更新间隔: {stats['mean_interval']:.3f} 秒")
#         print(f"- 平均频率: {stats['mean_frequency']:.2f} Hz")
        
#         plot_frequency_analysis(intervals, stats)
        
#     except Exception as e:
#         print(f"处理失败: {str(e)}")

import json
import numpy as np
import matplotlib.pyplot as plt
from geopy.distance import geodesic

import matplotlib as mpl

# 设置中文字体
mpl.rcParams['font.sans-serif'] = ['SimHei']  # 使用黑体
mpl.rcParams['axes.unicode_minus'] = False  # 解决负号显示问题

def analyze_gps_update_distance(file_path):
    # 加载数据
    with open(file_path, 'r') as f:
        data = json.load(f)
    
    # 提取位置和时间戳
    locations = [item['location'] for item in data]
    timestamps = [item['timestamp'] for item in data]
    
    # 计算有效更新点（仅当位置变化时）
    valid_updates = []
    last_location = None
    
    for i, (loc, ts) in enumerate(zip(locations, timestamps)):
        if last_location is None or loc != last_location:
            valid_updates.append({
                'index': i,
                'timestamp': ts,
                'location': loc
            })
            last_location = loc
    
    # 计算相邻有效更新点之间的距离（米）
    distances = []
    for i in range(1, len(valid_updates)):
        loc1 = valid_updates[i-1]['location']
        loc2 = valid_updates[i]['location']
        # 计算两点之间的真实距离（单位：米）
        distance = geodesic((loc1[1], loc1[0]), (loc2[1], loc2[0])).meters
        distances.append(distance)
    
    # 统计结果
    stats = {
        'total_points': len(locations),
        'valid_updates': len(valid_updates),
        'update_ratio': len(valid_updates) / len(locations),
        'min_distance_m': np.min(distances),
        'max_distance_m': np.max(distances),
        'mean_distance_m': np.mean(distances),
        'median_distance_m': np.median(distances),
        'std_distance_m': np.std(distances),
    }
    
    return stats, valid_updates, distances

def plot_distance_analysis(distances, stats):
    plt.figure(figsize=(12, 5))
    
    # 绘制移动距离分布直方图
    plt.subplot(1, 2, 1)
    plt.hist(distances, bins=20, edgecolor='black', alpha=0.7)
    plt.xlabel('移动距离 (米)')
    plt.ylabel('出现次数')
    plt.title('GPS 更新时的移动距离分布')
    plt.grid(True)
    
    # 绘制统计信息
    plt.subplot(1, 2, 2)
    stats_text = (
        f"总数据点: {stats['total_points']}\n"
        f"有效更新点: {stats['valid_updates']}\n"
        f"更新比例: {stats['update_ratio']:.1%}\n"
        f"最小移动距离: {stats['min_distance_m']:.2f} 米\n"
        f"最大移动距离: {stats['max_distance_m']:.2f} 米\n"
        f"平均移动距离: {stats['mean_distance_m']:.2f} 米\n"
        f"中位移动距离: {stats['median_distance_m']:.2f} 米\n"
        f"标准差: {stats['std_distance_m']:.2f} 米"
    )
    plt.text(0.1, 0.5, stats_text, fontsize=10, 
             bbox=dict(facecolor='white', alpha=0.8))
    plt.axis('off')
    
    plt.tight_layout()
    plt.show()

if __name__ == '__main__':
    json_file = 'move_gps_data_1 copy.json'
    
    try:
        stats, valid_updates, distances = analyze_gps_update_distance(json_file)
        
        print("GPS 更新距离分析结果:")
        print(f"- 总数据点: {stats['total_points']}")
        print(f"- 有效更新点: {stats['valid_updates']} (比例: {stats['update_ratio']:.1%})")
        print(f"- 最小移动距离: {stats['min_distance_m']:.2f} 米")
        print(f"- 最大移动距离: {stats['max_distance_m']:.2f} 米")
        print(f"- 平均移动距离: {stats['mean_distance_m']:.2f} 米")
        print(f"- 中位移动距离: {stats['median_distance_m']:.2f} 米")
        
        plot_distance_analysis(distances, stats)
        
    except Exception as e:
        print(f"处理失败: {str(e)}")