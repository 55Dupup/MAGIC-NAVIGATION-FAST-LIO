import numpy as np
import open3d as o3d
import json

def level_pointcloud_pro(input_pcd_path, output_pcd_path,
                         dist_threshold=0.05,
                         target_ground_z=0.3,
                         two_pass=True):
    """
    改进版点云平整：
    1. 两次Rodrigues变换，进一步平整地面
    2. 将地面高度调整到目标值（默认0.3m，雷达相对地面高度）

    参数:
        input_pcd_path: 输入点云路径
        output_pcd_path: 输出点云路径
        dist_threshold: RANSAC距离阈值
        target_ground_z: 目标地面高度（默认0.3m）
        two_pass: 是否进行两次平面拟合（默认True）

    返回:
        transform_params: 变换参数字典，供重定位使用
    """
    pcd = o3d.io.read_point_cloud(input_pcd_path)
    points = np.asarray(pcd.points)

    if len(points) < 100:
        print("点太少")
        return None

    original_points = points.copy()
    R_total = np.eye(3)  # 累计旋转矩阵

    # ==================== 第一次平面拟合 ====================
    print("=" * 50)
    print("第一次平面拟合...")
    points, R1, normal1, angle1 = _fit_and_rotate_plane(points, dist_threshold)
    R_total = R1 @ R_total
    print(f"第一次旋转角度: {angle1:.2f}°")

    # ==================== 第二次平面拟合（进一步修正） ====================
    if two_pass:
        print("=" * 50)
        print("第二次平面拟合...")
        points, R2, normal2, angle2 = _fit_and_rotate_plane(points, dist_threshold)
        R_total = R2 @ R_total  # 累计旋转
        print(f"第二次旋转角度: {angle2:.2f}°")

    # ==================== 计算地面高度并调整 ====================
    # 使用底部点云计算地面高度
    z_low = np.percentile(points[:, 2], 5)
    z_high = np.percentile(points[:, 2], 15)
    mask = (points[:, 2] > z_low) & (points[:, 2] < z_high)
    ground_points = points[mask]
    ground_z = np.median(ground_points[:, 2])

    # 调整到目标高度
    z_shift = target_ground_z - ground_z
    points[:, 2] += z_shift

    print("=" * 50)
    print(f"原始地面高度: {ground_z:.3f}m")
    print(f"Z轴平移量: {z_shift:.3f}m")
    print(f"目标地面高度: {target_ground_z:.3f}m")

    # ==================== 统计信息 ====================
    z_min = np.min(points[:, 2])
    z_max = np.max(points[:, 2])
    z_mean = np.mean(points[:, 2])
    z_median = np.median(points[:, 2])

    print("=" * 50)
    print("处理后Z轴统计:")
    print(f"  最小值: {z_min:.3f}m")
    print(f"  最大值: {z_max:.3f}m")
    print(f"  均值: {z_mean:.3f}m")
    print(f"  中位数: {z_median:.3f}m")
    print(f"  地面高度: {target_ground_z:.3f}m")

    # ==================== 保存点云 ====================
    pcd_out = o3d.geometry.PointCloud()
    pcd_out.points = o3d.utility.Vector3dVector(points)
    o3d.io.write_point_cloud(output_pcd_path, pcd_out)
    print(f"\n点云已保存: {output_pcd_path}")
    print(f"原始点数: {len(original_points)}, 输出点数: {len(points)}")

    # ==================== 返回变换参数 ====================
    transform_params = {
        'R': R_total.tolist(),           # 累计旋转矩阵
        'z_shift': float(z_shift),       # Z轴平移量
        'ground_z_original': float(ground_z),  # 原始地面高度
        'target_ground_z': float(target_ground_z),  # 目标地面高度
        'normal_original': normal1.tolist() if 'normal1' in dir() else None
    }

    return transform_params


