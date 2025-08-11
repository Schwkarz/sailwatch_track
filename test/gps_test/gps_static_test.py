import json
import numpy as np
import matplotlib.pyplot as plt
from geopy.distance import geodesic
from scipy import stats
import matplotlib as mpl


# 设置中文字体
mpl.rcParams['font.sans-serif'] = ['SimHei']  # 使用黑体
mpl.rcParams['axes.unicode_minus'] = False  # 解决负号显示问题

def load_gps_data(file_path):
    """加载JSON格式的GPS数据"""
    with open(file_path, 'r') as f:
        data = json.load(f)
    return [(item['location'][1], item['location'][0]) for item in data]  # (lat, lon)

def calculate_offsets(points):
    """计算各点相对于中心点的偏移"""
    center = np.mean(points, axis=0) #计算平均值，得到几何中心
    distances = [geodesic(center, point).meters for point in points]
    return center, distances

def analyze_static_gps(points):
    """分析静态GPS数据"""
    center, distances = calculate_offsets(points)
    
    # 基本统计
    median = np.median(distances)
    mean = np.mean(distances)
    std_dev = np.std(distances)
    max_offset = np.max(distances)
    
    # 计算CEP(圆概率误差)
    cep50 = np.percentile(distances, 50)
    cep95 = np.percentile(distances, 95)
    
    # 正态性检验
    k2, p = stats.normaltest(distances)
    normal_dist = p >= 0.05
    
    return {
        "center_point": center,
        "total_points": len(points),
        "median_offset": median,
        "mean_offset": mean,
        "std_deviation": std_dev,
        "max_offset": max_offset,
        "cep50": cep50,
        "cep95": cep95,
        "is_normal_dist": normal_dist
    }

def plot_offsets(points, center, distances):
    """可视化偏移情况"""
    # 转换为米为单位的坐标
    center_lat, center_lon = center
    x = []
    y = []
    for point in points:
        lat, lon = point
        dx = geodesic(center, (center_lat, lon)).meters * (1 if lon > center_lon else -1)
        dy = geodesic(center, (lat, center_lon)).meters * (1 if lat > center_lat else -1)
        x.append(dx)
        y.append(dy)
    
    plt.figure(figsize=(12, 10))
    
    # 绘制散点图
    plt.scatter(x, y, alpha=0.6, label='GPS点位')
    plt.scatter(0, 0, c='r', s=100, label='中心点')
    
    # 绘制CEP圆
    cep50 = np.percentile(distances, 50)
    cep95 = np.percentile(distances, 95)
    
    circle50 = plt.Circle((0, 0), cep50, color='r', fill=False, linestyle='--', label='CEP50')
    circle95 = plt.Circle((0, 0), cep95, color='g', fill=False, linestyle=':', label='CEP95')
    plt.gca().add_patch(circle50)
    plt.gca().add_patch(circle95)
    
    # 设置图形属性
    max_range = max(max(np.abs(x)), max(np.abs(y))) * 1.1
    plt.xlim(-max_range, max_range)
    plt.ylim(-max_range, max_range)
    plt.gca().set_aspect('equal', adjustable='box')
    
    plt.title('静态GPS偏移分析\n(以中心点为原点的XY坐标，单位：米)')
    plt.xlabel('东/西方向偏移 (米)')
    plt.ylabel('北/南方向偏移 (米)')
    plt.grid(True)
    plt.legend()
    
    # 添加统计信息
    stats_text = (
        f"总点数: {len(points)}\n"
        f"平均偏移: {np.mean(distances):.2f} m\n"
        f"标准差: {np.std(distances):.2f} m\n"
        f"CEP50: {cep50:.2f} m\n"
        f"CEP95: {cep95:.2f} m\n"
        f"最大偏移: {np.max(distances):.2f} m"
    )
    plt.text(0.02, 0.98, stats_text, 
             transform=plt.gca().transAxes,
             verticalalignment='top',
             bbox=dict(facecolor='white', alpha=0.8))
    
    plt.show()

