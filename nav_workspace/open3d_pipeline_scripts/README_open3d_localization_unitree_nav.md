# Open3D 重定位接入宇树导航操作指南

本文只说明 Open3D 重定位这条新链路。

核心结论：

- 平时操作都在**宿主机终端**执行。
- 不要手动进入 Docker 启动 FAST-LIO/Open3D；启动脚本会自动操作 Docker。
- `mid360_driver` 只能在**宿主机**运行，不在 Docker 里运行。
- Docker 容器只运行 ROS2 Humble 下的 FAST-LIO、Open3D localization、Foxglove bridge 等节点。
- FAST-LIO 的 `mapping.launch.py` 默认启动 Foxglove；需要关闭时传 `foxglove:=false`。
- Foxglove 默认不做 topic 白名单过滤。容器里没有 Unitree 自定义消息包时，相关 topic 可能打印 schema 报错；这些报错通常不影响 FAST-LIO 建图。

## 1. 路径和角色

| 项目 | 路径 / 名称 | 说明 |
| --- | --- | --- |
| 操作目录 | `/home/unitree/go2-fast-lio/nav_workspace/open3d_pipeline_scripts` | 宿主机终端进入这里执行脚本 |
| Docker 容器 | `unitree_humble_nav` | 已挂载 `/home/unitree/go2-fast-lio/nav_workspace` 到 `/workspace/nav_ws` |
| 默认地图 | `/workspace/nav_ws/maps/company_001_level_pro.pcd` | Docker 内路径 |
| 默认 Open3D 配置 | `/workspace/nav_ws/src/fast/open3d_loc/config/loc_param_go2.yaml` | Go2/MID360 专用 |
| 宿主机 MID360 driver | `/unitree/module/unitree_slam/bin/mid360_driver` | 只在宿主机跑 |
| Open3D 输出位置 | `/localization_3d` | `[x, y, z, qx, qy, qz, qw]` |
| Open3D 输出置信度 | `/localization_3d_confidence` | 当前有效阈值默认 `>= 0.55` |

Go2 MID360 外参由启动脚本发布为静态 TF：

```text
base_link -> imu_link
xyz   = [0.1870, 0.0, 0.0803]
qxyzw = [0.0, 0.0, 0.0, 1.0]
```

## 2. 一键启动 Open3D 重定位

全部在宿主机终端执行：

```bash
sudo docker start unitree_humble_nav
cd /home/unitree/go2-fast-lio/nav_workspace/open3d_pipeline_scripts
```

如果当前用户已有 Docker 权限，可以去掉 `sudo`，并把下面命令里的 `DOCKER_CMD="sudo docker"` 改为 `DOCKER_CMD="docker"`。

启动 MID360 输入：

```bash
bash open3d_start_mid360_host.sh
```

检查环境和雷达输入：

```bash
DOCKER_CMD="sudo docker" bash open3d_step0_check_environment.sh \
  --map /workspace/nav_ws/maps/company_001_level_pro.pcd \
  --check-input-topics
```

启动 FAST-LIO + Open3D localization：

```bash
DOCKER_CMD="sudo docker" bash open3d_step1_start_fastlio_open3d_loc.sh \
  --map /workspace/nav_ws/maps/company_001_level_pro.pcd \
  --wait-topic-timeout 60
```

检查 Open3D 是否重定位成功：

```bash
bash open3d_step2_check_localization.sh
```

成功输出示例：

```text
Open3D localization pose samples:
  sample 1: [x, y, z, qx, qy, qz, qw]
  sample 2: [...]
  sample 3: [...]
Position span: dx=... m, dy=... m
Open3D localization looks valid.
```

`open3d_step2_check_localization.sh` 默认要求：

```text
/localization_3d_confidence >= 0.55
```

只想临时查看低置信度输出时：

```bash
bash open3d_step2_check_localization.sh --min-confidence 0.0
```

