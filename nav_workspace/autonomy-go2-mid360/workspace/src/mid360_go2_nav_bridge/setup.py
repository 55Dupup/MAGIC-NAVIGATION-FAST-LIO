from setuptools import setup

package_name = "mid360_go2_nav_bridge"

setup(
    name=package_name,
    version="0.1.0",
    packages=[package_name],
    data_files=[
        ("share/ament_index/resource_index/packages", [f"resource/{package_name}"]),
        (f"share/{package_name}", ["package.xml"]),
        (
            f"share/{package_name}/launch",
            [
                "launch/fastlio_mid360_nav.launch.py",
                "launch/fastlivo2_mid360_frontend.launch.py",
            ],
        ),
    ],
    install_requires=["setuptools"],
    zip_safe=True,
    maintainer="unitree",
    maintainer_email="unitree@example.com",
    description="Bridge FAST-LIO MID360 topics into autonomy_stack_go2.",
    license="MIT",
    entry_points={
        "console_scripts": [
            "fastlio_topic_bridge = mid360_go2_nav_bridge.fastlio_topic_bridge:main",
            "fastlivo2_compat_bridge = mid360_go2_nav_bridge.fastlivo2_compat_bridge:main",
            "global_nav_frame_bridge = mid360_go2_nav_bridge.global_nav_frame_bridge:main",
        ],
    },
)