def plot_offset_distribution(distances):
    """绘制偏移距离分布直方图"""
    plt.figure(figsize=(10, 6))
    n, bins, patches = plt.hist(distances, bins=20, edgecolor='black', alpha=0.7)
    
    # 添加正态分布曲线
    mu = np.mean(distances)
    sigma = np.std(distances)
    y = ((1 / (np.sqrt(2 * np.pi) * sigma)) *
         np.exp(-0.5 * (1 / sigma * (bins - mu))**2))
    y *= len(distances) * (bins[1] - bins[0])  # 缩放以匹配直方图
    plt.plot(bins, y, 'r--', linewidth=2)
    
    plt.title('GPS偏移距离分布')
    plt.xlabel('偏移距离 (米)')
    plt.ylabel('点数')
    plt.grid(True)
    plt.show()

def plot_combined(points, center, distances):
    """合并散点图和直方图到一个窗口"""
    plt.figure(figsize=(12, 6))  # 调整窗口大小（宽12，高6）
    
    # ----------------- 散点图（左子图） -----------------
    plt.subplot(1, 2, 1)  # 1行2列，第1个子图
    
    # 转换为米为单位的坐标
    center_lat, center_lon = center
    x = []
    y = []
    for point in points:
        lat, lon = point
        dx = geodesic(center, (center_lat, lon)).meters * (1 if lon > center_lon else -1)
        dy = geodesic(center, (lat, center_lon)).meters * (1 if lat > center_lat else -1)
        x.append(dx)
        y.append(dy)
    
    # 绘制散点图
    plt.scatter(x, y, alpha=0.6, label='GPS点位')
    plt.scatter(0, 0, c='r', s=100, label='中心点')
    
    # 绘制CEP圆
    cep50 = np.percentile(distances, 50)
    cep95 = np.percentile(distances, 95)
    circle50 = plt.Circle((0, 0), cep50, color='r', fill=False, linestyle='--', label='CEP50')
    circle95 = plt.Circle((0, 0), cep95, color='g', fill=False, linestyle=':', label='CEP95')
    plt.gca().add_patch(circle50)
    plt.gca().add_patch(circle95)
    
    # 设置图形属性
    max_range = max(max(np.abs(x)), max(np.abs(y))) * 1.1
    plt.xlim(-max_range, max_range)
    plt.ylim(-max_range, max_range)
    plt.gca().set_aspect('equal', adjustable='box')
    plt.title('静态GPS偏移分析')
    plt.xlabel('东/西方向偏移 (米)')
    plt.ylabel('北/南方向偏移 (米)')
    plt.grid(True)
    plt.legend(loc='upper right')
    
    # ----------------- 直方图（右子图） -----------------
    plt.subplot(1, 2, 2)  # 1行2列，第2个子图
    
    # 绘制直方图
    n, bins, patches = plt.hist(distances, bins=20, edgecolor='black', alpha=0.7)
    
    # 添加正态分布曲线
    mu = np.mean(distances)
    sigma = np.std(distances)
    y = ((1 / (np.sqrt(2 * np.pi) * sigma)) *
         np.exp(-0.5 * (1 / sigma * (bins - mu))**2))
    y *= len(distances) * (bins[1] - bins[0])  # 缩放以匹配直方图
    plt.plot(bins, y, 'r--', linewidth=2)
    
    plt.title('GPS偏移距离分布')
    plt.xlabel('偏移距离 (米)')
    plt.ylabel('点数')
    plt.grid(True)
    
    # 调整子图间距
    plt.tight_layout()
    plt.savefig('static_test_1.png')
    plt.show()
   

if __name__ == '__main__':
    # 文件路径
    json_file = 'static_gps_data_1.json'
    
    try:
        # 加载数据
        gps_points = load_gps_data(json_file)
        print(f"成功加载 {len(gps_points)} 个GPS点")
        
        # 分析数据
        analysis = analyze_static_gps(gps_points)
        print("\n静态GPS分析结果:")
        for key, value in analysis.items():
            print(f"{key:15}: {value}")
        
        # 合并可视化
        center, distances = calculate_offsets(gps_points)
        plot_combined(gps_points, center, distances)
        
    except Exception as e:
        print(f"处理失败: {str(e)}")