## 3. 各脚本在哪里执行

| 脚本 | 在哪里执行 | 是否进入 Docker | 作用 |
| --- | --- | --- | --- |
| `open3d_start_mid360_host.sh` | 宿主机 | 否 | 启动宿主机 MID360 driver |
| `open3d_step0_check_environment.sh` | 宿主机 | 否 | 检查 Docker、地图、ROS 包、雷达输入 |
| `open3d_step1_start_fastlio_open3d_loc.sh` | 宿主机 | 否 | 自动在 Docker 内启动 FAST-LIO/Open3D |
| `open3d_step2_check_localization.sh` | 宿主机 | 否 | 检查 Open3D 位置和置信度 |
| `open3d_step2b_compare_pose_frame.sh` | 宿主机 | 否 | 对比 Open3D 和宇树 `/slam_info` 坐标 |
| `open3d_step3_record_nav_point.sh` | 宿主机 | 否 | 记录 Open3D 采点 |
| `open3d_step4_sync_nav_points.sh` | 宿主机 | 否 | 同步采点到导航 JSON |
| `open3d_step5_run_unitree_nav.sh` | 宿主机 | 否 | 启动宇树导航客户端 |
| `open3d_stop_pipeline.sh` | 宿主机 | 否 | 停止 Docker 内 FAST-LIO/Open3D |
| `open3d_stop_mid360_host.sh` | 宿主机 | 否 | 停止宿主机 MID360 driver |

日常不需要进入 Docker。

## 4. 查看当前位置和置信度

推荐方式，在宿主机执行：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/open3d_pipeline_scripts
bash open3d_step2_check_localization.sh
```

直接查看一次置信度：

```bash

```

直接查看一次位置：

```bash
sudo docker exec unitree_humble_nav bash -lc \
  'cd /workspace/nav_ws && source install/setup.bash && export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp && ros2 topic echo --once /localization_3d'
```

宿主机直接 `ros2 topic echo` 偶尔会因为 Foxy/conda 环境崩溃；遇到 `Segmentation fault` 时用上面的 Docker 命令。

## 5. 进入 Docker 调试

只有调试时才需要进入 Docker：

```bash
sudo docker exec -it unitree_humble_nav bash
```

进入后执行：

```bash
cd /workspace/nav_ws
source install/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
```

常用检查：

```bash
ros2 topic list
ros2 topic echo --once /localization_3d
ros2 topic echo --once /localization_3d_confidence
ros2 topic echo --once /Odometry_loc
ros2 topic echo --once /cloud_registered_1
tail -n 100 /tmp/open3d_localization.log
tail -n 100 /tmp/open3d_fastlio.log
```

退出 Docker：

```bash
exit
```

## 6. 启动 Foxglove 查看实时位置

在宿主机执行：

```bash
sudo docker exec -d unitree_humble_nav bash -lc '
cd /workspace/nav_ws
source install/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ros2 launch foxglove_bridge foxglove_bridge_launch.xml \
  port:=9001 \
  address:=0.0.0.0 \
  > /tmp/foxglove_bridge.log 2>&1
'
```

查看 bridge 状态：

```bash
sudo docker exec unitree_humble_nav bash -lc 'pgrep -af foxglove_bridge'
sudo docker exec unitree_humble_nav tail -n 80 /tmp/foxglove_bridge.log
```

Foxglove Studio 连接：

```text
ws://192.168.123.18:9001
```

如果在本机打开 Foxglove，也可试：

```text
ws://localhost:9001
```

建议添加这些 topic：

```text
/localization_3d
/localization_3d_confidence
/Odometry_loc
/cloud_registered_1
/map
/tf
/tf_static
```

停止 Foxglove bridge：

```bash
sudo docker exec unitree_humble_nav bash -lc 'pkill -f foxglove_bridge'
```

## 7. 停止 Open3D 重定位

停止 Docker 内 FAST-LIO/Open3D：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/open3d_pipeline_scripts
DOCKER_CMD="sudo docker" bash open3d_stop_pipeline.sh
```

