# FAST-LIO + 宇树导航顺序脚本说明

详细背景见 [README_fastlio_unitree_multi_nav.md](/home/unitree/go2-fast-lio/nav_workspace/README_fastlio_unitree_multi_nav.md:1)。

## 1. 入口

- 环境检查：[check_environment.sh](/home/unitree/go2-fast-lio/nav_workspace/check_environment.sh:1)
- `step1`：[step1_start_slam.sh](/home/unitree/go2-fast-lio/nav_workspace/step_scripts/step1_start_slam.sh:1)
- `step1.5`：[step1_5_save_fastlio_map.sh](/home/unitree/go2-fast-lio/nav_workspace/step_scripts/step1_5_save_fastlio_map.sh:1)
- `step2`：[step2_check_relocalization.sh](/home/unitree/go2-fast-lio/nav_workspace/step_scripts/step2_check_relocalization.sh:1)
- `step3`：[step3_record_nav_point.sh](/home/unitree/go2-fast-lio/nav_workspace/step_scripts/step3_record_nav_point.sh:1)
- `step4`：[step4_sync_nav_points.sh](/home/unitree/go2-fast-lio/nav_workspace/step_scripts/step4_sync_nav_points.sh:1)
- `step5`：[step5_run_nav_client.sh](/home/unitree/go2-fast-lio/nav_workspace/step_scripts/step5_run_nav_client.sh:1)

说明：

- `step1` 只是包装原始脚本 [start_slam.sh](/home/unitree/unitree_sdk2_python/scripts_v2/start_slam.sh:1)，不会复制逻辑。
- 这些脚本都在 Jetson 主机终端执行，不在 Docker 容器里执行。
- MID360 原厂驱动在 Jetson 主机运行；FAST-LIO 建图和 `/map_save` 在 Docker 容器里执行。
- `step2` 和 `step3` 读取 `/slam_info` 时会自动加载 `/opt/ros/foxy/setup.bash`，并补充 CycloneDDS 与 Python 路径。
- 当前 Docker/host 联通实测使用 `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` 更稳定；如果手工启动 FAST-LIO，也建议显式导出这个变量。
- 除了 FAST-LIO 建图，下面所有 `step*.sh` 都建议在这个目录执行：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
```

迁移服务器或重建 Docker 后，先检查路径和容器挂载：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace
bash check_environment.sh
```

如果当前用户没有 Docker 权限：

```bash
DOCKER_CMD="sudo docker" bash check_environment.sh
```

## 2. 执行环境总表

| 阶段 | 在哪里执行 | 工作目录 | 说明 |
| --- | --- | --- | --- |
| MID360 雷达输入 | Jetson 主机终端 | `/unitree/module/unitree_slam/bin` | 启动原厂 `mid360_driver` |
| FAST-LIO 建图 | Docker 容器 `unitree_humble_nav` | `/workspace/nav_ws` | 只负责建图和保存 `.pcd` |
| `step1` 启动宇树 SLAM/重定位 | Jetson 主机终端 A | `/home/unitree/go2-fast-lio/nav_workspace/step_scripts` | 会进入 tmux，按 `a` 触发重定位 |
| `step2` 检查重定位 | Jetson 主机终端 B | `/home/unitree/go2-fast-lio/nav_workspace/step_scripts` | 读取 `/slam_info` 位姿 |
| `step3` 记录点位 | Jetson 主机终端 B | `/home/unitree/go2-fast-lio/nav_workspace/step_scripts` | 写入 `nav_points_record.yaml` |
| `step4` 同步导航配置 | Jetson 主机终端 B | `/home/unitree/go2-fast-lio/nav_workspace/step_scripts` | 写入宇树 `client_config.json` |
| `step5` 启动多点导航 | Jetson 主机终端 C | `/home/unitree/go2-fast-lio/nav_workspace/step_scripts` | 运行现有导航客户端，可指定配置 JSON |

## 3. 地图路径

`step1` 支持直接传地图路径，不需要改原始 `start_slam.sh`。

默认地图：

```bash
/home/unitree/go2-fast-lio/nav_workspace/maps/kitchen_pro.pcd
```

也可以启动时指定：

