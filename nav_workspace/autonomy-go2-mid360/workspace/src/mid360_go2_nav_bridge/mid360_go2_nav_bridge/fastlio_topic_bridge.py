#!/usr/bin/env python3
import copy

from geometry_msgs.msg import TransformStamped
import rclpy
from rclpy.executors import ExternalShutdownException
from nav_msgs.msg import Odometry
from rclpy.node import Node
from sensor_msgs.msg import PointCloud2
from tf2_ros import TransformBroadcaster


class FastlioTopicBridge(Node):
    def __init__(self):
        super().__init__("fastlio_topic_bridge")

        self.declare_parameter("input_odom_topic", "/Odometry_loc")
        self.declare_parameter("output_odom_topic", "/state_estimation")
        self.declare_parameter("input_cloud_topic", "/cloud_registered_1")
        self.declare_parameter("output_cloud_topic", "/registered_scan")
        self.declare_parameter("odom_frame_id", "camera_init")
        self.declare_parameter("odom_child_frame_id", "aft_mapped")
        self.declare_parameter("cloud_frame_id", "camera_init")
        self.declare_parameter("override_frame_ids", True)
        self.declare_parameter("publish_cloud", True)
        self.declare_parameter("odom_pose_offset_to_sensor", False)
        self.declare_parameter("odom_pose_offset_x", 0.0)
        self.declare_parameter("odom_pose_offset_y", 0.0)
        self.declare_parameter("odom_pose_offset_z", 0.0)
        # This FAST-LIO build publishes camera_init -> body as TF, while the
        # autonomy stack expects camera_init -> aft_mapped. Republish the
        # odometry message as that TF edge to close:
        # map -> camera_init -> aft_mapped -> sensor -> vehicle.
        self.declare_parameter("publish_odom_tf", True)

        self.override_frame_ids = self.get_parameter("override_frame_ids").value
        self.odom_pose_offset_to_sensor = self.get_parameter(
            "odom_pose_offset_to_sensor"
        ).value
        self.odom_pose_offset = (
            self.get_parameter("odom_pose_offset_x").value,
            self.get_parameter("odom_pose_offset_y").value,
            self.get_parameter("odom_pose_offset_z").value,
        )
        self.publish_odom_tf = self.get_parameter("publish_odom_tf").value
        self.publish_cloud = self.get_parameter("publish_cloud").value
        self.odom_frame_id = self.get_parameter("odom_frame_id").value
        self.odom_child_frame_id = self.get_parameter("odom_child_frame_id").value
        self.cloud_frame_id = self.get_parameter("cloud_frame_id").value

        input_odom_topic = self.get_parameter("input_odom_topic").value
        output_odom_topic = self.get_parameter("output_odom_topic").value
        input_cloud_topic = self.get_parameter("input_cloud_topic").value
        output_cloud_topic = self.get_parameter("output_cloud_topic").value

        self.odom_pub = self.create_publisher(Odometry, output_odom_topic, 20)
        self.cloud_pub = None
        if self.publish_cloud:
            self.cloud_pub = self.create_publisher(PointCloud2, output_cloud_topic, 10)
        self.tf_broadcaster = TransformBroadcaster(self)

        self.create_subscription(Odometry, input_odom_topic, self.odom_callback, 20)
        if self.publish_cloud:
            self.create_subscription(PointCloud2, input_cloud_topic, self.cloud_callback, 10)

        self.get_logger().info(
            f"Bridging odometry {input_odom_topic} -> {output_odom_topic}"
        )
        if self.publish_cloud:
            self.get_logger().info(
                f"Bridging cloud {input_cloud_topic} -> {output_cloud_topic}"
            )
        else:
            self.get_logger().info("Cloud bridge disabled; odometry bridge only")

    def odom_callback(self, msg):
        out = copy.deepcopy(msg)
        if self.override_frame_ids:
            out.header.frame_id = self.odom_frame_id
            out.child_frame_id = self.odom_child_frame_id
        if self.odom_pose_offset_to_sensor:
            apply_pose_offset(out, self.odom_pose_offset)
        self.odom_pub.publish(out)
        if self.publish_odom_tf:
            transform = copy.deepcopy(out)
            transform_tf = transform_to_stamped(transform)
            self.tf_broadcaster.sendTransform(transform_tf)

    def cloud_callback(self, msg):
        if self.cloud_pub is None:
            return
        out = copy.deepcopy(msg)
        if self.override_frame_ids:
            out.header.frame_id = self.cloud_frame_id
        self.cloud_pub.publish(out)


def transform_to_stamped(odom):
    pose = odom.pose.pose
    msg = TransformStamped()
    msg.header = odom.header
    msg.child_frame_id = odom.child_frame_id
    msg.transform.translation.x = pose.position.x
    msg.transform.translation.y = pose.position.y
    msg.transform.translation.z = pose.position.z
    msg.transform.rotation = pose.orientation
    return msg


def apply_pose_offset(odom, offset):
    pose = odom.pose.pose
    dx, dy, dz = rotate_vector_by_quaternion(offset, pose.orientation)
    pose.position.x += dx
    pose.position.y += dy
    pose.position.z += dz


def rotate_vector_by_quaternion(vector, quaternion):
    # q * v * q^-1, expanded to avoid adding a dependency for one operation.
    x, y, z = vector
    qx = quaternion.x
    qy = quaternion.y
    qz = quaternion.z
    qw = quaternion.w

    tx = 2.0 * (qy * z - qz * y)
    ty = 2.0 * (qz * x - qx * z)
    tz = 2.0 * (qx * y - qy * x)

    return (
        x + qw * tx + qy * tz - qz * ty,
        y + qw * ty + qz * tx - qx * tz,
        z + qw * tz + qx * ty - qy * tx,
    )


def main(args=None):
    rclpy.init(args=args)
    node = FastlioTopicBridge()
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