停止宿主机 MID360 driver：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/open3d_pipeline_scripts
bash open3d_stop_mid360_host.sh
```

如果只想重启 Open3D/FAST-LIO，不要停 MID360，只执行：

```bash
DOCKER_CMD="sudo docker" bash open3d_stop_pipeline.sh
DOCKER_CMD="sudo docker" bash open3d_step1_start_fastlio_open3d_loc.sh \
  --map /workspace/nav_ws/maps/company_001_level_pro.pcd \
  --wait-topic-timeout 60
```

## 8. 采点和导航

先确认 Open3D 定位有效：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/open3d_pipeline_scripts
bash open3d_step2_check_localization.sh
```

记录一个点：

```bash
bash open3d_step3_record_nav_point.sh --name 起点 --mode overwrite
```

如果已经通过 `open3d_step2b_compare_pose_frame.sh --save-transform` 保存了 Open3D 到宇树坐标的转换，采点时加 `--apply-transform`：

```bash
bash open3d_step3_record_nav_point.sh --name 起点 --mode overwrite --apply-transform
```

追加同一地点路径点：

```bash
bash open3d_step3_record_nav_point.sh --name 前台 --mode overwrite
bash open3d_step3_record_nav_point.sh --name 前台 --mode append
```

默认记录文件：

```text
/home/unitree/go2-fast-lio/nav_workspace/open3d_nav_points_record.yaml
```

记录文件会同时保存两份 pose：

```yaml
locations:
  起点:
    poses: [...]
    raw_open3d_poses: [...]
    unitree_frame_poses: [...]
```

字段含义：

```text
raw_open3d_poses: 原始 /localization_3d 输出。
unitree_frame_poses: 应用转换后的宇树导航坐标系 pose。
poses: 和 unitree_frame_poses 相同，用于同步到宇树导航 JSON，保留这个字段是为了兼容旧脚本。
```

没有加 `--apply-transform` 时，`unitree_frame_poses` 会等于 `raw_open3d_poses`，并标记 `transform_applied: false`。

建议使用单独的 Open3D 导航配置，不要直接覆盖原始 `client_config.json`：

```bash
mkdir -p /home/unitree/go2-fast-lio/nav_workspace/configs
cp /home/unitree/unitree_sdk2_python/agent/config/client_config.json \
  /home/unitree/go2-fast-lio/nav_workspace/configs/client_config_open3d_company_001.json
```

同步采点到这个 JSON：

```bash
bash open3d_step4_sync_nav_points.sh \
  --client-config /home/unitree/go2-fast-lio/nav_workspace/configs/client_config_open3d_company_001.json
```

启动宇树导航客户端：

```bash
bash open3d_step5_run_unitree_nav.sh \
  --config /home/unitree/go2-fast-lio/nav_workspace/configs/client_config_open3d_company_001.json
```

## 9. 坐标系对齐

Open3D 输出是 `/localization_3d`。

宇树原始重定位输出是 `/slam_info.data.currentPose`。

两者格式都是：

```text
[x, y, z, qx, qy, qz, qw]
```

但不能默认认为坐标系完全一致。

只有在宇树原始重定位成功后，才做对比：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/open3d_pipeline_scripts
bash open3d_step2b_compare_pose_frame.sh
```

如果差异稳定且需要保存转换：

```bash
bash open3d_step2b_compare_pose_frame.sh --save-transform
```

之后采点时使用转换：

```bash
bash open3d_step3_record_nav_point.sh --name 目标点 --apply-transform
```

当前如果宇树原始重定位 `keyDemo_changemap` 返回 `errorCode=509`，说明 `/slam_info` 无效，不能做坐标对齐。

## 10. 常见问题

### Docker 容器没启动

```bash
sudo docker start unitree_humble_nav
```

### Open3D 已有进程，step1 拒绝启动

这不是重定位失败。它表示 Docker 里已经有 FAST-LIO/Open3D 进程在运行，脚本拒绝再启动一套重复进程。

典型输出：

```text
Existing FAST-LIO/Open3D localization process detected in container:
... fastlio_mapping ...
... global_localization_node ...
Stop it first, or rerun with --allow-existing-fastlio ...
```

先判断当前定位是否已经可用：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/open3d_pipeline_scripts
bash open3d_step2_check_localization.sh
```

