# FAST-LIO 地图接入宇树 Go2 现有多点导航操作说明

如果你现在更关心“按顺序执行”的操作入口，优先看：

- [README_fastlio_unitree_step_scripts.md](/home/unitree/go2-fast-lio/nav_workspace/README_fastlio_unitree_step_scripts.md:1)

## 0. 执行位置

| 操作 | 在哪里执行 | 工作目录 |
| --- | --- | --- |
| 启动 MID360 雷达输入 | Jetson 主机终端 | `/unitree/module/unitree_slam/bin` |
| FAST-LIO 建图、保存 `.pcd` | Docker 容器 `unitree_humble_nav` | `/workspace/nav_ws` |
| 启动宇树 SLAM/重定位 `step1` | Jetson 主机终端 | `/home/unitree/go2-fast-lio/nav_workspace/step_scripts` |
| 检查重定位 `step2` | Jetson 主机终端 | `/home/unitree/go2-fast-lio/nav_workspace/step_scripts` |
| 记录点位 `step3` | Jetson 主机终端 | `/home/unitree/go2-fast-lio/nav_workspace/step_scripts` |
| 同步配置 `step4` | Jetson 主机终端 | `/home/unitree/go2-fast-lio/nav_workspace/step_scripts` |
规则：

- MID360 原厂驱动在 Jetson 主机运行，不在 Docker 容器里运行。
- FAST-LIO、Foxglove 和 `/map_save` 在 Docker 容器里运行。
- `step1` 到 `step5` 在 Jetson 主机终端运行。
- 手工启动 FAST-LIO 或检查话题时，建议设置 `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp`。

## 1. 当前链路

当前链路：

1. 用 FAST-LIO 建图并导出 `.pcd` 地图。
2. 用宇树 `keyDemo_changemap` 加载 FAST-LIO 地图并重定位。
3. 重定位成功后，从 `/slam_info` 读取当前位置。
4. 用 `step3` 记录导航点，用 `step4` 同步到 `client_config.json`。
5. 用 `step5` 调用现有宇树导航客户端。

## 2. 相关文件

- FAST-LIO 建图说明补充：[/home/unitree/go2-fast-lio/nav_workspace/readme_nav.md](/home/unitree/go2-fast-lio/nav_workspace/readme_nav.md:1)
- 宇树重定位启动脚本：[/home/unitree/unitree_sdk2_python/scripts_v2/start_slam.sh](/home/unitree/unitree_sdk2_python/scripts_v2/start_slam.sh:1)
- 顺序执行脚本：[step_scripts](/home/unitree/go2-fast-lio/nav_workspace/step_scripts:1)
- 当前位姿读取脚本：[/home/unitree/unitree_sdk2_python/navi_update/get_pose.py](/home/unitree/unitree_sdk2_python/navi_update/get_pose.py:1)
- 当前导航配置：[/home/unitree/unitree_sdk2_python/agent/config/client_config.json](/home/unitree/unitree_sdk2_python/agent/config/client_config.json:1)
- 当前导航执行封装：[/home/unitree/unitree_sdk2_python/navi_update/unitree_nav.py](/home/unitree/unitree_sdk2_python/navi_update/unitree_nav.py:1)
- 本次新增点位记录模板：[nav_points_record.yaml](/home/unitree/go2-fast-lio/nav_workspace/nav_points_record.yaml:1)

## 3. 整体流程

### 第一步：FAST-LIO 建图

更短命令见 [readme_nav.md](/home/unitree/go2-fast-lio/nav_workspace/readme_nav.md:1)。

终端 A，Jetson 主机：

```bash
cd /unitree/module/unitree_slam/bin
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
./mid360_driver
```

终端 B，Docker 容器：

```bash
sudo docker restart unitree_humble_nav
sudo docker exec -it unitree_humble_nav zsh
cd /workspace/nav_ws
source install/setup.zsh
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ros2 launch fast_lio mapping.launch.py
```

`mapping.launch.py` 默认启动 Foxglove。关闭 Foxglove：

```bash
ros2 launch fast_lio mapping.launch.py foxglove:=false
```

Foxglove 默认不做 topic 白名单过滤。容器里没有 Unitree 自定义消息包时，相关 topic 可能打印 schema 报错；这些报错通常不影响 FAST-LIO 建图。
Windows 端连接 `ws://<Jetson-IP>:9001`，例如 `ws://192.168.123.18:9001`。

