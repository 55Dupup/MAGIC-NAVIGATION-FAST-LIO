import numpy as np
import open3d as o3d

def level_pointcloud(input_pcd_path, output_pcd_path,
                    dist_threshold=0.05, 
                    z_offset=0.0):
    """
    自动检测地面平面，旋转点云使地面水平，地面落在 z=0
    """
    pcd = o3d.io.read_point_cloud(input_pcd_path)
    points = np.asarray(pcd.points)

    if len(points) < 100:
        print("点太少")
        return

    # 1. 直通滤波：先截取大致底部区域（地面候选区）
    z_low = np.percentile(points[:, 2], 5)
    z_high = np.percentile(points[:, 2], 30)
    mask = (points[:, 2] > z_low) & (points[:, 2] < z_high)
    candidate = points[mask]

    # 2. RANSAC 拟合平面: ax + by + cz + d = 0
    pcd_candidate = o3d.geometry.PointCloud()
    pcd_candidate.points = o3d.utility.Vector3dVector(candidate)
    plane_model, inliers = pcd_candidate.segment_plane(
        distance_threshold=dist_threshold,
        ransac_n=3,
        num_iterations=1000
    )
    a, b, c, d = plane_model  # 平面方程系数

    # 3. 保证法向量朝上 (地面法向量指向 +z)
    normal = np.array([a, b, c])
    if normal[2] < 0:
        normal = -normal
    normal = normal / np.linalg.norm(normal)

    # 4. 计算旋转：把 normal 对齐到 [0, 0, 1]
    z_axis = np.array([0.0, 0.0, 1.0])
    v = np.cross(normal, z_axis)
    s = np.linalg.norm(v)
    c_val = np.dot(normal, z_axis)

    if s < 1e-8:
        R = np.eye(3)  # 已经水平
    else:
        vx = np.array([[0, -v[2], v[1]],
                        [v[2], 0, -v[0]],
                        [-v[1], v[0], 0]])
        R = np.eye(3) + vx + vx @ vx * (1 - c_val) / (s * s)

    # 5. 旋转所有点
    points_level = points @ R.T

    # 6. 地面归零：新的地面高度应该在 z = -d (经过旋转后的 d)
    # 取拟合的内点，旋转后计算新高度
    inlier_points = candidate[inliers]
    inlier_level = inlier_points @ R.T
    ground_z = np.median(inlier_level[:, 2])
    points_level[:, 2] -= ground_z - z_offset

    # 7. 去除明显在地面以下的离群点（放宽阈值，或注释掉此行不过滤）
    # points_level = points_level[points_level[:, 2] > -0.5]

    # 8. 写入文件
    pcd_out = o3d.geometry.PointCloud()
    pcd_out.points = o3d.utility.Vector3dVector(points_level)
    o3d.io.write_point_cloud(output_pcd_path, pcd_out)

    # 打印信息
    angle_deg = np.degrees(np.arccos(c_val))
    print(f"地面法向量: {normal}")
    print(f"倾斜角度: {angle_deg:.2f}°")
    print(f"旋转矩阵:\n{R}")
    print(f"原始点数: {len(points)}, 输出点数: {len(points_level)}")

def main():
    level_pointcloud("test_000.pcd", "test_001_level.pcd", z_offset=0.0)

if __name__ == "__main__":
    main()