如果 `step2` 成功，就不用重新启动。

先停止旧 pipeline：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/open3d_pipeline_scripts
DOCKER_CMD="sudo docker" bash open3d_stop_pipeline.sh
```

再启动：

```bash
DOCKER_CMD="sudo docker" bash open3d_step1_start_fastlio_open3d_loc.sh \
  --map /workspace/nav_ws/maps/company_001_level_pro.pcd \
  --wait-topic-timeout 60
```

### step2 报 `No valid pose received`

这个报错表示当前没有收到有效 `/localization_3d`，不等于进程一定没启动。

先确认进程和话题：

```bash
sudo docker exec unitree_humble_nav bash -lc \
  "ps -ef | grep -E 'fastlio_mapping|global_localization_node|static_transform_publisher' | grep -v grep"

sudo docker exec unitree_humble_nav bash -lc \
  'cd /workspace/nav_ws && source install/setup.bash && export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp && ros2 topic list | sort | grep -E "localization_3d|Odometry_loc|cloud_registered_1|unitree/slam_lidar"'
```

如果进程和话题都存在，再看 Open3D 日志：

```bash
sudo docker exec unitree_humble_nav bash -lc \
  'tail -n 120 /tmp/open3d_localization.log'
```

如果日志连续出现：

```text
reg_result.fitness: 0.0, eva fitness: 0.0
```

说明 Open3D 当前 ICP 没有收敛，所以不会发布有效 `/localization_3d`。常见原因是 FAST-LIO 当前 odom 已经漂到离地图当前位置很远，或者同时混跑了宇树原始 SLAM 和 Open3D 链路。

检查 FAST-LIO 当前 odom：

```bash
sudo docker exec unitree_humble_nav bash -lc \
  'cd /workspace/nav_ws && source install/setup.bash && export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp && timeout 6 ros2 topic echo --once /Odometry_loc'
```

如果 `/Odometry_loc` 的位置明显离谱，例如几十米偏移或 z 方向数米偏移，先清理并按单链路重启。

推荐清理顺序：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/open3d_pipeline_scripts
DOCKER_CMD="sudo docker" bash open3d_stop_pipeline.sh
bash open3d_stop_mid360_host.sh
```

如果之前手动启动过 Docker 内进程，`open3d_stop_pipeline.sh` 可能无法清掉所有手动残留。只在这种情况下使用下面的兜底命令：

```bash
sudo docker exec unitree_humble_nav bash -lc \
  "pkill -f 'fastlio_mapping|global_localization_node|static_transform_publisher' || true"
```

然后只启动 Open3D 链路：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/open3d_pipeline_scripts
bash open3d_start_mid360_host.sh

DOCKER_CMD="sudo docker" bash open3d_step1_start_fastlio_open3d_loc.sh \
  --map /workspace/nav_ws/maps/company_001_level_pro.pcd \
  --wait-topic-timeout 60

