import os.path

from ament_index_python.packages import get_package_share_directory

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution
from launch.conditions import IfCondition

from launch_ros.actions import Node

# Foxglove bridge port
FOXGLOVE_PORT = 9001
FOXGLOVE_TOPIC_WHITELIST = [
    # Core ROS visualization and interaction topics.
    r'/tf',
    r'/tf_static',
    r'/clicked_point',
    r'/initialpose',
    r'/move_base_simple/goal',
    r'/foxglove_posestamped',

    # MID360 raw topics used by FAST-LIO. These are standard ROS messages.
    r'/unitree/slam_lidar/points',
    r'/unitree/slam_lidar/imu',

    # FAST-LIO outputs.
    r'/Laser_map_1',
    r'/Odometry_loc',
    r'/cloud_registered_1',
    r'/cloud_registered_body_1',
    r'/cloud_effected_1',
    r'/path_1',

    # Open3D global localization outputs.
    r'/map',
    r'/submap',
    r'/scan',
    r'/scan2map',
    r'/localization_3d',
    r'/localization_3d_confidence',
    r'/localization_3d_delay_ms',
    r'/baselink2map',
    r'/baselink2map_kalman',
    r'/odom2map',
    r'/odom2map_kalman',
    r'/motionlink2map',

    # Autonomy bridge, terrain, planner, and controller topics.
    r'/registered_scan',
    r'/state_estimation',
    r'/terrain_map',
    r'/terrain_map_ext',
    r'/terrain_map_ext.*',
    r'/navigation_boundary',
    r'/goal_point',
    r'/way_point',
    r'/way_point_global',
    r'/far_reach_goal_status',
    r'/far_traverse_time',
    r'/runtime',
    r'/planning_time',
    r'/cmd_vel',
    r'/path',
    r'/free_paths',
    r'/robot_vgraph',
    r'/decoded_vgraph',
    r'/graph_decoder_viz',
    r'/viz_.*',
    r'/FAR_.*',

    # Known Unitree standard-message debug topics. Keep custom /api, /utlidar
    # compressed/status, and config topics out because they can break
    # foxglove_bridge graph polling with unsupported schemas.
    r'/utlidar/cloud_deskewed',
    r'/utlidar/grid_map',
    r'/utlidar/height_map',
    r'/utlidar/range_map',
    r'/utlidar/voxel_map',
    r'/utlidar/robot_pose',
    r'/uslam/cloud_map',
    r'/uslam/frontend/cloud_world_ds',
    r'/uslam/frontend/odom',
    r'/uslam/localization/cloud_world',
    r'/uslam/localization/odom',
    r'/uslam/navigation/global_path',
]


def generate_launch_description():
    package_path = get_package_share_directory('fast_lio')
    default_config_path = os.path.join(package_path, 'config')
    
    # 添加以下两行打印路径
    print(f"[DEBUG] package_path: {package_path}")
    print(f"[DEBUG] default_config_path: {default_config_path}")

    # 读取并打印配置文件内容
    config_file_path = os.path.join(default_config_path, 'mid360.yaml')
    print(f"[DEBUG] config_file_path: {config_file_path}")
    try:
        with open(config_file_path, 'r') as f:
            config_content = f.read()
            print(f"[DEBUG] ========== mid360.yaml 内容 ==========")
            print(config_content)
            print(f"[DEBUG] ======================================")
    except Exception as e:
        print(f"[DEBUG] Error reading config file: {e}")

    default_rviz_config_path = os.path.join(
        package_path, 'rviz', 'fastlio.rviz')

    # 动态获取包路径，避免硬编码
    use_sim_time = LaunchConfiguration('use_sim_time')
    config_path = LaunchConfiguration('config_path')
    config_file = LaunchConfiguration('config_file')
    rviz_use = LaunchConfiguration('rviz')
    rviz_cfg = LaunchConfiguration('rviz_cfg')
    foxglove_use = LaunchConfiguration('foxglove')

    # # 声明启动参数（允许用户在命令行传入）
    declare_use_sim_time_cmd = DeclareLaunchArgument(
        'use_sim_time', default_value='false',
        description='Use simulation (Gazebo) clock if true'
    )
    declare_config_path_cmd = DeclareLaunchArgument(
        'config_path', default_value=default_config_path,
        description='Yaml config file path'
    )
    decalre_config_file_cmd = DeclareLaunchArgument(
        'config_file', default_value='mid360.yaml',
        # 'config_file', default_value='avia.yaml',
        description='Config file'
    )
    declare_rviz_cmd = DeclareLaunchArgument(
        'rviz', default_value='false',
        description='Use RViz to monitor results'
    )
    declare_rviz_config_path_cmd = DeclareLaunchArgument(
        'rviz_cfg', default_value=default_rviz_config_path,
        description='RViz config file path'
    )
    declare_foxglove_cmd = DeclareLaunchArgument(
        'foxglove', default_value='true',
        description='Start foxglove_bridge'
    )

    fast_lio_node = Node(
        package='fast_lio', # 包名
        executable='fastlio_mapping', # 可执行文件名
        parameters=[PathJoinSubstitution([config_path, config_file]),
                    {'use_sim_time': use_sim_time}], #  # 参数配置
        remappings=[
            ('/livox/custom_msg', '/unitree/slam_lidar/points'),
            ('/livox/imu', '/unitree/slam_lidar/imu'),
        ],
        output='screen'
    )
    rviz_node = Node(
        package='rviz2',
        executable='rviz2',
        arguments=['-d', rviz_cfg],
        condition=IfCondition(rviz_use)
    )

    # Foxglove bridge for remote visualization
    foxglove_bridge_node = Node(
        package='foxglove_bridge',
        executable='foxglove_bridge',
        parameters=[{
            'port': FOXGLOVE_PORT,
            'address': '0.0.0.0',
            'topic_whitelist': FOXGLOVE_TOPIC_WHITELIST,
            'client_topic_whitelist': [
                r'/clicked_point',
                r'/initialpose',
                r'/move_base_simple/goal',
                r'/goal_point',
            ],
            'send_buffer_limit': 100000000,
            'use_compression': True,
        }],
        condition=IfCondition(foxglove_use),
        output='screen'
    )

    ld = LaunchDescription()
    ld.add_action(declare_use_sim_time_cmd)
    ld.add_action(declare_config_path_cmd)
    ld.add_action(decalre_config_file_cmd)
    ld.add_action(declare_rviz_cmd)
    ld.add_action(declare_rviz_config_path_cmd)
    ld.add_action(declare_foxglove_cmd)

    ld.add_action(fast_lio_node)
    ld.add_action(foxglove_bridge_node)
    # ld.add_action(rviz_node)

    return ld
