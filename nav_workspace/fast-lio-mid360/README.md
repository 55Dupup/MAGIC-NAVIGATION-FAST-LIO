# FAST-LIO MID360 一键建图

这个目录和原始 FAST-LIO 包隔离。脚本复用已有的 `fast_lio` 可执行文件和
`mapping.launch.py`，但启动时传入 `fast-lio-mid360/config` 里的配置副本，
不会修改原始 `FAST_LIO/config/mid360.yaml`。

默认模式面向“任意本体 + MID360”：在容器里启动 `livox_ros_driver2`，订阅
`/livox/lidar` 和 `/livox/imu` 建图。宇树 Go2 只是一个示例兼容模式。

## 文件

- `config/mid360_fastlio.yaml`：通用 Livox ROS2 driver 模式的 FAST-LIO 配置。
- `config/unitree_go2_fastlio.yaml`：宇树 Go2 示例配置，使用
  `/unitree/slam_lidar/points` 和 `/unitree/slam_lidar/imu`。
- `config/MID360_config.json`：MID360 网络/驱动配置副本。通用模式下主要改这里
  的雷达 IP、主机 IP 和端口。
- `scripts/fast_lio_mid360_mapping.sh`：交互式一键建图脚本。
- `output/current_map.pcd`：FAST-LIO `/map_save` 写入的临时点云路径。
- `maps/`：默认保存最终带时间戳的地图点云。

## 运行

通用模式，在仓库根目录执行：

```bash
bash nav_workspace/fast-lio-mid360/scripts/fast_lio_mid360_mapping.sh
```

宇树 Go2 示例模式：

```bash
bash nav_workspace/fast-lio-mid360/scripts/fast_lio_mid360_mapping.sh \
  --driver-mode unitree \
  --config-file unitree_go2_fastlio.yaml
```

如果你已经用自己的方式启动了 MID360 driver，只让脚本负责 FAST-LIO 和保存：

```bash
bash nav_workspace/fast-lio-mid360/scripts/fast_lio_mid360_mapping.sh \
  --driver-mode external
```

按键：

- `s`：MID360 driver 启动后，开始 FAST-LIO 建图。
- `q`：调用 `/map_save`，把 PCD 复制到指定输出目录，然后停止本脚本启动的建图
  session 和 driver session。

常用参数：

```bash
bash nav_workspace/fast-lio-mid360/scripts/fast_lio_mid360_mapping.sh \
  --output-dir /home/unitree/maps \
  --name factory_floor
```

输出文件类似：

`/home/unitree/maps/factory_floor_YYYYmmdd_HHMMSS.pcd`.

## MID360 参数

通用模式优先调整 `config/MID360_config.json` 里的网络参数：

- `host_net_info.*_ip`：运行 driver 的主机 IP。
- `lidar_configs[0].ip`：MID360 的雷达 IP。
- 端口保持默认即可，除非你的网络规划要求修改。

如果使用 MID360 自带 IMU，MID360 安装到不同底盘上通常不需要改 FAST-LIO 的
`extrinsic_T/R`；底盘上的安装位置应由机器人系统里的
`base_link -> livox_frame` 静态 TF 表达。

只有在你不用 MID360 内置 IMU，而改用车体 IMU 时，才需要把下面参数改成
“雷达到车体 IMU”的外参：

```yaml
mapping:
  extrinsic_est_en: false
  extrinsic_T: [x, y, z]
  extrinsic_R: [r11, r12, r13,
                r21, r22, r23,
                r31, r32, r33]
```

如果从通用 Livox ROS2 driver 切换到其它 driver，也要同步修改同一个 YAML
里的 `common.lid_topic`、`common.imu_topic` 和 `preprocess.lidar_type`。
