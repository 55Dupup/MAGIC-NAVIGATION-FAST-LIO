#!/usr/bin/env python3
import copy

import rclpy
from nav_msgs.msg import Odometry
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node
from sensor_msgs.msg import PointCloud2


class Fastlivo2CompatBridge(Node):
    """Expose FAST-LIVO2 output through the current FAST-LIO-compatible API.

    The existing OPERATION_GUIDE backend expects:
      /Odometry_loc
      /cloud_registered_1

    The ROS2 FAST-LIVO2 fork publishes:
      /aft_mapped_to_init
      /cloud_registered

    This bridge intentionally does not alter pose values. It only republishes
    topic names and normalizes frame IDs so Open3D localization and the current
    navigation bridge do not need to know which frontend produced the data.
    """

    def __init__(self):
        super().__init__("fastlivo2_compat_bridge")

        self.declare_parameter("input_odom_topic", "/aft_mapped_to_init")
        self.declare_parameter("output_odom_topic", "/Odometry_loc")
        self.declare_parameter("input_cloud_topic", "/cloud_registered")
        self.declare_parameter("output_cloud_topic", "/cloud_registered_1")
        self.declare_parameter("odom_frame_id", "camera_init")
        self.declare_parameter("odom_child_frame_id", "aft_mapped")
        self.declare_parameter("cloud_frame_id", "camera_init")
        self.declare_parameter("override_frame_ids", True)

        self.override_frame_ids = self.get_parameter("override_frame_ids").value
        self.odom_frame_id = self.get_parameter("odom_frame_id").value
        self.odom_child_frame_id = self.get_parameter("odom_child_frame_id").value
        self.cloud_frame_id = self.get_parameter("cloud_frame_id").value

        input_odom_topic = self.get_parameter("input_odom_topic").value
        output_odom_topic = self.get_parameter("output_odom_topic").value
        input_cloud_topic = self.get_parameter("input_cloud_topic").value
        output_cloud_topic = self.get_parameter("output_cloud_topic").value

        self.odom_pub = self.create_publisher(Odometry, output_odom_topic, 20)
        self.cloud_pub = self.create_publisher(PointCloud2, output_cloud_topic, 10)

        self.create_subscription(Odometry, input_odom_topic, self.odom_callback, 20)
        self.create_subscription(PointCloud2, input_cloud_topic, self.cloud_callback, 10)

        self.get_logger().info(
            f"FAST-LIVO2 odometry compatibility: {input_odom_topic} -> {output_odom_topic}"
        )
        self.get_logger().info(
            f"FAST-LIVO2 cloud compatibility: {input_cloud_topic} -> {output_cloud_topic}"
        )

    def odom_callback(self, msg):
        out = copy.deepcopy(msg)
        if self.override_frame_ids:
            out.header.frame_id = self.odom_frame_id
            out.child_frame_id = self.odom_child_frame_id
        self.odom_pub.publish(out)

    def cloud_callback(self, msg):
        out = copy.deepcopy(msg)
        if self.override_frame_ids:
            out.header.frame_id = self.cloud_frame_id
        self.cloud_pub.publish(out)


def main(args=None):
    rclpy.init(args=args)
    node = Fastlivo2CompatBridge()
    try:
        rclpy.spin(node)
    except (ExternalShutdownException, KeyboardInterrupt):
        pass
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == "__main__":
    main()
