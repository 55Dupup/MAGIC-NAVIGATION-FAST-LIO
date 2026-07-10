import os

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.conditions import IfCondition
from launch.substitutions import LaunchConfiguration, PythonExpression
from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterValue


def generate_launch_description():
    default_base = "/workspace/autonomy-go2-mid360/config/fastlivo2"
    livo_params_file = LaunchConfiguration("livo_params_file")
    camera_params_file = LaunchConfiguration("camera_params_file")
    use_rviz = LaunchConfiguration("use_rviz")
    use_compat_bridge = LaunchConfiguration("use_compat_bridge")
    lio_only = LaunchConfiguration("lio_only")

    return LaunchDescription(
        [
            DeclareLaunchArgument(
                "livo_params_file",
                default_value=os.path.join(default_base, "unitree_go2_mid360_livo2.yaml"),
                description="FAST-LIVO2 parameters for Go2 MID360.",
            ),
            DeclareLaunchArgument(
                "camera_params_file",
                default_value=os.path.join(default_base, "camera_front_pinhole.yaml"),
                description="Vikit camera model parameters for the front camera.",
            ),
            DeclareLaunchArgument(
                "use_rviz",
                default_value="False",
                description="Start FAST-LIVO2 RViz if installed.",
            ),
            DeclareLaunchArgument(
                "use_compat_bridge",
                default_value="True",
                description="Republish FAST-LIVO2 outputs as /Odometry_loc and /cloud_registered_1.",
            ),
            DeclareLaunchArgument(
                "lio_only",
                default_value="False",
                description="Disable image updates for smoke tests when camera is not ready.",
            ),
            Node(
                package="demo_nodes_cpp",
                executable="parameter_blackboard",
                name="parameter_blackboard",
                parameters=[camera_params_file],
                output="screen",
            ),
            Node(
                package="fast_livo",
                executable="fastlivo_mapping",
                name="laserMapping",
                parameters=[
                    livo_params_file,
                    {
                        "common.img_en": ParameterValue(
                            PythonExpression(
                                ["0 if '", lio_only, "'.lower() in ['true', '1', 'yes'] else 1"]
                            ),
                            value_type=int,
                        )
                    },
                ],
                output="screen",
            ),
            Node(
                package="mid360_go2_nav_bridge",
                executable="fastlivo2_compat_bridge",
                name="fastlivo2_compat_bridge",
                output="screen",
                condition=IfCondition(use_compat_bridge),
            ),
            Node(
                package="rviz2",
                executable="rviz2",
                name="fastlivo2_rviz",
                condition=IfCondition(use_rviz),
                output="screen",
            ),
        ]
    )