def _fit_and_rotate_plane(points, dist_threshold):
    """
    单次平面拟合和旋转

    返回:
        points_rotated: 旋转后的点云
        R: 旋转矩阵
        normal: 原始法向量
        angle_deg: 旋转角度（度）
    """
    # 直通滤波：截取底部区域作为地面候选
    z_low = np.percentile(points[:, 2], 5)
    z_high = np.percentile(points[:, 2], 30)
    mask = (points[:, 2] > z_low) & (points[:, 2] < z_high)
    candidate = points[mask]

    # RANSAC拟合平面
    pcd_candidate = o3d.geometry.PointCloud()
    pcd_candidate.points = o3d.utility.Vector3dVector(candidate)
    plane_model, inliers = pcd_candidate.segment_plane(
        distance_threshold=dist_threshold,
        ransac_n=3,
        num_iterations=1000
    )
    a, b, c, d = plane_model

    # 法向量归一化，保证朝上
    normal = np.array([a, b, c])
    if normal[2] < 0:
        normal = -normal
    normal = normal / np.linalg.norm(normal)

    # Rodrigues旋转：将法向量对齐到z轴
    z_axis = np.array([0.0, 0.0, 1.0])
    v = np.cross(normal, z_axis)
    s = np.linalg.norm(v)
    c_val = np.dot(normal, z_axis)

    if s < 1e-8:
        R = np.eye(3)
        angle_deg = 0.0
    else:
        vx = np.array([[0, -v[2], v[1]],
                       [v[2], 0, -v[0]],
                       [-v[1], v[0], 0]])
        R = np.eye(3) + vx + vx @ vx * (1 - c_val) / (s * s)
        angle_deg = np.degrees(np.arccos(np.clip(c_val, -1, 1)))

    # 旋转点云
    points_rotated = points @ R.T

    print(f"地面法向量: [{normal[0]:.4f}, {normal[1]:.4f}, {normal[2]:.4f}]")
    print(f"内点数量: {len(inliers)}")

    return points_rotated, R, normal, angle_deg


def transform_pose(pose, transform_params):
    """
    将重定位得到的位姿变换到水平点云坐标系

    参数:
        pose: [x, y, z, qx, qy, qz, qw] 或 [x, y, z]
        transform_params: level_pointcloud_pro返回的变换参数

    返回:
        变换后的位姿
    """
    R = np.array(transform_params['R'])
    z_shift = transform_params['z_shift']

    # 位置变换
    pos = np.array(pose[:3])
    pos_transformed = pos @ R.T
    pos_transformed[2] += z_shift

    if len(pose) == 7:
        # 姿态变换（四元数）
        from scipy.spatial.transform import Rotation
        q_orig = np.array([pose[3], pose[4], pose[5], pose[6]])  # [qx, qy, qz, qw]
        rot_orig = Rotation.from_quat(q_orig)
        rot_R = Rotation.from_matrix(R)
        rot_new = rot_R * rot_orig
        q_new = rot_new.as_quat()
        return list(pos_transformed) + list(q_new)
    else:
        return list(pos_transformed)


def transform_poses_file(input_json_path, output_json_path, transform_params):
    """
    批量变换JSON文件中的位姿

    参数:
        input_json_path: 输入JSON文件路径
        output_json_path: 输出JSON文件路径
        transform_params: 变换参数
    """
    with open(input_json_path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    # 递归处理所有数值列表（假设为位姿）
    def process_value(value):
        if isinstance(value, list):
            if len(value) == 7 and all(isinstance(v, (int, float)) for v in value):
                # 7个数值，认为是位姿 [x,y,z,qx,qy,qz,qw]
                return transform_pose(value, transform_params)
            elif len(value) == 3 and all(isinstance(v, (int, float)) for v in value):
                # 3个数值，认为是位置 [x,y,z]
                return transform_pose(value, transform_params)
            else:
                return [process_value(v) for v in value]
        return value

    data_transformed = process_value(data)

    with open(output_json_path, 'w', encoding='utf-8') as f:
        json.dump(data_transformed, f, indent=4, ensure_ascii=False)

    print(f"位姿已变换并保存: {output_json_path}")


def save_transform_params(params, output_path):
    """保存变换参数到JSON文件"""
    with open(output_path, 'w', encoding='utf-8') as f:
        json.dump(params, f, indent=4)
    print(f"变换参数已保存: {output_path}")


def load_transform_params(input_path):
    """从JSON文件加载变换参数"""
    with open(input_path, 'r', encoding='utf-8') as f:
        return json.load(f)


def main():
    # 示例用法
    input_pcd = "company_002.pcd"
    output_pcd = "company_002_level_pro.pcd"

    # 处理点云
    params = level_pointcloud_pro(
        input_pcd,
        output_pcd,
        dist_threshold=0.05,
        target_ground_z=0.3,  # 雷达相对地面高度
        two_pass=True
    )

    if params:
        # 保存变换参数
        save_transform_params(params, "transform_params.json")

        # 示例：变换单个位姿
        test_pose = [-17.7588, 10.3494, -2.43888, 0.0862007, 0.0882605, -0.650751, 0.749201]
        transformed = transform_pose(test_pose, params)
        print(f"\n原始位姿: {test_pose}")
        print(f"变换后位姿: {transformed}")


if __name__ == "__main__":
    main()