bash open3d_step2_check_localization.sh
```

不要同时运行宇树原始 `unitree_slam/keyDemo_changemap` 和 Open3D/FAST-LIO。两条链路混跑时，可能出现 Open3D `fitness=0`、宇树 `/slam_info` 失效、或宇树 `icp score greater than 0.03`。

### Open3D 置信度很高但位置明显不对

`/localization_3d_confidence` 是当前局部点云和地图局部区域的匹配质量，不是“全局唯一正确位置”的证明。

如果场地空旷、桌子/货架/墙面结构重复，错误位置也可能得到较高 fitness。混跑宇树原始 SLAM 和 Open3D/FAST-LIO 时更容易出现这种假成功。

先看当前是否混跑：

```bash
tmux ls
pgrep -af 'unitree_slam|keyDemo_changemap|mid360_driver'
```

Open3D 单链路时，宿主机最多应只有 `open3d_mid360_host` 里的一个 `mid360_driver`。不应该同时有：

```text
go2_slam
go2_lidar
go2_relocation
unitree_slam
keyDemo_changemap
第二个 mid360_driver
```

再看 FAST-LIO odom 是否离谱：

```bash
sudo docker exec unitree_humble_nav bash -lc \
  'cd /workspace/nav_ws && source install/setup.bash && export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp && timeout 6 ros2 topic echo --once /Odometry_loc'
```

如果 `/Odometry_loc` 的 z 已经到数米，或 x/y 明显远离当前位置，当前 Open3D 输出即使置信度高也不能信。先清理所有链路，再只启动 Open3D。

如果确认没有混跑，但仍然稳定定位到错误区域，说明地图里存在重复结构造成误匹配。此时不要直接使用 `[0,0,0,0,0,0]` 全零初值，启动时给 Open3D 一个接近真实位置的初值：

```bash
DOCKER_CMD="sudo docker" bash open3d_step1_start_fastlio_open3d_loc.sh \
  --map /workspace/nav_ws/maps/company_001_level_pro.pcd \
  --initialpose x,y,z,roll,pitch,yaw \
  --wait-topic-timeout 60
```

`--initialpose` 的单位是：

```text
x y z: 米
roll pitch yaw: 角度 degree
```

### 启动脚本提示宿主机有宇树原始 SLAM 冲突

新版脚本会拒绝在 `go2_slam/go2_lidar/go2_relocation` 或 `unitree_slam/keyDemo_changemap` 运行时启动 Open3D。

这是正常保护，先停止宇树原始链路：

```bash
tmux kill-session -t go2_relocation 2>/dev/null || true
tmux kill-session -t go2_lidar 2>/dev/null || true
tmux kill-session -t go2_slam 2>/dev/null || true
```

然后重新启动 Open3D。

### 缺少 `liblapacke.so.3`

只在 Docker 里安装：

```bash
sudo docker exec unitree_humble_nav apt-get install -y liblapacke
```

### 查看实际 Open3D 参数

```bash
sudo docker exec unitree_humble_nav bash -lc \
  'cd /workspace/nav_ws && source install/setup.bash && export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp && ros2 param dump /global_loc_node'
```

应看到：

```text
voxelsize_fine: 0.3
threshold_fitness: 0.55
path_map: /workspace/nav_ws/maps/company_001_level_pro.pcd
```

### 查看 Go2 MID360 外参是否生效

```bash
sudo docker exec unitree_humble_nav bash -lc \
  'cd /workspace/nav_ws && source install/setup.bash && export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp && timeout 5 ros2 run tf2_ros tf2_echo base_link imu_link'
```

应看到：

```text
Translation: [0.187, 0.000, 0.080]
Rotation: [0.000, 0.000, 0.000, 1.000]
```

## 11. 不要做的事

- 不要在 Docker 里运行 `mid360_driver`。
- 不要在 Docker 里执行 `open3d_start_mid360_host.sh`。
- 不要日常手动 `pkill fastlio_mapping`，优先用 `open3d_stop_pipeline.sh`。
- 不要把低置信度 `/localization_3d` 直接用于采点和导航。
- 不要在未对齐坐标系前假设 Open3D pose 等于宇树 `/slam_info` pose。
- 不要同时运行宇树原始 `unitree_slam/keyDemo_changemap` 和 Open3D/FAST-LIO。
