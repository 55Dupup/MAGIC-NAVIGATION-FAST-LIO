#!/usr/bin/env python3
import copy
import math

from geometry_msgs.msg import PointStamped, PoseWithCovarianceStamped
import rclpy
from nav_msgs.msg import Odometry
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node
from tf2_ros import Buffer, TransformException, TransformListener


class GlobalNavFrameBridge(Node):
    def __init__(self):
        super().__init__("global_nav_frame_bridge")

        self.declare_parameter("enable_initialpose_bridge", True)
        self.declare_parameter("enable_waypoint_bridge", True)
        self.declare_parameter("odom_topic", "/Odometry_loc")
        self.declare_parameter("input_initialpose_topic", "/initialpose")
        self.declare_parameter("output_initialpose_topic", "/open3d_initialpose")
        self.declare_parameter("input_waypoint_topic", "/way_point_global")
        self.declare_parameter("output_waypoint_topic", "/way_point")
        self.declare_parameter("target_waypoint_frame", "camera_init")
        self.declare_parameter("auto_initialpose", False)
        self.declare_parameter("auto_initialpose_x", 0.0)
        self.declare_parameter("auto_initialpose_y", 0.0)
        self.declare_parameter("auto_initialpose_z", 0.0)
        self.declare_parameter("auto_initialpose_yaw", 0.0)
        self.declare_parameter("auto_initialpose_publish_count", 3)
        # Open3D global_localization.cpp treats /Odometry_loc as imu_link pose
        # in odom/camera_init, then converts it to base_link with T_base_imu.
        self.declare_parameter("base_to_imu_x", 0.187)
        self.declare_parameter("base_to_imu_y", 0.0)
        self.declare_parameter("base_to_imu_z", 0.0803)

        self.enable_initialpose_bridge = self.get_parameter(
            "enable_initialpose_bridge"
        ).value
        self.enable_waypoint_bridge = self.get_parameter("enable_waypoint_bridge").value
        self.target_waypoint_frame = self.get_parameter("target_waypoint_frame").value
        self.base_to_imu = (
            self.get_parameter("base_to_imu_x").value,
            self.get_parameter("base_to_imu_y").value,
            self.get_parameter("base_to_imu_z").value,
        )
        self.auto_initialpose = self.get_parameter("auto_initialpose").value
        self.auto_initialpose_pose = (
            self.get_parameter("auto_initialpose_x").value,
            self.get_parameter("auto_initialpose_y").value,
            self.get_parameter("auto_initialpose_z").value,
            self.get_parameter("auto_initialpose_yaw").value,
        )
        self.auto_initialpose_publish_count = max(
            1, int(self.get_parameter("auto_initialpose_publish_count").value)
        )
        self.auto_initialpose_published = 0

        self.latest_odom = None
        self.auto_initialpose_timer = None
        self.tf_buffer = Buffer()
        self.tf_listener = TransformListener(self.tf_buffer, self)

        odom_topic = self.get_parameter("odom_topic").value
        self.create_subscription(Odometry, odom_topic, self.odom_callback, 20)

        if self.enable_initialpose_bridge:
            input_initialpose_topic = self.get_parameter("input_initialpose_topic").value
            output_initialpose_topic = self.get_parameter("output_initialpose_topic").value
            self.initialpose_pub = self.create_publisher(
                PoseWithCovarianceStamped, output_initialpose_topic, 5
            )
            self.create_subscription(
                PoseWithCovarianceStamped,
                input_initialpose_topic,
                self.initialpose_callback,
                5,
            )
            self.get_logger().info(
                "Bridging RViz robot initialpose to Open3D map->odom "
                f"{input_initialpose_topic} -> {output_initialpose_topic}"
            )
            if self.auto_initialpose:
                self.auto_initialpose_timer = self.create_timer(
                    1.0, self.auto_initialpose_callback
                )
                x, y, z, yaw = self.auto_initialpose_pose
                self.get_logger().info(
                    "Auto initialpose enabled: "
                    f"map->base_link x={x:.3f}, y={y:.3f}, z={z:.3f}, "
                    f"yaw={yaw:.3f} rad"
                )

        if self.enable_waypoint_bridge:
            input_waypoint_topic = self.get_parameter("input_waypoint_topic").value
            output_waypoint_topic = self.get_parameter("output_waypoint_topic").value
            self.waypoint_pub = self.create_publisher(
                PointStamped, output_waypoint_topic, 5
            )
            self.create_subscription(
                PointStamped, input_waypoint_topic, self.waypoint_callback, 5
            )
            self.get_logger().info(
                "Bridging global waypoints to local planner "
                f"{input_waypoint_topic} -> {output_waypoint_topic} "
                f"target_frame={self.target_waypoint_frame}"
            )

    def odom_callback(self, msg):
        self.latest_odom = copy.deepcopy(msg)

    def initialpose_callback(self, msg):
        if self.publish_initialpose_to_open3d(msg, "manual"):
            self.auto_initialpose_published = self.auto_initialpose_publish_count

    def auto_initialpose_callback(self):
        if self.auto_initialpose_published >= self.auto_initialpose_publish_count:
            if self.auto_initialpose_timer is not None:
                self.destroy_timer(self.auto_initialpose_timer)
                self.auto_initialpose_timer = None
            return
        if self.latest_odom is None:
            self.get_logger().warn(
                "Waiting for /Odometry_loc before publishing auto initialpose"
            )
            return

        x, y, z, yaw = self.auto_initialpose_pose
        msg = PoseWithCovarianceStamped()
        msg.header.frame_id = "map"
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.pose.pose.position.x = x
        msg.pose.pose.position.y = y
        msg.pose.pose.position.z = z
        (
            msg.pose.pose.orientation.x,
            msg.pose.pose.orientation.y,
            msg.pose.pose.orientation.z,
            msg.pose.pose.orientation.w,
        ) = yaw_to_quaternion(yaw)

        self.publish_initialpose_to_open3d(msg, "auto")
        self.auto_initialpose_published += 1

    def publish_initialpose_to_open3d(self, msg, source):
        if self.latest_odom is None:
            self.get_logger().warn(
                "Ignoring initialpose until the first /Odometry_loc sample arrives"
            )
            return False

        t_map_base = transform_from_pose(msg.pose.pose)
        t_odom_imu = transform_from_pose(self.latest_odom.pose.pose)
        t_base_imu = (self.base_to_imu, (0.0, 0.0, 0.0, 1.0))
        t_odom_base = compose_transform(t_odom_imu, invert_transform(t_base_imu))
        t_map_odom = compose_transform(t_map_base, invert_transform(t_odom_base))

        out = copy.deepcopy(msg)
        out.header.frame_id = "map"
        set_pose_from_transform(out.pose.pose, t_map_odom)
        self.initialpose_pub.publish(out)
        self.get_logger().info(
            f"Converted {source} robot initialpose map->base_link "
            "into Open3D map->odom"
        )
        return True

    def waypoint_callback(self, msg):
        source_frame = msg.header.frame_id or "map"
        try:
            transform = self.tf_buffer.lookup_transform(
                self.target_waypoint_frame,
                source_frame,
                rclpy.time.Time(),
                timeout=rclpy.duration.Duration(seconds=0.5),
            )
        except TransformException as exc:
            self.get_logger().warn(
                f"Cannot transform waypoint {source_frame} -> "
                f"{self.target_waypoint_frame}: {exc}"
            )
            return

        out = copy.deepcopy(msg)
        out.header.frame_id = self.target_waypoint_frame
        out.point.x, out.point.y, out.point.z = apply_transform_to_point(
            transform_to_tuple(transform.transform),
            (msg.point.x, msg.point.y, msg.point.z),
        )
        self.waypoint_pub.publish(out)