终端 C，Docker 容器检查输入输出：

```bash
sudo docker exec -it unitree_humble_nav zsh
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

`/unitree/slam_lidar/points` 和 `/unitree/slam_lidar/imu` 必须有 publisher 并能收到数据。

保存地图并复制到宿主机：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step1_5_save_fastlio_map.sh --name company_001
```

默认输出目录是 `/home/unitree/maps`，文件名会自动追加日期，例如：

```bash
/home/unitree/maps/company_001_20260519_160908.pcd
```

直接调用 `/map_save` 时，FAST-LIO 会先写入配置里的源路径：

```yaml
map_file_path: "/workspace/nav_ws/maps/test.pcd"
```

### 第二步：启动宇树重定位

使用 [step1_start_slam.sh](/home/unitree/go2-fast-lio/nav_workspace/step_scripts/step1_start_slam.sh:1) 启动。它会调用原始 [start_slam.sh](/home/unitree/unitree_sdk2_python/scripts_v2/start_slam.sh:1)，并在运行时把地图路径替换成你传入的 `.pcd`，不用手动修改原始脚本。

以下命令在 Jetson 主机终端执行，不在 Docker 里执行。

先 dry-run 检查最终会使用哪张地图：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step1_start_slam.sh --dry-run --maps /home/unitree/maps/company_001_level_pro.pcd
```

确认无误后启动：

```bash
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step1_start_slam.sh --maps /home/unitree/maps/company_001-test_20260519_195622.pcd
```

如果不传地图路径，默认使用：

```bash
/home/unitree/go2-fast-lio/nav_workspace/maps/kitchen_pro.pcd
```

路径测试结果：

- 已测试：`--dry-run` 能把 `/home/unitree/go2-fast-lio/nav_workspace/maps/kitchen_pro.pcd` 和 `/home/unitree/maps/test_001_level.pcd` 正确传给 `keyDemo_changemap`。
- 已测试：不存在的地图路径会被 `step1_start_slam.sh` 拒绝，不会继续启动。
- 已测试：`--dry-run` 不会启动 SLAM，也不会在 `/tmp` 留临时脚本。
- 未测试：没有实机按 `a` 验证所有目录都被宇树二进制接受。
- 如果按 `a` 后出现 `The directory is illegal`，把地图放到 `/home/unitree/maps/`，再用这个路径启动。

```bash
cp /home/unitree/go2-fast-lio/nav_workspace/maps/kitchen_pro.pcd /home/unitree/maps/kitchen_pro.pcd
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step1_start_slam.sh --maps /home/unitree/maps/kitchen_pro.pcd
```

启动后会依次拉起 3 个 tmux 会话：

- `go2_slam`
- `go2_lidar`
- `go2_relocation`

脚本最后会自动进入 `go2_relocation` 会话，并提示直接按 `a`。

实际操作：

1. 等待脚本完成启动。
2. 进入重定位界面后按一次 `a`。
3. 如果需要退出 tmux 界面，按 `Ctrl+B`，松开后再按 `D`。

重新查看各进程：

```bash
tmux attach -t go2_slam
tmux attach -t go2_lidar
tmux attach -t go2_relocation
```

### 第三步：判断重定位是否成功

重定位成功后，`/slam_info` 会持续给出当前位姿，`get_pose.py` 可以读到非零位姿。

推荐直接执行封装脚本：

```bash
# Jetson 主机终端执行
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step2_check_relocalization.sh
```

说明：

- `step2_check_relocalization.sh` 内部会自动加载 `/opt/ros/foxy/setup.bash`。
- 不要只手动 `source /opt/ros/foxy/setup.bash` 后检查 `/slam_info`，这种环境下可能出现 `bad_alloc` 或读不到话题。
- 如果 `step2` 报 `No valid pose received from /slam_info`，先回到 `go2_relocation` 看按 `a` 后是否已经显示 `Successfully started relocation`。

也可以直接读取原始位姿脚本：

```bash
# Jetson 主机终端执行
source /opt/ros/foxy/setup.bash
export PYTHONPATH=/opt/ros/foxy/lib/python3.8/site-packages:${PYTHONPATH:-}
/usr/bin/python3 /home/unitree/unitree_sdk2_python/navi_update/get_pose.py simple
```

预期输出格式：

```text
# x y z q_x q_y q_z q_w
-17.758800 10.349400 -2.438880 0.086201 0.088261 -0.650751 0.749201
```

判断标准：

- 能稳定输出 7 个数值。
- `x` 和 `y` 不是一直为 `0`。
- 机器人轻微移动后，再次读取时位姿会跟着变化。

也可以直接看 `/slam_info`：

```bash
# Jetson 主机终端执行
source /opt/ros/foxy/setup.bash
ros2 topic echo /slam_info
```

如果迟迟没有有效位姿：

1. 回到 `go2_relocation` 会话。
2. 重新按 `a`。
3. 适当挪动机器人后再试。

注意：

- 现在这套地图存在地面倾斜问题，`z` 出现 `-2.xx` 这类值是正常现象，不单独作为失败依据。

### 第四步：重定位成功后记录地图中的点

必须先完成重定位，再采点。否则记录下来的坐标没有意义。

操作步骤：

1. 手动把机器人移动到目标点。
2. 执行 `step3_record_nav_point.sh` 采样。
3. 脚本会把输出的 7 个数值写入 [nav_points_record.yaml](/home/unitree/go2-fast-lio/nav_workspace/nav_points_record.yaml:1)。
4. 如果某个地点需要多段路径点，就按路径顺序记录多个 pose。

记录单点：

```bash
# Jetson 主机终端执行
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step3_record_nav_point.sh --name 吧台 --mode overwrite --note "吧台停靠点"
```

同一地点追加路径点：

```bash
# Jetson 主机终端执行
bash step3_record_nav_point.sh --name 前台 --mode overwrite --note "前台路径点"
bash step3_record_nav_point.sh --name 前台 --mode append
```

这一行 7 个值对应顺序固定为：

```text
[x, y, z, qx, qy, qz, qw]
```

记录规则：

- 单点目标：在该地点下只保留 1 个 pose。
- 多点导航路径：在同一地点的 `poses` 下按通过顺序记录多个 pose。
- 每采一个点，建议连续采 2 到 3 次，选择最稳定的一组。

### 第五步：把点位写入 yml 记录文件

本仓库新增的记录文件是：

- [nav_points_record.yaml](/home/unitree/go2-fast-lio/nav_workspace/nav_points_record.yaml:1)

推荐用法：

1. 先把现场采到的结果完整写到这个 yml。
2. 在 `note` 字段里写清楚这个点的含义，例如“吧台停靠点”“前台中间过渡点”。
3. 确认无误后，再同步到实际运行使用的 JSON 配置。

示例：

```yaml
map_name: kitchen_pro.pcd
locations:
  吧台:
    poses:
      - [3.016720, -1.655370, 0.082426, 0.107421, 0.032942, -0.844297, 0.523964]
      - [3.452390, -2.279980, 0.086270, 0.057025, 0.098608, -0.436829, 0.892303]
    note: "吧台路径点，按接近吧台的顺序排列"
