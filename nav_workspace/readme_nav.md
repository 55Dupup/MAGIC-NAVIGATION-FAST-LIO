# FAST-LIO 建图快速命令

## 1. 启动容器

```bash
sudo docker start unitree_humble_nav
sudo docker exec -it unitree_humble_nav zsh
```

如果当前用户已经有 Docker 权限，可以去掉 `sudo`。

容器挂载关系：

```text
/home/unitree/go2-fast-lio/nav_workspace -> /workspace/nav_ws
```

## 2. 启动 MID360 输入

在 Jetson 主机终端执行，不在 Docker 里执行：

```bash
cd /unitree/module/unitree_slam/bin
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
./mid360_driver
```

## 3. 启动 FAST-LIO

在 Docker 容器内执行：

```bash
cd /workspace/nav_ws
source install/setup.zsh
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ros2 launch fast_lio mapping.launch.py
```

默认会同时启动 `foxglove_bridge`。如需关闭：

```bash
ros2 launch fast_lio mapping.launch.py foxglove:=false
```

Foxglove 默认不做 topic 白名单过滤，会暴露 ROS 网络里可发现的 topic。容器里没有 Unitree 自定义消息包时，`unitree_api/unitree_go/unitree_interfaces` 相关 topic 可能会打印 schema 报错；这些报错通常不影响 FAST-LIO 建图。

Windows 端连接地址使用机器狗/Jetson 的 IP 和 9001 端口，例如：

```text
ws://192.168.123.18:9001
```

## 4. 检查话题

在 Docker 容器内执行：

```bash
cd /workspace/nav_ws
source install/setup.zsh
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp

ros2 topic info -v /unitree/slam_lidar/points
ros2 topic info -v /unitree/slam_lidar/imu
ros2 topic hz /unitree/slam_lidar/points
ros2 topic hz /unitree/slam_lidar/imu

ros2 topic hz /cloud_registered_1
ros2 topic hz /Odometry_loc
```

`/unitree/slam_lidar/points` 和 `/unitree/slam_lidar/imu` 必须有 publisher，并且能收到数据。只有 subscription 不代表建图链路已通。
当前 `/unitree/slam_lidar/points` 是带 `ring/time` 字段的 PointCloud2，FAST-LIO 配置使用 `lidar_type: 2`、`scan_line: 4`、`timestamp_unit: 3(ns)` 读取逐点时间戳。不要改回普通 `lidar_type: 5`，否则会丢掉逐点时间，运动时点云更容易扭曲。

Foxglove 里建图优先看这些 topic：

```text
/unitree/slam_lidar/points   原始雷达输入
/cloud_registered_1          FAST-LIO 全局点云
/cloud_registered_body_1     FAST-LIO 机体系点云
/Odometry_loc                FAST-LIO 里程计
/path                        FAST-LIO 轨迹
/uslam/cloud_map             宇树 SLAM 地图点云
/utlidar/cloud_deskewed      宇树雷达去畸变点云
```

如果 `/cloud_registered_1` 不存在，说明 FAST-LIO 没有正常启动或没有收到有效输入。

## 5. 保存地图

推荐在宿主机执行保存脚本。它会调用 Docker 内的 `/map_save`，再把地图复制到宿主机目录，默认 `/home/unitree/maps`，文件名默认带日期：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step1_5_save_fastlio_map.sh --name company_001
```

输出示例：

```bash
/home/unitree/maps/company_001_20260519_160908.pcd
```

也可以交互式输入目录和名称：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step1_5_save_fastlio_map.sh
```

先检查不保存：

```bash
bash step1_5_save_fastlio_map.sh --dry-run --name company_001
```

FAST-LIO 原始保存源路径仍由配置控制：

```yaml
map_file_path: "/workspace/nav_ws/maps/test.pcd"
```

这个路径对应宿主机：

```bash
/home/unitree/go2-fast-lio/nav_workspace/maps/test.pcd
```
