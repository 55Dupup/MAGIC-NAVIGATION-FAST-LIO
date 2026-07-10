from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription
from launch.conditions import IfCondition, UnlessCondition
from launch.launch_description_sources import AnyLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution
from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterValue
from launch_ros.substitutions import FindPackageShare


FOXGLOVE_TOPIC_WHITELIST = [
    r"/tf",
    r"/tf_static",
    r"/clicked_point",
    r"/initialpose",
    r"/open3d_initialpose",
    r"/move_base_simple/goal",
    r"/foxglove_posestamped",
    r"/unitree/slam_lidar/points",
    r"/unitree/slam_lidar/imu",
    r"/Laser_map_1",
    r"/Odometry_loc",
    r"/cloud_registered_1",
    r"/cloud_registered_body_1",
    r"/cloud_effected_1",
    r"/path_1",
    r"/map",
    r"/submap",
    r"/scan",
    r"/scan2map",
    r"/localization_3d",
    r"/localization_3d_confidence",
    r"/localization_3d_delay_ms",
    r"/baselink2map",
    r"/baselink2map_kalman",
    r"/odom2map",
    r"/odom2map_kalman",
    r"/motionlink2map",
    r"/registered_scan",
    r"/state_estimation",
    r"/terrain_map",
    r"/terrain_map_ext",
    r"/terrain_map_ext.*",
    r"/navigation_boundary",
    r"/navigation_boundary_viz",
    r"/goal_point",
    r"/way_point",
    r"/way_point_global",
    r"/far_reach_goal_status",
    r"/far_traverse_time",
    r"/runtime",
    r"/planning_time",
    r"/cmd_vel",
    r"/path",
    r"/free_paths",
    r"/robot_vgraph",
    r"/decoded_vgraph",
    r"/graph_decoder_viz",
    r"/viz_.*",
    r"/FAR_.*",
    r"/utlidar/cloud_deskewed",
    r"/utlidar/grid_map",
    r"/utlidar/height_map",
    r"/utlidar/range_map",
    r"/utlidar/robot_pose",
    r"/uslam/cloud_map",
    r"/uslam/frontend/cloud_world_ds",
    r"/uslam/frontend/odom",
    r"/uslam/localization/cloud_world",
    r"/uslam/localization/odom",
    r"/uslam/navigation/global_path",
]