```

### 第六步：把 yml 中的点同步到运行配置

当前运行时真正读取的仍然是：

- `/home/unitree/unitree_sdk2_python/agent/config/client_config.json`

因此完成 yml 记录后，执行：

```bash
# Jetson 主机终端执行
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step4_sync_nav_points.sh --dry-run
bash step4_sync_nav_points.sh
```

如果你想维护多套导航配置，可以指定另一个 JSON。这个 JSON 必须先存在，建议先从原始配置复制一份：

```bash
# Jetson 主机终端执行
mkdir -p /home/unitree/go2-fast-lio/nav_workspace/configs
cp /home/unitree/unitree_sdk2_python/agent/config/client_config.json \
  /home/unitree/go2-fast-lio/nav_workspace/configs/client_config_kitchen.json
```

然后把 yml 点位同步到这份配置：

```bash
# Jetson 主机终端执行
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step4_sync_nav_points.sh \
  --client-config /home/unitree/go2-fast-lio/nav_workspace/configs/client_config_kitchen.json
```

脚本会把对应地点的 `poses` 同步到 JSON 里的：

```json
"location_poses_mapping": {
  "吧台": [
    [3.01672, -1.65537, 0.0824255, 0.107421, 0.032942, -0.844297, 0.523964],
    [3.45239, -2.27998, 0.0862699, 0.0570252, 0.0986078, -0.436829, 0.892303]
  ]
}
```

同步原则：

1. yml 是采点记录源。
2. `client_config.json` 是当前运行配置。
3. 两边的地点名称必须一致，例如 `吧台`、`起点`、`桌子一`。
4. 如果是另一套地图，按实际情况写到对应的映射块，例如 `sf_location_poses_mapping`。

### 第七步：启动现有多点导航

完成重定位并同步好点位后，再启动当前客户端：

```bash
# Jetson 主机终端执行
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step5_run_nav_client.sh
```

如果要像地图一样手动指定导航配置 JSON：

```bash
# Jetson 主机终端执行
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step5_run_nav_client.sh \
  --config /home/unitree/go2-fast-lio/nav_workspace/configs/client_config_kitchen.json