```bash
bash step1_start_slam.sh /path/to/your_map.pcd
bash step1_start_slam.sh --maps /home/unitree/maps/company_001-test_20260519_195622.pcd
```

启动前检查最终命令：

```bash
bash step1_start_slam.sh --dry-run /path/to/your_map.pcd
bash step1_start_slam.sh --dry-run --maps /path/to/your_map.pcd
```

```bash
cp /home/unitree/go2-fast-lio/nav_workspace/maps/kitchen_pro.pcd /home/unitree/maps/kitchen_pro.pcd
```

## 4. 执行顺序

### 终端 A：Jetson 主机，启动重定位

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step1_start_slam.sh
```

如果要指定地图：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step1_start_slam.sh --maps /home/unitree/maps/company_001-test_20260519_195622.pcd
```

然后在 tmux 重定位界面里：

1. 等界面稳定
2. 按一次小写 `a`

### 终端 B：Jetson 主机，检查重定位和记录点

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step2_check_relocalization.sh
```

通过后开始录点：

```bash
bash step3_record_nav_point.sh --name 起点 --mode overwrite
bash step3_record_nav_point.sh --name 吧台 --mode overwrite
bash step3_record_nav_point.sh --name 前台 --mode overwrite
bash step3_record_nav_point.sh --name 前台 --mode append

bash step3_record_nav_point.sh --name magic --mode overwrite
bash step3_record_nav_point.sh --name magic --mode append
```

同步配置：

```bash
bash step4_sync_nav_points.sh --dry-run
bash step4_sync_nav_points.sh
```

### 终端 C：Jetson 主机，启动多点导航

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step5_run_nav_client.sh
```

如果要使用其它导航配置 JSON：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step5_run_nav_client.sh --config /home/unitree/go2-fast-lio/nav_workspace/configs/client_config_kitchen.json
```

配套同步时也要指定同一个 JSON：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step4_sync_nav_points.sh --client-config /home/unitree/go2-fast-lio/nav_workspace/configs/client_config_kitchen.json
```

### FAST-LIO 建图：host 启动雷达，Docker 启动 FAST-LIO

如果要重新建图，先在 Jetson 主机终端启动 MID360 原厂驱动：

```bash
cd /unitree/module/unitree_slam/bin
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
./mid360_driver
```

然后在另一个终端进入容器启动 FAST-LIO：

```bash
sudo docker start unitree_humble_nav
sudo docker exec -it unitree_humble_nav zsh
cd /workspace/nav_ws
source install/setup.zsh
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ros2 launch fast_lio mapping.launch.py
```

默认会启动 Foxglove。关闭方式：

```bash
ros2 launch fast_lio mapping.launch.py foxglove:=false
```

再开一个容器终端检查输入输出并保存地图：

```bash
sudo docker exec -it unitree_humble_nav zsh
cd /workspace/nav_ws
source install/setup.zsh
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ros2 topic info -v /unitree/slam_lidar/points
ros2 topic info -v /unitree/slam_lidar/imu
ros2 topic hz /cloud_registered_1
ros2 topic hz /Odometry_loc
```

保存地图在宿主机执行：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step1_5_save_fastlio_map.sh --name company_001
```

默认保存到 `/home/unitree/maps/company_001_YYYYmmdd_HHMMSS.pcd`。

不要在容器里执行 `step1` 到 `step5`。容器内没有 `/unitree/module/unitree_slam/bin/mid360_driver` 时，这是正常的；该驱动属于 Jetson 主机环境。

## 5. 输出文件

- 采点记录：[nav_points_record.yaml](/home/unitree/go2-fast-lio/nav_workspace/nav_points_record.yaml:1)
- 运行配置：`/home/unitree/unitree_sdk2_python/agent/config/client_config.json`

## 6. 注意

- `step1` 会占住当前终端，因为原始 `start_slam.sh` 会自动 attach 到 tmux。
- `step2` 报 `No valid pose received from /slam_info` 时，优先回到 `go2_relocation` 看是否已经显示 `Successfully started relocation`。
- `step3` 只负责读当前位姿并写 yml，不会移动机器人。
- `step4` 会改 `client_config.json`，但会先自动备份。
- `step5 --config` 会运行临时客户端副本，不会修改宇树原始 `client_recon_v1.py`。