def generate_launch_description():
    sensor_offset_x = LaunchConfiguration("sensor_offset_x")
    sensor_offset_y = LaunchConfiguration("sensor_offset_y")
    camera_offset_z = LaunchConfiguration("camera_offset_z")
    max_speed = LaunchConfiguration("max_speed")
    max_yaw_rate = LaunchConfiguration("max_yaw_rate")
    real_robot = LaunchConfiguration("real_robot")
    route_planner = LaunchConfiguration("route_planner")
    global_localization = LaunchConfiguration("global_localization")
    map_file = LaunchConfiguration("map_file")
    base_to_imu_z = LaunchConfiguration("base_to_imu_z")
    auto_initialpose = LaunchConfiguration("auto_initialpose")
    initialpose_x = LaunchConfiguration("initialpose_x")
    initialpose_y = LaunchConfiguration("initialpose_y")
    initialpose_z = LaunchConfiguration("initialpose_z")
    initialpose_yaw = LaunchConfiguration("initialpose_yaw")
    terrain_ext = LaunchConfiguration("terrain_ext")
    rviz = LaunchConfiguration("rviz")
    foxglove = LaunchConfiguration("foxglove")
    autonomy_mode = LaunchConfiguration("autonomy_mode")
    auto_disarm_on_goal = LaunchConfiguration("auto_disarm_on_goal")
    auto_disarm_stop_count = LaunchConfiguration("auto_disarm_stop_count")

    bridge = Node(
        package="mid360_go2_nav_bridge",
        executable="fastlio_topic_bridge",
        name="fastlio_topic_bridge",
        output="screen",
        parameters=[
            {
                "input_odom_topic": "/Odometry_loc",
                "output_odom_topic": "/state_estimation",
                "input_cloud_topic": "/cloud_registered_1",
                "output_cloud_topic": "/registered_scan",
                "odom_frame_id": "camera_init",
                "odom_child_frame_id": "aft_mapped",
                "cloud_frame_id": "camera_init",
                "override_frame_ids": True,
                # Keep the default planner input on the original lightweight
                # chain. Dense local scan experiments were too CPU-heavy on
                # Go2 and could starve FAST-LIO.
                "publish_cloud": True,
                # FAST-LIO /Odometry_loc follows the LiDAR IMU/body state.
                # autonomy_stack_go2 expects /state_estimation at the sensor
                # frame, then localPlanner/pathFollower subtract
                # sensorOffsetX/Y to recover the vehicle/base position.
                # Do not add the base->sensor offset here, or the vehicle pose
                # will be shifted forward by that offset.
                "odom_pose_offset_to_sensor": False,
                "odom_pose_offset_x": 0.0,
                "odom_pose_offset_y": 0.0,
                # Keep Z unchanged because upstream localPlanner has no
                # sensorOffsetZ and uses odometry z directly for terrain gates.
                "odom_pose_offset_z": 0.0,
                "publish_odom_tf": True,
            }
        ],
    )

    global_nav_frame_bridge = Node(
        package="mid360_go2_nav_bridge",
        executable="global_nav_frame_bridge",
        name="global_nav_frame_bridge",
        output="screen",
        parameters=[
            {
                "enable_initialpose_bridge": ParameterValue(
                    global_localization, value_type=bool
                ),
                "enable_waypoint_bridge": ParameterValue(route_planner, value_type=bool),
                "odom_topic": "/Odometry_loc",
                "input_initialpose_topic": "/initialpose",
                "output_initialpose_topic": "/open3d_initialpose",
                "input_waypoint_topic": "/way_point_global",
                "output_waypoint_topic": "/way_point",
                "target_waypoint_frame": "camera_init",
                "auto_initialpose": ParameterValue(
                    auto_initialpose, value_type=bool
                ),
                "auto_initialpose_x": initialpose_x,
                "auto_initialpose_y": initialpose_y,
                "auto_initialpose_z": initialpose_z,
                "auto_initialpose_yaw": initialpose_yaw,
                "base_to_imu_x": sensor_offset_x,
                "base_to_imu_y": sensor_offset_y,
                "base_to_imu_z": base_to_imu_z,
            }
        ],
    )

    local_planner = IncludeLaunchDescription(
        AnyLaunchDescriptionSource(
            PathJoinSubstitution(
                [
                    FindPackageShare("local_planner"),
                    "launch",
                    "local_planner.launch",
                ]
            )
        ),
        launch_arguments={
            "sensorOffsetX": sensor_offset_x,
            "sensorOffsetY": sensor_offset_y,
            "cameraOffsetZ": camera_offset_z,
            "maxSpeed": max_speed,
            "maxYawRate": max_yaw_rate,
            "is_real_robot": real_robot,
            "autonomyMode": autonomy_mode,
            "autoDisarmOnGoal": auto_disarm_on_goal,
            "autoDisarmStopPublishCount": auto_disarm_stop_count,
        }.items(),
    )

    terrain_analysis = IncludeLaunchDescription(
        AnyLaunchDescriptionSource(
            PathJoinSubstitution(
                [
                    FindPackageShare("terrain_analysis"),
                    "launch",
                    "terrain_analysis.launch",
                ]
            )
        )
    )

    terrain_analysis_ext = IncludeLaunchDescription(
        AnyLaunchDescriptionSource(
            PathJoinSubstitution(
                [
                    FindPackageShare("terrain_analysis_ext"),
                    "launch",
                    "terrain_analysis_ext.launch",
                ]
            )
        ),
        condition=IfCondition(terrain_ext),
    )

    open3d_global_localization = Node(
        package="open3d_loc",
        executable="global_localization_node",
        name="global_loc_node",
        output="screen",
        parameters=[
            "/workspace/nav_ws/src/fast/open3d_loc/config/loc_param_go2.yaml",
            {
                "path_map": map_file,
            },
        ],
        remappings=[
            # Open3D's callback treats /initialpose as map->odom, while RViz
            # publishes robot pose in map. The frame bridge converts it first.
            ("/initialpose", "/open3d_initialpose"),
        ],
        condition=IfCondition(global_localization),
    )

    far_planner = Node(
        package="far_planner",
        executable="far_planner",
        name="far_planner",
        output="screen",
        parameters=[
            PathJoinSubstitution(
                [
                    FindPackageShare("far_planner"),
                    "config",
                    "default.yaml",
                ]
            )
        ],
        remappings=[
            ("/odom_world", "/state_estimation"),
            ("/terrain_cloud", "/terrain_map_ext"),
            ("/scan_cloud", "/terrain_map"),
            ("/terrain_local_cloud", "/registered_scan"),
            # Keep localPlanner in camera_init. The frame bridge transforms
            # FAR's map-frame waypoint into /way_point in camera_init.
            ("/way_point", "/way_point_global"),
        ],
        condition=IfCondition(route_planner),
    )

    graph_decoder = IncludeLaunchDescription(
        AnyLaunchDescriptionSource(
            PathJoinSubstitution(
                [
                    FindPackageShare("graph_decoder"),
                    "launch",
                    "decoder.launch",
                ]
            )
        ),
        condition=IfCondition(route_planner),
    )

    rviz_node = Node(
        package="rviz2",
        executable="rviz2",
        name="rvizGA",
        arguments=[
            "-d",
            PathJoinSubstitution(
                [
                    FindPackageShare("vehicle_simulator"),
                    "rviz",
                    "vehicle_simulator.rviz",
                ]
            ),
        ],
        condition=IfCondition(rviz),
        output="screen",
    )

    foxglove_bridge = Node(
        package="foxglove_bridge",
        executable="foxglove_bridge",
        name="foxglove_bridge",
        output="screen",
        parameters=[
            {
                "port": 9001,
                "address": "0.0.0.0",
                "topic_whitelist": FOXGLOVE_TOPIC_WHITELIST,
                "client_topic_whitelist": [
                    r"/clicked_point",
                    r"/initialpose",
                    r"/move_base_simple/goal",
                    r"/goal_point",
                ],
                "param_whitelist": [r"^$"],
                "service_whitelist": [r"^$"],
                "capabilities": ["clientPublish", "connectionGraph"],
                "ignore_unresponsive_param_nodes": True,
                "max_qos_depth": 25,
                "send_buffer_limit": 100000000,
                "use_compression": True,
            }
        ],
        condition=IfCondition(foxglove),
    )

    map_to_camera_init = Node(
        package="tf2_ros",
        executable="static_transform_publisher",
        name="loamInterfaceTransPubMap",
        arguments=["0", "0", "0", "0", "0", "0", "/map", "/camera_init"],
        condition=UnlessCondition(global_localization),
    )

    odom_to_camera_init = Node(
        package="tf2_ros",
        executable="static_transform_publisher",
        name="odomToCameraInit",
        arguments=["0", "0", "0", "0", "0", "0", "1", "odom", "camera_init"],
        condition=IfCondition(global_localization),
    )

    base_to_imu = Node(
        package="tf2_ros",
        executable="static_transform_publisher",
        name="baseToImu",
        arguments=[
            sensor_offset_x,
            sensor_offset_y,
            base_to_imu_z,
            "0",
            "0",
            "0",
            "1",
            "base_link",
            "imu_link",
        ],
        condition=IfCondition(global_localization),
    )

    base_to_motion = Node(
        package="tf2_ros",
        executable="static_transform_publisher",
        name="baseToMotion",
        arguments=["0", "0", "0", "0", "0", "0", "1", "base_link", "motion_link"],
        condition=IfCondition(global_localization),
    )

    aft_mapped_to_sensor = Node(
        package="tf2_ros",
        executable="static_transform_publisher",
        name="loamInterfaceTransPubVehicle",
        arguments=["0", "0", "0", "0", "0", "0", "/aft_mapped", "/sensor"],
    )

    return LaunchDescription(
        [
            # Upstream autonomy_stack_go2 defaults this to 0.30 for the L1
            # setup. The Go2 MID360 factory relocation config uses
            # pose_imu_lidar tx=0.1870, so use that as the MID360 default.
            DeclareLaunchArgument("sensor_offset_x", default_value="0.187"),
            DeclareLaunchArgument("sensor_offset_y", default_value="0.0"),
            DeclareLaunchArgument("camera_offset_z", default_value="0.0"),
            DeclareLaunchArgument("max_speed", default_value="0.3"),
            DeclareLaunchArgument("max_yaw_rate", default_value="30.0"),
            DeclareLaunchArgument("real_robot", default_value="false"),
            DeclareLaunchArgument("route_planner", default_value="false"),
            DeclareLaunchArgument("global_localization", default_value="false"),
            DeclareLaunchArgument(
                "map_file",
                default_value="/workspace/maps/company_001-test_20260519_195622.pcd",
            ),
            DeclareLaunchArgument("base_to_imu_z", default_value="0.0803"),
            DeclareLaunchArgument("auto_initialpose", default_value="false"),
            DeclareLaunchArgument("initialpose_x", default_value="0.0"),
            DeclareLaunchArgument("initialpose_y", default_value="0.0"),
            DeclareLaunchArgument("initialpose_z", default_value="0.0"),
            DeclareLaunchArgument("initialpose_yaw", default_value="0.0"),
            DeclareLaunchArgument("terrain_ext", default_value="false"),
            DeclareLaunchArgument("rviz", default_value="true"),
            DeclareLaunchArgument("foxglove", default_value="false"),
            DeclareLaunchArgument("autonomy_mode", default_value="true"),
            DeclareLaunchArgument("auto_disarm_on_goal", default_value="false"),
            DeclareLaunchArgument("auto_disarm_stop_count", default_value="20"),
            bridge,
            global_nav_frame_bridge,
            local_planner,
            terrain_analysis,
            terrain_analysis_ext,
            open3d_global_localization,
            far_planner,
            graph_decoder,
            rviz_node,
            foxglove_bridge,
            map_to_camera_init,
            odom_to_camera_init,
            base_to_imu,
            base_to_motion,
            aft_mapped_to_sensor,
        ]
    )
