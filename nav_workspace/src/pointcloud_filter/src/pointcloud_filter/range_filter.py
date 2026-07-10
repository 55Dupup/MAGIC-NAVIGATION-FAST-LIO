#!/usr/bin/env python3
"""
Point Cloud Range Filter Node
订阅原始点云，过滤超过指定距离的点，发布过滤后的点云
"""

import rclpy
from rclpy.node import Node
from sensor_msgs.msg import PointCloud2
import sensor_msgs_py.point_cloud2 as pc2
from std_msgs.msg import Header
import numpy as np


class RangeFilterNode(Node):
    def __init__(self):
        super().__init__('range_filter_node')

        # 声明参数
        self.declare_parameter('input_topic', '/unitree/slam_lidar/points')
        self.declare_parameter('output_topic', '/unitree/slam_lidar/points_filtered')
        self.declare_parameter('max_range', 10.0)  # 最大距离 (米)
        self.declare_parameter('min_range', 0.3)   # 最小距离 (米) - 盲区
        self.declare_parameter('filter_z_min', -2.0)  # Z轴最小值
        self.declare_parameter('filter_z_max', 2.0)   # Z轴最大值

        # 获取参数
        self.input_topic = self.get_parameter('input_topic').value
        self.output_topic = self.get_parameter('output_topic').value
        self.max_range = self.get_parameter('max_range').value
        self.min_range = self.get_parameter('min_range').value
        self.filter_z_min = self.get_parameter('filter_z_min').value
        self.filter_z_max = self.get_parameter('filter_z_max').value

        self.get_logger().info(f'Range Filter Node initialized:')
        self.get_logger().info(f'  Input topic: {self.input_topic}')
        self.get_logger().info(f'  Output topic: {self.output_topic}')
        self.get_logger().info(f'  Max range: {self.max_range} m')
        self.get_logger().info(f'  Min range: {self.min_range} m')
        self.get_logger().info(f'  Z range: [{self.filter_z_min}, {self.filter_z_max}] m')

        # 创建订阅者
        self.subscription = self.create_subscription(
            PointCloud2,
            self.input_topic,
            self.pointcloud_callback,
            10
        )

        # 创建发布者
        self.publisher = self.create_publisher(
            PointCloud2,
            self.output_topic,
            10
        )

        # 统计信息
        self.total_points_in = 0
        self.total_points_out = 0
        self.frame_count = 0

    def pointcloud_callback(self, msg: PointCloud2):
        """处理点云回调"""
        # 读取点云数据
        points = list(pc2.read_points(msg, field_names=("x", "y", "z"), skip_nans=True))

        original_count = len(points)
        self.total_points_in += original_count

        # 过滤点云
        filtered_points = []
        max_range_sq = self.max_range ** 2
        min_range_sq = self.min_range ** 2

        for point in points:
            x, y, z = point

            # 计算距离平方
            dist_sq = x * x + y * y + z * z

            # 距离过滤
            if dist_sq < min_range_sq or dist_sq > max_range_sq:
                continue

            # Z轴过滤
            if z < self.filter_z_min or z > self.filter_z_max:
                continue

            filtered_points.append([x, y, z])

        filtered_count = len(filtered_points)
        self.total_points_out += filtered_count
        self.frame_count += 1

        # 创建过滤后的点云消息
        header = Header()
        header.stamp = msg.header.stamp
        header.frame_id = msg.header.frame_id

        filtered_msg = pc2.create_cloud_xyz32(header, filtered_points)

        # 发布过滤后的点云
        self.publisher.publish(filtered_msg)

        # 每100帧打印一次统计信息
        if self.frame_count % 100 == 0:
            avg_filter_ratio = self.total_points_out / self.total_points_in * 100 if self.total_points_in > 0 else 0
            self.get_logger().info(
                f'Frame {self.frame_count}: {original_count} -> {filtered_count} points '
                f'({filtered_count/original_count*100:.1f}% kept), '
                f'Avg filter ratio: {avg_filter_ratio:.1f}%'
            )


def main(args=None):
    rclpy.init(args=args)
    node = RangeFilterNode()

    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.get_logger().info(
            f'Shutting down. Total: {node.total_points_in} -> {node.total_points_out} points'
        )
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