```

说明：

- 原始 `client_recon_v1.py` 里配置路径是硬编码的。
- `step5_run_nav_client.sh --config` 会运行一个临时客户端副本，把配置路径替换成你指定的 JSON。
- 这个过程不会修改 `/home/unitree/unitree_sdk2_python/navi_update/client_recon_v1.py`。
- `step4 --client-config` 和 `step5 --config` 应该指向同一个 JSON。

当前代码会从 `client_config.json` 读取：

- `location_poses_mapping`
- 地点名称对应的 `poses_list`

然后通过 `simple_nav_v3 start <temp_json> <speed> <mode> <loop>` 发起导航。

因此只要：

1. 重定位成功。
2. 地点名称配置正确。
3. 点位顺序正确。

现有多点导航就可以直接使用 FAST-LIO 建好的地图。

## 4. 推荐现场操作顺序

建议严格按下面顺序执行：

1. 用 FAST-LIO 建图并导出 `.pcd`。
2. 确认 `.pcd` 已经位于 `/home/unitree/go2-fast-lio/nav_workspace/maps/kitchen_pro.pcd`。
3. 执行 `step1_start_slam.sh` 并在重定位界面按 `a`。
4. 执行 `step2_check_relocalization.sh` 确认已经拿到稳定位姿。
5. 手动移动机器人到目标位置，用 `step3_record_nav_point.sh` 逐个采样。
6. 执行 `step4_sync_nav_points.sh` 同步到 `client_config.json`。
7. 执行 `step5_run_nav_client.sh` 验证多点导航。

## 5. 常用命令汇总

### 启动重定位

```bash
# Jetson 主机终端执行
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step1_start_slam.sh --maps /home/unitree/go2-fast-lio/nav_workspace/maps/kitchen_pro.pcd
```

启动前检查地图路径：

```bash
# Jetson 主机终端执行
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step1_start_slam.sh --dry-run --maps /home/unitree/go2-fast-lio/nav_workspace/maps/kitchen_pro.pcd
```

### 查看当前位姿

```bash
# Jetson 主机终端执行
source /opt/ros/foxy/setup.bash
export PYTHONPATH=/opt/ros/foxy/lib/python3.8/site-packages:${PYTHONPATH:-}
/usr/bin/python3 /home/unitree/unitree_sdk2_python/navi_update/get_pose.py simple
```

### 采样一次位姿并只取最后结果

```bash
# Jetson 主机终端执行
source /opt/ros/foxy/setup.bash
export PYTHONPATH=/opt/ros/foxy/lib/python3.8/site-packages:${PYTHONPATH:-}
timeout 5 /usr/bin/python3 /home/unitree/unitree_sdk2_python/navi_update/get_pose.py simple 2>/dev/null | tail -1
```

### 查看重定位话题

```bash
# Jetson 主机终端执行
source /opt/ros/foxy/setup.bash
ros2 topic echo /slam_info
```

### 启动现有导航客户端

```bash
# Jetson 主机终端执行
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step5_run_nav_client.sh
```

指定导航配置：

```bash
# Jetson 主机终端执行
cd /home/unitree/go2-fast-lio/nav_workspace/step_scripts
bash step5_run_nav_client.sh --config /home/unitree/go2-fast-lio/nav_workspace/configs/client_config_kitchen.json
```