def transform_from_pose(pose):
    return (
        (pose.position.x, pose.position.y, pose.position.z),
        normalize_quaternion(
            (
                pose.orientation.x,
                pose.orientation.y,
                pose.orientation.z,
                pose.orientation.w,
            )
        ),
    )


def transform_to_tuple(transform):
    return (
        (
            transform.translation.x,
            transform.translation.y,
            transform.translation.z,
        ),
        normalize_quaternion(
            (
                transform.rotation.x,
                transform.rotation.y,
                transform.rotation.z,
                transform.rotation.w,
            )
        ),
    )


def set_pose_from_transform(pose, transform):
    translation, rotation = transform
    pose.position.x, pose.position.y, pose.position.z = translation
    pose.orientation.x, pose.orientation.y, pose.orientation.z, pose.orientation.w = rotation


def compose_transform(first, second):
    first_t, first_q = first
    second_t, second_q = second
    rotated_second_t = rotate_vector_by_quaternion(second_t, first_q)
    return (
        (
            first_t[0] + rotated_second_t[0],
            first_t[1] + rotated_second_t[1],
            first_t[2] + rotated_second_t[2],
        ),
        normalize_quaternion(quaternion_multiply(first_q, second_q)),
    )


def invert_transform(transform):
    translation, rotation = transform
    inv_rotation = quaternion_inverse(rotation)
    inv_translation = rotate_vector_by_quaternion(
        (-translation[0], -translation[1], -translation[2]), inv_rotation
    )
    return inv_translation, inv_rotation


def apply_transform_to_point(transform, point):
    translation, rotation = transform
    rotated = rotate_vector_by_quaternion(point, rotation)
    return (
        translation[0] + rotated[0],
        translation[1] + rotated[1],
        translation[2] + rotated[2],
    )


def normalize_quaternion(q):
    x, y, z, w = q
    norm = math.sqrt(x * x + y * y + z * z + w * w)
    if norm == 0.0:
        return 0.0, 0.0, 0.0, 1.0
    return x / norm, y / norm, z / norm, w / norm


def yaw_to_quaternion(yaw):
    half_yaw = yaw * 0.5
    return 0.0, 0.0, math.sin(half_yaw), math.cos(half_yaw)


def quaternion_inverse(q):
    x, y, z, w = normalize_quaternion(q)
    return -x, -y, -z, w


def quaternion_multiply(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    )


def rotate_vector_by_quaternion(vector, quaternion):
    x, y, z = vector
    qx, qy, qz, qw = normalize_quaternion(quaternion)

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
    node = GlobalNavFrameBridge()
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
