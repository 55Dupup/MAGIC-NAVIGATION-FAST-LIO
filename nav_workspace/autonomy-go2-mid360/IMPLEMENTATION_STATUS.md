# 实现状态

本文只记录当前实现了什么、已经检查了什么、主要风险和后续要改哪里。具体运行命令见 `OPERATION_GUIDE.md`。

## 当前实现

- 已集成 `jizhang-cmu/autonomy_stack_go2` 的 `foxy-humble` 分支。
- 已提供独立 ROS2 Humble Docker 环境运行导航层。
- 已添加本地 bridge 包 `mid360_go2_nav_bridge`。
- 已添加 FAST-LIO 到 autonomy_stack_go2 的 topic bridge：
  - `/Odometry_loc` -> `/state_estimation`
  - `/cloud_registered_1` -> `/registered_scan`
- 已添加本地导航 launch，默认 `real_robot:=false`：
  - `terrain_analysis`
  - `localPlanner`
  - `pathFollower`
- 已添加全局重定位链路：
  - `open3d_loc/global_localization_node`
  - PCD 地图输入
  - `map -> odom`
  - `odom -> camera_init`
- 已添加 `/initialpose` 转换桥：
  - RViz `/initialpose` 表示 `map->base_link`
  - Open3D 实际需要 `map->odom`
  - `global_nav_frame_bridge` 负责转换后发布到 `/open3d_initialpose`
  - 全局重定位启动时默认自动发布地图原点初始位姿
  - 可通过 `start_nav.sh --initialpose X Y Z YAW` 指定启动初始位姿
- 已添加全局路线规划链路：
  - FAR planner 接收 `/goal_point`
  - FAR planner 输出 `/way_point_global`
  - bridge 转换为 `camera_init` 下的 `/way_point`
  - `localPlanner` 继续消费局部 `/way_point`
- 已新增 autonomy 专用 FAST-LIO 感知配置：
  - `nav_workspace/fast-lio-mid360/config/unitree_go2_fastlio_autonomy.yaml`
  - `nav_workspace/autonomy-go2-mid360/scripts/start_fastlio_unitree_autonomy_for_nav.sh`
  - 不替换原 `unitree_go2_fastlio.yaml` 和原启动脚本
- 当前容器分工已调整：
  - `mid360_go2_nav_humble`：autonomy 集成容器，运行 autonomy 专用 FAST-LIO、Open3D 重定位、全局/局部规划
  - `unitree_humble_nav`：保留给原来的稳定 FAST-LIO/宇树原厂流程
  - autonomy 专用 FAST-LIO runtime 写入 `/workspace/autonomy-go2-mid360/fast-lio-runtime`
  - `unitree_go2_fastlio_autonomy.yaml` 的 `map_file_path` 已改为 `/workspace/autonomy-go2-mid360/fast-lio-runtime/output/autonomy_current_map.pcd`

## 坐标关系

本地导航模式：

```text
map
└── camera_init
    └── aft_mapped
        └── sensor
            ├── vehicle
            └── camera
```

全局重定位模式：

```text
map
└── odom
    └── camera_init
        └── aft_mapped
            └── sensor
                └── vehicle
```

默认兼容外参：

```text
config: nav_workspace/fast-lio-mid360/config/unitree_go2_fastlio.yaml
translation = [0.1870, 0.0, 0.0803]
rotation = identity
```

autonomy 专用候选外参：

```text
config: nav_workspace/fast-lio-mid360/config/unitree_go2_fastlio_autonomy.yaml
translation = [0.1870, 0.0, 0.0803]
rotation = R_y(+0.226 rad) ~= +12.95 deg
```

`localPlanner` 和 `pathFollower` 会从 `/state_estimation` 中减去 `sensorOffsetX/Y` 来恢复 `vehicle` 位姿。因此 bridge 当前不会再给 `/state_estimation` 额外加 `0.187 m`，避免重复偏移。

## 导航能力

当前代码链路设计目标：

```text
FAST-LIO 局部里程计/点云
-> Open3D 全局重定位到 PCD map
-> FAR planner 生成全局中间航点
-> bridge 转换为局部航点
-> localPlanner/pathFollower 局部避障和速度输出
```

理论上支持在全局 PCD map 中给 `/goal_point`，让狗根据全局路线和局部避障走过去。

这属于已知地图中的定点导航：重定位成功后，在 `map` 坐标系发布目标点，FAR planner 生成全局中间航点，`localPlanner/pathFollower` 负责局部路径和速度输出。目标点不必须提前记录，但记录过的目标点更适合复现测试。

当前状态应理解为：链路已接通，静态/假数据和无运动测试已通过；真实狗运动闭环还没有完成验证。

## 已验证

- 脚本 shell 语法检查通过。
- bridge Python 节点和 launch 文件语法检查通过。
- `mid360_go2_nav_bridge` 在 ROS2 Humble 容器内构建通过。
- `open3d_loc` 在 ROS2 Humble 容器内构建通过。
- Dockerfile 已补充 Open3D 链接所需依赖 `liblapacke-dev`。
- `ros2 launch mid360_go2_nav_bridge fastlio_mid360_nav.launch.py --show-args` 可解析。
- 2026-05-28 验证 `mid360_go2_nav_humble` 可以订阅实时 MID360 原始数据：
  - `/unitree/slam_lidar/points` 约 `19.9 Hz`
  - `frame_id: livox_frame`
  - 字段包含 `x/y/z/intensity/ring/time`
  - 单帧约 `10080` 点
  - `/unitree/slam_lidar/imu` 约 `200 Hz`
- 2026-05-28 用实时 MID360 数据短时间启动 FAST-LIO，不移动狗、不保存地图：
  - 容器：`unitree_humble_nav`
  - 配置：`/workspace/nav_ws/fast-lio-mid360/config/unitree_go2_fastlio.yaml`
  - `/Odometry_loc` 约 `19.9 Hz`
  - `/cloud_registered_1` 约 `19.9 Hz`
  - `camera_init -> body` TF 正常
  - 示例静止位姿约 `[0.037, 0.027, -0.009]`，姿态接近 identity
- 2026-05-28 检查保存地图 `/home/unitree/maps/company_001-test_20260519_195622.pcd`：
  - 点数 `138681`
  - XYZ 范围约 `x=[-31.674,45.874]`、`y=[-24.951,43.736]`、`z=[-3.136,14.747]`
  - 主要近水平面倾角约 `12-14 deg`
  - 下包络面拟合倾角约 `13.3 deg`
  - 判断：旧地图明显倾斜
- 2026-05-28 检查实时 FAST-LIO 点云水平性：
  - 当前 `extrinsic_R: identity` 下，近水平面约 `9.8-10.7 deg`
  - 临时 A/B：`R_y(+10 deg)` 约 `3.2 deg`
  - 临时 A/B：`R_y(+13 deg)` 约 `6.3 deg`
  - 临时 A/B：负方向补偿更差
  - 判断：正方向 pitch 补偿明显优于 identity/负方向，但最终角度还需标定
- 2026-05-28 检查宇树原厂配置：
  - `pl_mapping/mid360.yaml` Go2 段：`pose_imu_lidar: [1.0, 0.0, 0.0, 0.0, -0.011, -0.02329, 0.04412]`
  - `pl_relocation/mid360.yaml` Go2 段：`pose_imu_lidar: [1.0, 0.0, 0.0, 0.0, 0.1870, 0.0, 0.0803]`
  - 二者四元数均为 identity
  - `gridmap_config/config.yaml` 中 Go2 MID360 局部栅格使用 `T_Dog2lidar: [0.0, 0.0, 0.0, 0.0, 0.226, 0.0]`
  - 判断：原厂全局 PCD/重定位更像保持同一倾斜坐标系；局部 gridmap 另有固定 pitch 补偿
- 2026-05-28 验证实时 FAST-LIO 输出接入本地导航链路：
  - 参数：`real_robot:=false`、`route_planner:=false`、`global_localization:=false`
  - `/state_estimation` 可订阅
  - `/registered_scan` 可订阅
  - `/terrain_map` 可订阅
  - `camera_init -> aft_mapped` TF 正常
  - `sensor -> vehicle = [-0.187, 0.0, 0.0]`
  - `map -> vehicle` 连通
  - 没有发送 `/goal_point`
  - 没有启用真实运动控制
- 离线 PCD 无运动启动测试通过：
  - `/state_estimation` 有输出
  - `/registered_scan` 有输出
  - `fastlio_topic_bridge`、`localPlanner`、`pathFollower`、`terrainAnalysis` 能启动
- 本地 TF 偏移测试通过：
  - 假设 `/Odometry_loc` 中 MID360/IMU 位姿为 `x=1.187`
  - `sensor -> vehicle = -0.187`
  - 最终 `map -> vehicle = x=1.000`
- 全局重定位 TF 换算测试通过：
  - 当前 odom 下 `base_link = x=1.0`
  - RViz `/initialpose` 给 `map->base_link = x=10.0`
  - bridge 输出 `/open3d_initialpose = map->odom = x=9.0`
  - 最终 `map->vehicle = x=10.0`
- 2026-05-28 新增 autonomy FAST-LIO 配置后的检查：
  - 新脚本 shell 语法通过
  - 新脚本 `--dry-run` 通过
  - 新 YAML 本地解析通过
  - 新 YAML 在 `unitree_humble_nav` 容器内可见并可解析
  - 检查后没有遗留 FAST-LIO 或导航进程
- 2026-06-05 修复 FAST-LIO 建图脚本保存阶段问题：
  - `docker exec ... bash -s` 需要 `-i`，否则 heredoc 不会传进容器
  - 修复后 `map_file_path` 可从容器内配置解析
  - 脚本语法检查通过
- 2026-06-05 修复 FAST-LIO 建图脚本等待阶段问题：
  - 在 `set -u` helper 脚本中 source `install/setup.bash` 前临时 `set +u`，避免 `COLCON_TRACE: unbound variable`
  - 启动前检查 FAST-LIO 残留进程时忽略 `STAT=Z` 的 defunct 僵尸进程
  - 脚本语法检查和 autonomy 启动脚本 `--dry-run` 通过
- 2026-06-05 code review 后继续加固 FAST-LIO 建图脚本：
  - autonomy 专用启动脚本默认输出到 `/home/unitree/maps`
  - 保存地图前将旧容器内 PCD 移到备份，`/map_save` 失败或保存为空时恢复旧图
  - pid 文件冲突检查忽略 defunct 僵尸进程，并清理 stale pid 文件
  - `/map_save`、`/Odometry_loc`、`/cloud_registered_1` 使用同一个 `SERVICE_TIMEOUT` deadline 轮询
  - 等待或保存失败时会清理 mapping/driver，再退出报错
- 2026-06-05 将 `unitree` 用户加入 `docker` 组：
  - `id unitree` 已显示包含 `docker`
  - FAST-LIO 建图、导航启动、容器创建脚本默认 Docker 命令统一为 `docker`
  - 当前已打开终端需要重新登录或执行 `newgrp docker` 后组权限才会生效
- 2026-06-05 调整 autonomy 容器分工：
  - `start_fastlio_unitree_autonomy_for_nav.sh` 默认使用 `mid360_go2_nav_humble`
  - `fast_lio_mid360_mapping.sh` 增加 `CONTAINER_FASTLIO_RUNTIME_DIR`
  - autonomy 专用 FAST-LIO 不再默认写入 `/workspace/nav_ws/fast-lio-mid360/output`
  - Dockerfile 增加 `ros-humble-foxglove-bridge`；已有旧容器需要重建后才能在 `mid360_go2_nav_humble` 内直接启动 Foxglove bridge
- 2026-06-09 检查并补装当前运行的 `mid360_go2_nav_humble`：
  - 初始检查 `ros2 pkg prefix foxglove_bridge` 返回 `Package not found`
  - 已在当前容器内执行 `apt-get install -y ros-humble-foxglove-bridge`
  - 复查 `ros2 pkg prefix foxglove_bridge` 返回 `/opt/ros/humble`
  - 复查 `ros2 pkg executables foxglove_bridge` 返回 `foxglove_bridge foxglove_bridge`
  - 短启动验证：`foxglove_bridge` 可以启动，并监听 `9001`
  - 仅 source `/opt/ros/humble` 手动启动时，宇树自定义 topic 会出现 schema 加载报错；source `/workspace/autonomy-go2-mid360/workspace/install/setup.bash` 后可找到 `unitree_go` 和 `unitree_api`
  - 注意：这是对当前容器的补装；如果以后删除并重建容器，需要确认镜像已包含该包，或重新安装
- 2026-06-09 精简 `OPERATION_GUIDE.md`：
  - 改为 Step 0 到 Step 6 的直接操作流程
  - 每一步标明宿主机、容器或不同终端
  - autonomy 建图、重定位、导航命令统一使用 `mid360_go2_nav_humble`
- 2026-06-09 修复 Foxglove 后连接看不到 `/map`：
  - 原因：`open3d_loc` 启动时只发布一次 `/map`，QoS 为 `VOLATILE`，Foxglove 后订阅会错过地图消息
  - 修改 `nav_workspace/src/fast/open3d_loc/src/global_localization.cpp`
  - `/map` publisher 改为 `transient_local`
  - 增加 2 秒定时重发粗地图
  - 已在 `mid360_go2_nav_humble` 内重建 `open3d_loc`
  - 已运行中的 `global_localization_node` 需要重启 `start_nav.sh` 后才使用新二进制
- 2026-06-27 修复 Foxglove 暴露宇树原厂自定义 DDS 话题导致的 schema 报错：
  - 现象：Foxglove 显示 `/utlidar/voxel_map_compressed`、`/config_change_status` 为 `Unsupported message encoding`
  - 原因：FAST-LIO 建图启动的 `foxglove_bridge` 原来使用全量 topic 白名单 `.*`，会把机器人 DDS 域内的宇树自定义消息一起暴露给 Foxglove
  - 修改 `nav_workspace/src/fast/FAST_LIO/launch/mapping.launch.py`，FAST-LIO 的 Foxglove bridge 只暴露 FAST-LIO/导航相关标准话题
  - 修改 `workspace/src/mid360_go2_nav_bridge/launch/fastlio_mid360_nav.launch.py`，导航 launch 增加同样的过滤版 Foxglove bridge
  - 修改 `scripts/start_nav.sh`，增加 `--foxglove` / `--no-foxglove`
  - 注意：同一时间只能有一个 Foxglove bridge 监听 `9001`；建图脚本已启动 Foxglove 时，导航脚本不要再加 `--foxglove`
- 2026-06-29 调整 autonomy 专用 FAST-LIO 点云抽点参数：
  - 修改 `nav_workspace/fast-lio-mid360/config/unitree_go2_fastlio_autonomy.yaml`
  - `point_filter_num` 从 `3` 改为 `2`，让 autonomy 建图/实时注册点云稍密
  - 原稳定配置 `unitree_go2_fastlio.yaml` 保持 `point_filter_num: 3` 不变
  - 已做脚本和 launch 静态检查；修改配置后需要重新启动 FAST-LIO 建图进程才会生效
- 2026-06-05 使用 autonomy 专用外参成功保存小区域地图：
  - 输出：`/home/unitree/maps/autonomy_go2_mid360_test_20260605_173346.pcd`
  - 点数：`56129`
  - 文件大小：约 `1.8 MB`
  - XYZ 范围约 `x=[-22.313,42.262]`、`y=[-27.792,28.659]`、`z=[-3.119,5.571]`
  - Open3D 平面拟合结果：主要水平候选面倾角约 `4.6-5.0 deg`
  - 同算法复测旧图 `/home/unitree/maps/company_001-test_20260519_195622.pcd`：主要水平候选面倾角约 `13.0-13.7 deg`
  - 判断：`R_y(+0.226 rad)` 明显改善倾斜，但当前小图仍有约 `5 deg` 残余倾斜，角度还需要继续微调

## 未完全验证

- 实时 FAST-LIO 长时间稳定性。
- `unitree_go2_fastlio_autonomy.yaml` 中 `R_y(+0.226 rad)` 的最终角度。
- 使用 autonomy 专用外参重新建出的 PCD 已明显改善，但是否能达到最终导航所需水平度仍需继续标定。
- Open3D 在新 PCD 地图上的真实重定位稳定性。
- FAR planner 在真实地图中的可通行图质量。
- `/goal_point -> /way_point_global -> /way_point -> /cmd_vel` 的完整实机闭环。
- `/cmd_vel -> /api/sport/request` 的真实狗运动效果。
- RViz 直接点目标是否能发布到当前使用的 `/goal_point`。如果 RViz 只发布 `/goal_pose`，需要增加 `/goal_pose -> /goal_point` 转换。

### 2026-06-09 目标点规划/控制检查

检查环境：`mid360_go2_nav_humble`，`start_nav.sh --global-localization --route-planner --no-real-robot --max-speed 0.2`。

检查结果：

- 当前 `pathFollower` 在 `autonomyMode=false` 时会持续发布 0 `/cmd_vel`，即使 `/way_point` 已经存在。
- 已调整 `start_nav.sh` 和 `fastlio_mid360_nav.launch.py`，默认传入 `autonomy_mode:=true`；如需恢复上游手柄/速度门控，使用 `--manual-speed-gate`。
- 近距离目标测试可产生 `/way_point_global`、`/way_point`，并输出非零 `/cmd_vel.angular.z`，说明局部规划和控制输出链路可工作。
- 用户给定目标 `x=0.1934357307, y=2.1378745950, z=-0.2009190334` 在当前测试状态下没有产生 `/way_point_global`，因此还不能用该点直接进入真实运动。
- 狗坐下会影响记录到的 `z`，但 FAR planner 会根据地形调整目标高度；目标记录优先关注 `map` 下的 `x/y` 和重定位是否稳定。
- `/map` 可视化发布已改为 transient_local，并只在启动后约 30 秒内每 2 秒补发一次，避免大地图在 Foxglove 中长期重复发布导致卡顿。
- 站立状态目标 `x=5.2364309179, y=0.3807828106, z=-0.4820227298` 测试通过规划输出：`/way_point_global`、`/way_point` 正常，`/cmd_vel.angular.z=-1.396 rad/s`、线速度为 0，表示控制器当前先原地转向；`is_real_robot=false` 下 3 秒内未观察到 `/api/sport/request` 实际消息。
- 代码审查发现 `--max-speed` 不限制原地转向角速度；已新增 `--max-yaw-rate` 并传入 `pathFollower.maxYawRate`，默认 `30 deg/s`，用于第一次真实运动降低转向风险。
- 真实运动摇头问题检查：宿主机存在一个旧的 `start_nav.sh --real-robot --max-speed 0.1` 进程，启动命令没有包含新增的 `max_yaw_rate`，因此仍可能按旧上限 `80 deg/s` 原地转向；已手动停止该真实导航进程。`/api/sport/request` 当前仍显示多个 Unitree 裸 DDS 端点，但 5 秒内未观察到实际消息；后续真实运动前应先确认没有其它控制源持续发布。
- 2026-06-09 no-real 复测：`terrainAnalysis.noDataObstacle=false` 已生效，原先站立静止时前方 `x=0.3..1.8m, |y|<=0.9m` 的 no-data 虚拟障碍墙消失；当前采样仅 12 个前方地形点，`intensity>=1` 的障碍点为 0。
- 同次复测确认 TF bridge 未反向：`/way_point_global -> /way_point` 成对采样误差约 `0.05m`，转换方向正确。
- 站立目标复测时 FAR planner 会给出偏右的全局中间航点，例如 `/way_point_global=(2.284,-1.407,0.155)`，转换后 `/way_point=(2.314,-2.441,0.346)`，局部方向约 `-46.5 deg`，因此 `pathFollower` 输出 `angular.z=-0.262 rad/s` 是在跟随 FAR 的偏右子目标。
- 旁路 FAR 直接向 `/way_point` 发布 `camera_init` 前方点 `(2.0,0.0,0.0)` 时，`/cmd_vel` 输出 `linear.x=0.04, angular.z=0`，说明 localPlanner/pathFollower 对正前方局部目标可正常直行。当前剩余风险集中在 FAR 全局子目标/可通行图质量，而不是底层速度跟踪或 TF bridge。
- 2026-06-09 再次 no-real 复测当前调整后的规划/控制链路：
  - 启动参数：`--global-localization --route-planner --no-real-robot --max-speed 0.05 --max-yaw-rate 15.0 --no-rviz`
  - 重定位置信度稳定在约 `0.896..0.907`，最后约 `0.903`
  - `baselink2map ~= (-0.461, 0.656, -0.169)`，yaw 约 `5.9 deg`
  - 目标 `x=5.2364, y=0.3808, z=-0.4820` 发布后，FAR 输出 `/way_point_global ~= (5.236, 0.381, -0.089)`
  - bridge 输出 `/way_point ~= (5.486, -0.875, 0.022)`，局部目标方向约 `-9.1 deg`
  - `/path` 在 `vehicle` 坐标系前段为直线，前 8 个点 heading 均约 `0 deg`
  - `/cmd_vel` 采样：`linear.x ~= 0.059..0.060 m/s`，`linear.y ~= -0.009..0.003 m/s`，`angular.z ~= -0.219..0.082 rad/s`，最后 `angular.z ~= 0.014 rad/s`
  - `is_real_robot=false` 下 3 秒内未观察到 `/api/sport/request` 实际消息
  - 注意：`--max-speed 0.05` 时 `/cmd_vel.linear.x` 可轻微达到约 `0.06 m/s`，原因是 `pathFollower` 按 `maxAccel/100` 离散加减速，当前没有对最终 `vehicleSpeed` 做严格上限钳制；真实低速测试时建议预留该余量，或后续增加最终速度 clamp。
- 2026-06-09 对新目标 `x=3.2546267998, y=-0.7578469772, z=-0.1534331860` 做 no-real 复测：
  - 启动参数：`--global-localization --route-planner --no-real-robot --max-speed 0.05 --max-yaw-rate 10.0 --no-rviz`
  - 重定位置信度 158 个样本均为 `1.000`
  - `baselink2map ~= (0.357, -0.036, -0.118)`，yaw 约 `-5.7 deg`，到目标平面距离约 `2.99m`
  - `/way_point_global` 已到目标附近，`/way_point` 转到 `camera_init` 后约 `(3.183, -0.430, -0.020)`，局部方向约 `-7.7 deg`
  - `/path` 在 `vehicle` 坐标系前段为直线，前 10 个点 heading 均约 `0 deg`
  - `/cmd_vel` 300 个样本均为非零低速前进：`linear.x ~= 0.060 m/s`，`linear.y ~= -0.002..0.002 m/s`，`angular.z ~= -0.057..0.053 rad/s`，最后接近 `0 rad/s`
  - `is_real_robot=false` 下未观察到 `/api/sport/request`，测试后已清理残留导航节点，仅保留 FAST-LIO 相关进程。
- 2026-06-22 新增可选 `--auto-disarm-on-goal`：
  - 默认关闭，旧命令行为不变。
  - 启用后，`pathFollower` 订阅 `/goal_point` 和 `/far_reach_goal_status`。
  - 启动后未收到 goal 时不发布 `/api/sport/request`；收到 `/goal_point` 后先等待新的 `/way_point` 和新的 `/path`，再 arm 真实运动控制，避免新目标刚发布时沿用旧 `/path`。
  - `/far_reach_goal_status=true` 后，连续发布 `autoDisarmStopPublishCount` 次 `StopMove`，随后停止发布 `/api/sport/request`，直到下一个 `/goal_point`。
  - 已编译验证 `local_planner` 和 `mid360_go2_nav_bridge` 通过；代码审查后修正了新目标 re-arm 前可能短暂复用旧路径的风险；尚未做实机到达后释放控制验证。

真实运动前仍需确认：

```text
/way_point_global 正常
/way_point 正常
/cmd_vel 方向和幅值合理
```

## 主要注意事项

### 外参和地图必须成套

FAST-LIO 的 `extrinsic_R/T` 会影响建图坐标系。修改外参后必须重新建图。不要把旧 PCD 与新外参混用。

旧兼容配置保留：

```text
nav_workspace/fast-lio-mid360/config/unitree_go2_fastlio.yaml
```

autonomy 专用候选配置：

```text
nav_workspace/fast-lio-mid360/config/unitree_go2_fastlio_autonomy.yaml
```

### 当前局部避障不是宇树原厂 gridmap

当前链路是：

```text
/registered_scan -> terrain_analysis -> /terrain_map -> localPlanner -> /path -> pathFollower -> /cmd_vel
```

它没有使用宇树原厂 `gridmap_config/config.yaml` 中的 `T_Dog2lidar: [0,0,0,0,0.226,0]`。因此更合理的方向是在 FAST-LIO 感知阶段得到已校准的点云和地图，让后续重定位、规划、局部避障都处在同一正确坐标系。

### `/initialpose` 需要谨慎

Open3D 更像“有初值的地图对齐”，不是完全不依赖初值的全局检索。`/initialpose` 给错会导致后续全局导航整体偏移。

后续建议：

- 保存上一次 `map->vehicle`，下次自动恢复为初值。
- 增加多候选初值重定位。
- 必要时引入 Scan Context、FPFH/RANSAC、NDT 或人工标志物辅助粗定位。

### 真实运动前必须先无运动验证

先验证：

```text
点云水平性
TF 连通和方向
重定位置信度
/way_point 方向
/cmd_vel 方向和幅值
```

再低速、短距离开启 `--real-robot`。

## 修改位置

调整 FAST-LIO 旧兼容配置：

```text
nav_workspace/fast-lio-mid360/config/unitree_go2_fastlio.yaml
```

调整 autonomy 专用 FAST-LIO 外参：

```text
nav_workspace/fast-lio-mid360/config/unitree_go2_fastlio_autonomy.yaml
```

启动旧 FAST-LIO：

```text
nav_workspace/autonomy-go2-mid360/scripts/start_fastlio_unitree_for_nav.sh
```

启动 autonomy 专用 FAST-LIO：

```text
nav_workspace/autonomy-go2-mid360/scripts/start_fastlio_unitree_autonomy_for_nav.sh
```

调整导航 launch、TF、topic bridge：

```text
nav_workspace/autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/launch/fastlio_mid360_nav.launch.py
nav_workspace/autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/mid360_go2_nav_bridge/fastlio_topic_bridge.py
nav_workspace/autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/mid360_go2_nav_bridge/global_nav_frame_bridge.py
```

调整启动参数默认值：

```text
nav_workspace/autonomy-go2-mid360/scripts/start_nav.sh
```

调整 Open3D 重定位参数：

```text
nav_workspace/src/fast/open3d_loc/config/loc_param_go2.yaml
```

## 2026-06-30 点云密度回退到低负载配置

为降低 FAST-LIO、Open3D 重定位和 Foxglove 可视化负载，当前采用接近原稳定 FAST-LIO 的低密度配置：

```text
nav_workspace/fast-lio-mid360/config/unitree_go2_fastlio_autonomy.yaml
  point_filter_num: 2
  filter_size_surf: 0.5
  filter_size_map: 0.5
  dense_publish_en: false

nav_workspace/src/fast/open3d_loc/config/loc_param_go2.yaml
  voxelsize_coarse: 0.3
  voxelsize_fine: 0.3
```

说明：

- `point_filter_num=2` 和 `dense_publish_en=false` 会减少实时注册点云和累计地图的体量，同时比 `3` 稍密。
- `filter_size_surf/map=0.5` 降低建图计算和 `/Laser_map_1` 单帧大小。
- Open3D `/map` 和持续 ICP 使用 `0.3m` voxel，加载更快，fitness 数值会和 `0.2m` 配置不同，不能直接横向比较。
- 如果后续短时需要更密的地图，可单独降低这些值，但需要同步重启建图/重定位并关注 CPU 与 Foxglove 负载。

## 2026-06-30 Foxglove `/map` 不显示修复

现象：

- ROS2 中 `/map` 正常存在，`Publisher count=1`，publisher 是 `/global_loc_node`。
- Foxglove 中看不到 `/map`、重定位地图和实时点云。
- `/root/.ros/log/*foxglove*` 中持续出现：

```text
Exception thrown in rosgraphPollThread: bad optional access
```

原因：

- 当前运行的 `foxglove_bridge` 是 FAST-LIO 建图 launch 启动的未过滤 bridge，只配置了 `port/address`。
- 它会扫描 DDS/ROS graph 中的全部 topic，遇到宇树自定义或异常 schema 后 rosgraph 轮询失败，导致 `/map` 等后续话题不能稳定暴露给 Foxglove。
- 这不是 `/map` 没发布，也不是 `far_planner` 直接导致。

修改：

```text
nav_workspace/src/fast/FAST_LIO/launch/mapping.launch.py
nav_workspace/autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/launch/fastlio_mid360_nav.launch.py
```

- 2026-06-30 复查确认：完全取消 Foxglove topic 白名单会让 `foxglove_bridge`
  在扫描宇树自定义/DDS topic 时持续报
  `Exception thrown in rosgraphPollThread: bad optional access`，导致 `/map`
  虽然 ROS2 中存在但 Foxglove 不稳定显示。
- 当前改为“宽白名单稳定模式”：保留 FAST-LIO、Open3D、FAR、TF、目标点、
  规划可视化和部分已知标准消息的 Unitree 点云/里程计话题；默认排除
  `/api/*`、`/config_change_status`、`/utlidar/voxel_map_compressed`
  等易触发 Foxglove schema/graph 异常的自定义话题。

验证：

- 修改后的 launch 文件在当前容器 install 中是 symlink，可直接生效。
- 手动重启 filtered bridge 后：
  - `/map` 的 `Subscription count=1`，订阅者是 `/foxglove_bridge`。
  - Foxglove bridge 日志已 advertise `/map`、`/cloud_registered_1`、`/Laser_map_1`、`/localization_3d`。
  - 新日志未继续出现 `bad optional access`。

## 2026-06-30 Foxglove `/Laser_map_1` 消息超限处理

现象：

- Foxglove 提示 `/Laser_map_1` 消息大小超出限制并丢弃消息。

原因：

- `/Laser_map_1` 是 FAST-LIO 发布的累计地图，建图越久单帧 `PointCloud2` 越大。
- `foxglove_bridge` 默认 `send_buffer_limit=10000000`，约 10MB，较大的累计地图容易超过上限。

修改：

```text
nav_workspace/src/fast/FAST_LIO/launch/mapping.launch.py
nav_workspace/autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/launch/fastlio_mid360_nav.launch.py
```

- `send_buffer_limit: 100000000`
- `use_compression: true`

验证：

- 当前运行的 `/foxglove_bridge` 参数已确认：

```text
send_buffer_limit = 100000000
use_compression = true
```

注意：

- 100MB 只是提高可视化上限，不建议长时间一直订阅 `/Laser_map_1`。
- 如果仍然超限或 Foxglove 卡顿，取消订阅 `/Laser_map_1`，建图时看 `/cloud_registered_1`，保存地图后重定位阶段看 `/map`。

## 2026-06-30 局部避障点云过稀处理

现象：

- MID360 原始点云正常，但 `/registered_scan` 只有几百点，局部规划避障输入过稀。
- FAST-LIO 建图和 Foxglove 里看起来容易误判为“建图参数被改坏”。

判断：

- 当前 autonomy FAST-LIO 配置仍接近官方 MID360 低负载配置：
  - `filter_size_surf: 0.5`
  - `filter_size_map: 0.5`
  - `dense_publish_en: false`
- `dense_publish_en=false` 时，FAST-LIO 的 `/cloud_registered_1` 是下采样后的世界系点云。
- `/cloud_registered_body_1` 保留更多机体系点，但作为导航默认输入会改变局部障碍输入链路，必须单独验证。

修改：

```text
nav_workspace/autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/mid360_go2_nav_bridge/fastlio_topic_bridge.py
nav_workspace/autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/launch/fastlio_mid360_nav.launch.py
```

- `fastlio_topic_bridge` 增加可选 `transform_cloud_to_odom`。
- 导航默认恢复稳定旧链路：`/cloud_registered_1 -> /registered_scan`。
- 新增实验链路：`--dense-local-scan` 时使用 `/cloud_registered_body_1`，并用最新 `/Odometry_loc` 把 body 点云变换到 `camera_init` 后发布 `/registered_scan`。
- 不开启 FAST-LIO `dense_publish_en=true`，避免 `/Laser_map_1` 和 Foxglove 负载过高。

验证：

```text
/cloud_registered_1 width: 1218
/cloud_registered_body_1 width: 4280
/registered_scan width: 4158
/registered_scan frame_id: camera_init
```

已在容器 `mid360_go2_nav_humble` 内重编译：

```bash
colcon build --symlink-install --packages-select mid360_go2_nav_bridge
```

注意：

- 已运行中的 `start_nav.sh` 需要重启后才会加载新桥接逻辑。
- 默认稳定链路应看到 `Bridging cloud /cloud_registered_1 -> /registered_scan`。
- 只有手动加 `--dense-local-scan`，才应看到
  `Bridging cloud /cloud_registered_body_1 -> /registered_scan`。

### Code review 后修正

- 操作指南 Step 0 不再使用 `docker ps -q | xargs docker kill`，只停止/启动
  `mid360_go2_nav_humble`，避免误杀其他容器。
- 操作指南中的重定位和真机导航命令恢复为 `<map_name>_<timestamp>.pcd`
  占位符，并把示例速度保持在更保守的 `--max-speed 0.2`。
- 旧版建图和导航 launch 曾使用 Foxglove 白名单并补齐 `/submap`、
  `/baselink2map`、`/odom2map`、`/motionlink2map`、
  `/localization_3d_delay_ms`、`/far_reach_goal_status` 等检查话题。
- `fastlio_topic_bridge` 的 PointCloud2 转换增加字段类型校验，并按
  `height/width/row_step` 迭代，避免未来 organized cloud 或行 padding
  导致坐标写错。
- 2026-06-30 发现 dense body 默认链路会让导航表现不稳定，已改为
  可选实验开关，默认恢复 `/cloud_registered_1` 稳定链路。

调整 autonomy_stack_go2 局部规划参数：

```text
nav_workspace/autonomy-go2-mid360/workspace/src/autonomy_stack_go2/src/base_autonomy/terrain_analysis/launch/terrain_analysis.launch
nav_workspace/autonomy-go2-mid360/workspace/src/autonomy_stack_go2/src/base_autonomy/local_planner/launch/local_planner.launch
```

宇树原厂配置只作为参考，不建议由本集成直接修改：

```text
/unitree/module/unitree_slam/config/pl_mapping/mid360.yaml
/unitree/module/unitree_slam/config/pl_relocation/mid360.yaml
/unitree/module/unitree_slam/config/gridmap_config/config.yaml
```

## 2026-07-02 Humble 环境重编译和 TF 回顾

现象：

- 启动建图或重定位时，source `/workspace/nav_ws/install/setup.bash` 会打印：
  - `not found: "/opt/ros/foxy/local_setup.bash"`
  - `not found: "/home/unitree/cyclonedds_ws/install/local_setup.bash"`

原因：

- `nav_workspace/install/setup.bash` 是旧 colcon underlay 生成物，内部记录了
  `/opt/ros/foxy` 和 `/home/unitree/cyclonedds_ws/install`。
- 当前运行容器仍是 ROS2 Humble；问题不在容器版本，而在旧 install prefix chain。

处理：

```bash
sudo docker run --rm --network host \
  -e RMW_IMPLEMENTATION=rmw_cyclonedds_cpp \
  -v /home/unitree/go2-fast-lio/nav_workspace:/workspace/nav_ws \
  mid360-go2-nav:humble bash -lc '
    set -euo pipefail
    cd /workspace/nav_ws
    set +u
    source /opt/ros/humble/setup.bash
    source /workspace/nav_ws/src/ws_livox/install/local_setup.bash
    set -u
    colcon build \
      --base-paths src/pointcloud_filter src/fast/FAST_LIO src/fast/open3d_loc \
      --packages-select pointcloud_filter fast_lio open3d_loc \
      --symlink-install \
      --cmake-args -DCMAKE_BUILD_TYPE=Release
  '
```

验证：

- `nav_workspace/install/setup.bash` 现在只链到：
  - `/opt/ros/humble`
  - `/workspace/nav_ws/src/ws_livox/install`
- 当前容器内可找到：
  - `fast_lio`
  - `open3d_loc`
  - `pointcloud_filter`
- 建图脚本实际进入交互提示时，不再打印 Foxy/cyclonedds 的 `not found`。

base_link 回顾：

- 当前文档和 launch 的导航主 TF 仍是：

```text
map -> odom -> camera_init -> aft_mapped -> sensor -> vehicle
```

- 2026-05-28 的原始验证记录也是 `map -> vehicle` 连通，并没有记录
  `map -> base_link` 作为主导航 TF。
- 当前 `base_link` 主要用于：
  - `/initialpose` 语义：用户给的是 `map -> base_link`
  - `global_nav_frame_bridge` 把它转换成 Open3D 需要的 `map -> odom`
  - launch 中发布 `base_link -> imu_link`、`base_link -> motion_link`
- 当前没有发布 `vehicle -> base_link` 或 `sensor -> base_link`，所以 Foxglove 里
  `map -> base_link` 不一定连通。导航链路本身按 `vehicle` 工作。
- 如果后续要兼容 Nav2、URDF 或 Foxglove 机器人模型，应新增一条明确的
  `vehicle -> base_link` 静态 TF，而不是改动 FAST-LIO 里程计定义。

## 2026-07-02 planner 专用更密点云 bridge 实装记录（已回滚，仅历史记录）

目标：

- 不改变 FAST-LIO 建图和重定位使用的稳定低负载链路。
- 保留 `/cloud_registered_1` 作为 Open3D 重定位、调试和默认导航输入。
- 额外提供一个只给局部 planner 使用的更密当前帧点云输入，解决
  `/registered_scan` 过稀导致局部障碍轮廓断续的问题。
- 避免直接开启 FAST-LIO `dense_publish_en=true`，因为那会同时影响
  `/cloud_registered_1`、Foxglove 可视化负载和 Open3D 重定位输入。

备份：

```text
/tmp/autonomy_go2_mid360_bridge_backup_20260702_202845/
  fastlio_topic_bridge.py
  fastlio_mid360_nav.launch.py
  start_nav.sh
```

修改文件：

```text
nav_workspace/autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/mid360_go2_nav_bridge/fastlio_topic_bridge.py
nav_workspace/autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/launch/fastlio_mid360_nav.launch.py
nav_workspace/autonomy-go2-mid360/scripts/start_nav.sh
```

实现方式：

- `fastlio_topic_bridge` 新增参数：
  - `transform_cloud_to_odom`，默认 `false`
  - `planner_cloud_voxel_size`，默认 `0.0`
- 默认模式保持原行为：
  - 订阅 `/cloud_registered_1`
  - 直接重发为 `/registered_scan`
  - frame_id 覆盖为 `camera_init`
- planner dense 模式：
  - 订阅 `/cloud_registered_body_1`
  - 保存最新 `/Odometry_loc`
  - 将 body-frame 点云用最新 odometry pose 变换到 `camera_init`
  - 按 `planner_cloud_voxel_size` 做可选体素抽点
  - 发布到原下游接口 `/registered_scan`
- PointCloud2 处理细节：
  - 检查 `x/y/z` 字段存在且为 `FLOAT32`
  - 按 `height/width/row_step/point_step` 遍历，兼容 organized cloud 和行 padding
  - 跳过非有限值点
  - 体素抽点采用每个 voxel 保留第一个点
  - 输入字段不符合预期时限频 warning，并丢弃该帧，不让 bridge 节点退出

启动参数：

- `fastlio_mid360_nav.launch.py` 新增：
  - `input_cloud_topic`
  - `transform_cloud_to_odom`
  - `planner_cloud_voxel_size`
- `start_nav.sh` 新增：
  - `--dense-local-scan`
  - `--planner-cloud-voxel-size M`
- `--dense-local-scan` 等价于：

```text
input_cloud_topic:=/cloud_registered_body_1
transform_cloud_to_odom:=true
planner_cloud_voxel_size:=0.15
```

其中 `0.15m` 只作用在 planner 的 `/registered_scan` 输出上，不改变
FAST-LIO 建图地图、不改变 `/cloud_registered_1`、不改变 Open3D `/map`。

验证：

- 宿主机语法检查通过：

```bash
python3 -m py_compile autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/mid360_go2_nav_bridge/fastlio_topic_bridge.py
python3 -m py_compile autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/launch/fastlio_mid360_nav.launch.py
bash -n autonomy-go2-mid360/scripts/start_nav.sh
```

- 容器 `mid360_go2_nav_humble` 内已重编译：

```bash
colcon build --symlink-install --packages-select mid360_go2_nav_bridge
```

- 容器内验证：
  - `ros2 launch mid360_go2_nav_bridge fastlio_mid360_nav.launch.py --show-args`
    能看到 `input_cloud_topic`、`transform_cloud_to_odom`、
    `planner_cloud_voxel_size`
  - `python3 -c 'from mid360_go2_nav_bridge.fastlio_topic_bridge import FastlioTopicBridge, transform_cloud; print("ok")'`
    返回 `ok`
  - install 目录中的 launch 已包含新增参数

使用判断：

- 建图和重定位仍使用稳定 FAST-LIO 配置，不需要重新打开
  `dense_publish_en`。
- 如果只想使用原稳定导航链路，不加 `--dense-local-scan`。
- 如果局部障碍仍过稀，导航启动时加 `--dense-local-scan`。
- 如果 CPU 负载高或障碍轮廓仍抖动，优先把
  `--planner-cloud-voxel-size` 从 `0.15` 调到 `0.20` 或 `0.25`；
  不建议优先改 FAST-LIO 建图参数。

## 2026-07-03 dense planner bridge 时间戳匹配修复（已回滚，仅历史记录）

问题假设：

- 2026-07-02 新增的 dense planner bridge 在 `--dense-local-scan` 模式下，
  会把 `/cloud_registered_body_1` 变换到 `camera_init` 后发布为
  `/registered_scan`。
- 旧实现使用“cloud 回调触发时最新收到的 `/Odometry_loc`”进行变换。
- FAST-LIO 源码确认 `/Odometry_loc`、`/cloud_registered_1`、
  `/cloud_registered_body_1` 都使用同一个 `lidar_end_time` 作为 stamp。
- 但 ROS2 不保证不同 topic 的回调一定严格按 FAST-LIO 发布顺序到达。
  如果 cloud 回调拿到的是上一帧 odom，机器人运动时就会把当前帧点云
  套到上一帧位姿上，表现为 `/registered_scan` 或 `/terrain_map`
  局部障碍轮廓抖动/滑动。

原行为：

```text
/cloud_registered_body_1 当前帧
+ latest /Odometry_loc，不检查 header.stamp
-> /registered_scan
```

修改后行为：

```text
/Odometry_loc 按 header.stamp 放入 ring buffer
/cloud_registered_body_1 到达时，按 cloud header.stamp 查最近 odom
stamp 差值 <= planner_cloud_max_stamp_diff 才变换发布
找不到匹配 odom 时丢弃该 cloud 帧，并限频 warning
```

修改文件：

```text
nav_workspace/autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/mid360_go2_nav_bridge/fastlio_topic_bridge.py
nav_workspace/autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/launch/fastlio_mid360_nav.launch.py
nav_workspace/autonomy-go2-mid360/scripts/start_nav.sh
```

新增/调整参数：

```text
fastlio_topic_bridge:
  planner_cloud_odom_buffer_size: 100
  planner_cloud_max_stamp_diff: 0.02

start_nav.sh:
  --planner-cloud-max-stamp-diff SEC
```

默认容差：

- `planner_cloud_max_stamp_diff=0.02s`
- MID360/FAST-LIO 当前约 `20Hz`，帧间隔约 `0.05s`
- 20ms 小于一帧周期，可避免误用上一帧 odom；如果现场偶发丢帧，
  可临时放宽到 `0.03`，但不建议超过 `0.05`

重要边界：

- 这个修复只影响 `--dense-local-scan` 模式下的 `/registered_scan`。
- 不改变 `/cloud_registered_1`。
- 不改变 `/Odometry_loc`。
- 不改变 Open3D 重定位订阅的输入。
- 不改变 FAST-LIO 建图或保存 PCD 地图。

验证命令：

```bash
python3 -m py_compile autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/mid360_go2_nav_bridge/fastlio_topic_bridge.py
python3 -m py_compile autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/launch/fastlio_mid360_nav.launch.py
bash -n autonomy-go2-mid360/scripts/start_nav.sh
```

现场验证建议：

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/start_nav.sh \
  --global-localization \
  --route-planner \
  --map-file /workspace/maps/<map>.pcd \
  --no-real-robot \
  --dense-local-scan \
  --planner-cloud-voxel-size 0.15 \
  --planner-cloud-max-stamp-diff 0.02 \
  --max-speed 0.2 \
  --max-yaw-rate 30.0 \
  --no-rviz
```

检查点：

- 启动日志应显示：
  `Transforming planner cloud ... max_stamp_diff=0.020 s`
- 如果持续出现：
  `Dropping planner cloud: no odometry with matching stamp`
  说明 odom/cloud 回调顺序或时间戳存在实际问题，可先把
  `--planner-cloud-max-stamp-diff` 临时调到 `0.03` 复测。
- 如果出现：
  `Planner cloud using nearest odometry with stamp_diff=...`
  说明没有精确同 stamp，但仍在容差内匹配到了最近 odom。

## 2026-07-03 dense planner bridge 回滚

用户判断：

- 目标发布后可视化里狗的位置和障碍物地图出现漂移，怀疑新增的
  dense planner bridge 影响了 `/registered_scan` 输入链路。
- 当前优先恢复原稳定版本，不继续保留实验 bridge。

回滚内容：

```text
nav_workspace/autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/mid360_go2_nav_bridge/fastlio_topic_bridge.py
nav_workspace/autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/launch/fastlio_mid360_nav.launch.py
nav_workspace/autonomy-go2-mid360/scripts/start_nav.sh
nav_workspace/autonomy-go2-mid360/OPERATION_GUIDE.md
```

当前行为：

- `fastlio_topic_bridge.py` 已恢复为 6.22 稳定版本行为：
  - `/Odometry_loc` -> `/state_estimation`
  - 发布 `camera_init -> aft_mapped` TF
  - `/cloud_registered_1` 仅改 `frame_id=camera_init` 后发布为
    `/registered_scan`
- 不再订阅 `/cloud_registered_body_1`。
- 不再把 body-frame 点云用 `/Odometry_loc` 变换到 `camera_init`。
- 不再做 planner 专用 voxel filter。
- `start_nav.sh` 不再接受：
  - `--dense-local-scan`
  - `--planner-cloud-voxel-size`
  - `--planner-cloud-max-stamp-diff`
- `fastlio_mid360_nav.launch.py` 不再声明或传递：
  - `input_cloud_topic`
  - `transform_cloud_to_odom`
  - `planner_cloud_voxel_size`
  - `planner_cloud_odom_buffer_size`
  - `planner_cloud_max_stamp_diff`

验证：

```bash
python3 -m py_compile autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/mid360_go2_nav_bridge/fastlio_topic_bridge.py autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/launch/fastlio_mid360_nav.launch.py
bash -n autonomy-go2-mid360/scripts/start_nav.sh
diff -u <6.22 workspace.zip 中的 fastlio_topic_bridge.py> 当前 fastlio_topic_bridge.py
```

结果：

- Python 语法检查通过。
- `start_nav.sh` 语法检查通过。
- `fastlio_topic_bridge.py` 与 6.22 备份中的同名文件一致。
- 代码入口中不再存在 `dense-local-scan`、`planner_cloud`、
  `transform_cloud_to_odom`、`cloud_registered_body_1` 等实验 bridge 入口。

注意：

- 已经启动的旧 `start_nav.sh` 进程不会自动卸载旧 bridge，需要停止后重新启动。
- 重启后导航日志应显示稳定链路：
  `Bridging cloud /cloud_registered_1 -> /registered_scan`。

## 2026-07-03 重定位默认启动 Foxglove

用户目标：

- 执行 `scripts/start_nav.sh --global-localization ...` 启动重定位时，默认同时启动 Foxglove。
- 仍保留关闭入口，避免 9001 端口已有其他 `foxglove_bridge` 时冲突。
- 避免使用全量 ROS graph 暴露方式触发：
  `Exception thrown in rosgraphPollThread: bad optional access`

原因说明：

- 该错误来自 `foxglove_bridge` 的 ROS graph 轮询线程，不是 FAST-LIO 或
  Open3D 重定位节点本身报错。
- Unitree 运行环境中存在部分自定义 DDS/ROS topic、service 或 type 元数据，
  容器内 Humble 环境不一定能完整解析对应 schema。
- `foxglove_bridge` 全图扫描时遇到缺失 metadata 后可能触发 C++
  `std::optional` 空值访问，从而反复打印 `bad optional access`。

修改文件：

```text
nav_workspace/autonomy-go2-mid360/scripts/start_nav.sh
nav_workspace/autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/launch/fastlio_mid360_nav.launch.py
```

行为变化：

```text
scripts/start_nav.sh --global-localization ...
  默认传入 foxglove:=true

scripts/start_nav.sh --global-localization --no-foxglove ...
  显式关闭 foxglove_bridge

scripts/start_nav.sh --foxglove ...
  显式启动 foxglove_bridge
```

Foxglove bridge 启动参数：

```text
port: 9001
address: 0.0.0.0
send_buffer_limit: 100000000
max_qos_depth: 25
capabilities: [clientPublish, connectionGraph]
param_whitelist: [^$]
service_whitelist: [^$]
topic_whitelist: FAST-LIO/Open3D/autonomy/FAR/TF 相关标准话题
```

注意：

- 当前过滤不是修复 Foxglove bridge 的 C++ 异常处理，而是避免它扫描
  本容器无法完整解析的 Unitree 自定义 graph endpoint。
- 同一时间只能有一个 bridge 监听 `9001`。如果仍有建图 launch 启动的
  Foxglove，重定位 launch 中的 bridge 会因为端口占用而失败。
- 2026-07-03 修复：ROS2 launch 参数系统不能接受空数组参数；原先的
  `param_whitelist: []` / `service_whitelist: []` 会被解析成空 tuple `()`，
  报错 `Expected 'value' ... but got '()'`。已改为 `[^$]`，表示合法的
  字符串数组且不匹配任何参数或服务。

## 2026-07-03 恢复 terrainAnalysis noDataObstacle

用户要求：

- 将 `terrainAnalysis.noDataObstacle` 设回 `true`。

修改文件：

```text
nav_workspace/autonomy-go2-mid360/workspace/src/autonomy_stack_go2/src/base_autonomy/terrain_analysis/launch/terrain_analysis.launch
```

当前行为：

```xml
<param name="noDataObstacle" value="true" />
```

影响：

- `terrainAnalysis` 会恢复上游默认的 no-data obstacle 行为。
- 空洞/无点云覆盖区域可能重新被标成障碍；如果静止时前方出现虚拟障碍墙，
  这是该参数开启后的预期风险。
- 已经运行中的 `terrainAnalysis` 不会自动更新参数，需要重启导航 launch。

## 2026-07-03 降低 localPlanner 障碍高度阈值

用户要求：

- 离地面约 `0.15m` 的高度变化就视作障碍物。

修改文件：

```text
nav_workspace/autonomy-go2-mid360/workspace/src/autonomy_stack_go2/src/base_autonomy/local_planner/launch/local_planner.launch
```

当前行为：

```xml
<param name="obstacleHeightThre" value="0.15" />
```

影响：

- `localPlanner` 使用 `terrainAnalysis` 输出点云中的高度强度值判断障碍。
- 原来 `0.3m` 以上才按障碍处理；现在约 `0.15m` 以上就会更容易阻挡路径。
- 灵敏度提高后，地面噪声、台阶边缘、点云抖动也更容易触发避障，需要现场观察
  `/terrain_map` 和 `/free_paths` 是否因此过度保守。
- 已经运行中的 `localPlanner` 不会自动更新参数，需要重启导航 launch。

## 2026-07-06 新增 planner 专用 registered_scan 点云桥

用户目标：

- 保持 Open3D 重定位继续使用 FAST-LIO 的 `/cloud_registered_1`。
- 不开启 FAST-LIO `dense_publish_en=true`，避免影响重定位和可视化负载。
- 让后续 terrain/local/FAR planner 使用更接近原 Point-LIO 粒度的局部点云。

修改文件：

```text
nav_workspace/autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/mid360_go2_nav_bridge/planner_scan_bridge.py
nav_workspace/autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/mid360_go2_nav_bridge/fastlio_topic_bridge.py
nav_workspace/autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/launch/fastlio_mid360_nav.launch.py
nav_workspace/autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/setup.py
nav_workspace/autonomy-go2-mid360/workspace/src/mid360_go2_nav_bridge/package.xml
```

当前链路：

```text
Open3D 重定位:
  /cloud_registered_1

FAST-LIO odom/TF bridge:
  /Odometry_loc -> /state_estimation
  camera_init -> aft_mapped TF

Planner 专用点云:
  /cloud_registered_body_1 + /Odometry_loc
    -> 按 cloud header.stamp 查最近 odom
    -> body 点云变换到 camera_init
    -> 0.10m voxel
    -> 0.20s 短时累积，最多 4 帧
    -> 最多 12000 点
    -> /registered_scan
```

默认参数：

```text
input_cloud_topic: /cloud_registered_body_1
input_odom_topic: /Odometry_loc
output_cloud_topic: /registered_scan
target_frame_id: camera_init
voxel_size: 0.10
accumulation_time: 0.20
max_frames: 4
max_points: 12000
min_range: 0.25
max_range: 10.0
max_odom_dt: 0.08
```

为什么这样改：

- 原官方 Point-LIO 链路是 `/cloud_registered -> /registered_scan`，并使用
  `point_filter_num=1`、`filter_size_surf=0.1`、`space_down_sample=true`。
- 当前 FAST-LIO `/cloud_registered_1` 默认是 `filter_size_surf=0.5` 的稀疏世界系点云，
  直接给 planner 会导致障碍轮廓和 FAR 图更容易断续。
- `/cloud_registered_body_1` 更密，但不能直接喂给 planner；它必须按时间戳用
  `/Odometry_loc` 转到 `camera_init`，否则运动时静态障碍会跟随 body frame 漂移。
- 旧 `fastlio_topic_bridge` 新增 `publish_cloud` 参数，并在导航 launch 中设为 `false`，
  避免它和新 `planner_scan_bridge` 同时发布 `/registered_scan`。

验证建议：

```bash
ros2 node list | grep planner_scan_bridge
ros2 topic info -v /registered_scan
ros2 topic echo --once /registered_scan --field header
ros2 topic echo --once /registered_scan --field width
ros2 topic hz /registered_scan
ros2 topic echo --once /cloud_registered_1 --field width
ros2 topic echo --once /cloud_registered_body_1 --field width
```

预期：

```text
/registered_scan publisher: /planner_scan_bridge
/registered_scan frame_id: camera_init
/registered_scan 点数: 高于 /cloud_registered_1，接近受控的几千点级
Open3D /global_loc_node 仍订阅 /cloud_registered_1
```

注意：

- 需要重新 `colcon build --packages-select mid360_go2_nav_bridge` 后重启导航 launch。
- 已运行中的导航进程不会自动切换到新 bridge。

---

## 2026-07-06 静止状态地图/里程计发散诊断

现场现象：

- 狗静止时，导航可视化中地图/障碍物持续漂移，无法正常导航。
- 当前运行容器是开发版 `mid360_go2_nav_humble`。
- 备份容器 `mid360_go2_nav_humble_original_20260701` 当时未运行，不是双容器重复发布导致。

运行时检查结果：

```text
/map publisher count: 0
/baselink2map: unknown topic
/localization_3d_confidence: unknown topic
tf2_echo map odom: map frame does not exist
```

说明 Open3D `global_loc_node` 已退出，当前没有 `map->odom` 重定位闭环。

`launch.log` 中记录：

```text
global_localization_node process started
global_localization_node process has died, exit code -6
```

更上游的 FAST-LIO 已经先发散。静止状态下连续采样 `/Odometry_loc`：

```text
SAMPLE 1: x=803.31, y=743.20, z=-571.52
SAMPLE 2: x=803.31, y=743.27, z=-571.51
SAMPLE 3: x=805.36, y=744.56, z=-572.38
SAMPLE 4: x=800.44, y=743.55, z=-570.96
SAMPLE 5: x=815.29, y=762.15, z=-579.81
```

这说明不是 planner 或新 `/registered_scan` bridge 首先把地图带飞，而是
FAST-LIO `/Odometry_loc` 在静止状态下已经发散。

FAST-LIO 日志同时持续出现：

```text
Too few input point cloud!
No point, skip this scan!
```

原始 `/unitree/slam_lidar/points` 抽样：

```text
width: 10080
fields: x/y/z/intensity/ring/time
time: 5000.0 -> 50400000.0
span: 50395000.0
ring: 0..3
```

`timestamp_unit: 3` 在当前 FAST-LIO 源码中对应纳秒，和 Unitree 点云 `time`
字段匹配；不是本次直接原因。

确认到当前开发版和 2026-07-01 备份稳定版的 FAST-LIO 源码一致，但
`unitree_go2_fastlio_autonomy.yaml` 有一个参数差异：

```text
2026-07-01 backup: point_filter_num: 2
current before fix: point_filter_num: 3
```

处理：

- 将 `fast-lio-mid360/config/unitree_go2_fastlio_autonomy.yaml`
  的 `point_filter_num` 从 `3` 恢复为备份稳定值 `2`。
- 同步修正 `autonomy-go2-mid360/OPERATION_GUIDE.md` 中的当前参数说明。

注意：

- 这是配置修改，不需要重新编译 FAST-LIO。
- 已运行的 FAST-LIO 不会自动生效，必须停止当前建图/导航会话后重新启动。
- 重新测试时先只启动 FAST-LIO，狗保持静止，确认 `/Odometry_loc` 不再持续漂移，
  再启动 `start_nav.sh`。

---

## 2026-07-06 关闭默认 dense planner bridge，恢复稳定 `/registered_scan` 链路

现场复现：

- 只启动 FAST-LIO 建图/实时前端时，狗静止和轻微运动下 `/Odometry_loc` 稳定。
- 启动下面导航命令后，`/Odometry_loc` 开始持续跑远：

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/start_nav.sh \
  --global-localization \
  --route-planner \
  --map-file /workspace/maps/aaa-fuck-magic-company_20260630_100336.pcd \
  --no-real-robot \
  --max-speed 0.3 \
  --max-yaw-rate 80.0 \
  --auto-disarm-on-goal \
  --no-rviz
```

运行时证据：

```text
planner_scan_bridge: ~89% CPU
far_planner: ~85% CPU
fastlio_mapping: ~42% CPU
```

同时 FAST-LIO 日志密集出现：

```text
Too few input point cloud!
No point, skip this scan!
```

结论：

- `planner_scan_bridge` 不会直接发布或改写 `/Odometry_loc`、`/cloud_registered_1`
  或 `/cloud_registered_body_1`。
- 但它在 Go2 上负载过高，会和 FAR planner、terrain analysis、Foxglove 一起抢占 CPU，
  使 FAST-LIO 实时性变差，进而触发 `Too few input point cloud`，导致
  `/Odometry_loc` 发散。

处理：

- 修改 `workspace/src/mid360_go2_nav_bridge/launch/fastlio_mid360_nav.launch.py`：
  - `fastlio_topic_bridge.publish_cloud` 从 `false` 改为 `true`。
  - 从默认 LaunchDescription 中移除 `planner_scan_bridge` 启动项。
- 默认 `/registered_scan` 恢复为稳定旧链路：

```text
/cloud_registered_1 -> fastlio_topic_bridge -> /registered_scan
```

- `planner_scan_bridge.py` 文件暂时保留，后续若要继续研究高密度 planner 输入，需要先做
  C++ 实现或显著降频/降点数，不能默认在导航链路中启用。

验证：

```bash
docker exec mid360_go2_nav_humble bash -lc \
  'set +u; source /opt/ros/humble/setup.bash; cd /workspace/autonomy-go2-mid360/workspace; colcon build --packages-select mid360_go2_nav_bridge --symlink-install'
docker restart mid360_go2_nav_humble
```

预期下一次导航启动：

```text
ros2 node list | grep planner_scan_bridge   # 应无输出
ros2 topic info -v /registered_scan         # publisher 应为 /fastlio_topic_bridge
日志应看到: Bridging cloud /cloud_registered_1 -> /registered_scan
```

---

## 2026-07-06 移除 dense planner bridge，调整 FAST-LIO 抽点粒度

按现场测试结论，默认不再保留 Python dense planner bridge：

- 删除 `mid360_go2_nav_bridge/planner_scan_bridge.py`。
- 删除 `setup.py` 中的 `planner_scan_bridge` console entry。
- 删除 `fastlio_mid360_nav.launch.py` 中的 `planner_scan_bridge` 节点定义。

当前 planner 输入链路固定为：

```text
/cloud_registered_1 -> fastlio_topic_bridge -> /registered_scan
```

为了让 planner 输入比原先稍密，同时避免额外 Python 点云处理负载，将
`fast-lio-mid360/config/unitree_go2_fastlio_autonomy.yaml` 调整为：

```text
point_filter_num: 1
filter_size_surf: 0.5
filter_size_map: 0.5
dense_publish_en: false
```

影响：

- `/cloud_registered_1` 和 `/registered_scan` 会比 `point_filter_num=2` 更密。
- 不启用 FAST-LIO `dense_publish_en=true`。
- 不改变外参、时间单位、`filter_size_map`，所以不强制要求立刻重建地图。
- 后续正式使用时，建议用同一套参数重新建一张地图做最终一致性验证。

---

## 2026-07-06 修复 terrain 输出 frame_id 误标为 map

问题现象：

- Foxglove 中 `/FAR_terrain_height_debug`、障碍物轮廓、局部图节点相对地图/机器人位置存在整体偏移或歪斜。
- 同一现象在开发容器和 2026-07-01 原始版本中都能出现，说明不是单个容器环境问题；
  也说明本节 frame_id 修复不能单独视为根因定案。

排查结论：

- 当前 `terrain_analysis` 和 `terrain_analysis_ext` 从 `/registered_scan` 读取点云后，
  发布 terrain 点云时把 `header.frame_id` 固定写成 `"map"`。
- `/registered_scan` 来自 FAST-LIO 注册点云链路，实际 frame 通常是输入点云 header 中的
  `camera_init`，不是 `map`。
- 这会把局部/里程计坐标系下的 terrain 点误标成全局 `map` 坐标，导致可视化和下游规划看到的
  障碍物整体偏移或角度不对。

处理：

- 修改 `terrain_analysis/src/terrainAnalysis.cpp`：
  - 增加 `terrainFrame`，默认值仍为 `"map"`。
  - 在 `laserCloudHandler()` 中，如果输入点云 `header.frame_id` 非空，则记录为 `terrainFrame`。
  - 发布 terrain 点云时使用 `terrainFrame`，不再硬编码 `"map"`。
- 修改 `terrain_analysis_ext/src/terrainAnalysisExt.cpp`：
  - 做同样的 `terrainFrame` 继承处理。

这次修复不修改 FAST-LIO 建图/重定位参数、不修改外参、不重新引入 dense planner bridge。

后续判断：

- 2026-07-01 原始版本本来就使用 `terrainFrame = laserCloud2->header.frame_id`，所以如果
  原始版本也有同样倾斜，根因更可能在两版共有链路：
  - FAST-LIO 外参 `extrinsic_R/T` 与 MID360 实际安装角不一致；
  - `/state_estimation` 的位姿参考点与 `/registered_scan` 的点云参考坐标不一致；
  - 重定位时 `map->odom/camera_init` 姿态使全局地图和局部扫描存在 pitch/roll/yaw 偏差；
  - Foxglove 固定坐标系把 `map` 与 `camera_init` 下的数据混合显示后暴露该偏差。
- FAST-LIO 源码确认：
  - `/cloud_registered_1` 是 world/camera_init 系下的当前帧注册点；
  - `/cloud_registered_body_1` 是 body 系点云；
  - `/Odometry_loc` 是 `camera_init -> body` 位姿。
- 因此下一步应在实机运行时同时采样 `/registered_scan`、`/state_estimation`、
  `/Odometry_loc`、`/tf`，确认它们的 frame 和数值是否一致。

验证建议：

```bash
ros2 topic echo --once /registered_scan --field header.frame_id
ros2 topic echo --once /terrain_map --field header.frame_id
ros2 topic echo --once /terrain_map_ext --field header.frame_id
```

修复后，terrain 输出的 frame 应与 `/registered_scan` 一致，而不是固定为 `map`。

---

## 2026-07-07 新增手动禁行边界发布脚本

新增脚本：

```text
autonomy-go2-mid360/scripts/publish_navigation_boundary.sh
```

用途：

- 发布 `geometry_msgs/msg/PolygonStamped` 到 `/navigation_boundary`。
- 支持输入 `camera_init` 坐标，直接发布给 `localPlanner`。
- 支持输入 `map` 坐标，脚本在容器内读取 TF，将点转换到 `camera_init` 后发布。
- 默认闭合边界，即自动把第一个点追加到最后。
- 默认把发布点的 z 固定为 `0.0`，避免 `localPlanner` 因相邻点 z 不完全相等而跳过线段。

示例：

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/publish_navigation_boundary.sh \
  --frame camera_init \
  --points "1.0,-1.0,0; 3.0,-1.0,0; 3.0,1.0,0; 1.0,1.0,0" \
  --repeat 3

bash nav_workspace/autonomy-go2-mid360/scripts/publish_navigation_boundary.sh \
  --frame map \
  --points "10.0,2.0,0; 12.0,2.0,0; 12.0,4.0,0; 10.0,4.0,0" \
  --repeat 3
```

验证：

```bash
bash -n autonomy-go2-mid360/scripts/publish_navigation_boundary.sh
bash autonomy-go2-mid360/scripts/publish_navigation_boundary.sh --help
bash autonomy-go2-mid360/scripts/publish_navigation_boundary.sh \
  --container mid360_go2_nav_humble_original_20260701 \
  --frame camera_init \
  --points "1,0,0;2,0,0;2,1,0;1,1,0" \
  --dry-run
```

说明：

- 该脚本不修改 FAST-LIO、Open3D、FAR planner 或 `localPlanner` 代码。
- 脚本只使用当前已有的 `/navigation_boundary` 接口。
- 长期持久化标注建议用 `map` 坐标保存到 JSON；发布时再转换到 `camera_init`。

补充验证：

- TF 方向验证：
  - 临时发布 `map -> camera_init` 平移 `(1, 2, 0)`。
  - 输入 map 点：
    `[(1,2,0), (2,2,0), (2,3,0), (1,3,0)]`。
  - 脚本 dry-run 输出 camera_init 点：
    `[(0,0,0), (1,0,0), (1,1,0), (0,1,0), (0,0,0)]`。
  - 说明 `lookup_transform(camera_init, map)` 方向和点变换实现正确。
- 发布验证：
  - 使用 Python ROS2 临时订阅器订阅 `/navigation_boundary`。
  - 脚本发布 camera_init 边界后，订阅器收到：
    `frame_id=camera_init`，5 个闭合点与脚本输出一致。
  - `ros2 topic echo --once` 在当前容器里未稳定捕获一次性发布样本，
    后续验证使用持续运行的 Python 订阅器更可靠。
- localPlanner 识别验证：
  - 直接 `ros2 run local_planner localPlanner` 会因为缺少 launch 中的
    `pathFolder` 参数退出，不能用于单独验证。
  - 使用 `ros2 launch local_planner local_planner.launch is_real_robot:=false autonomyMode:=false`
    短时启动后，`ros2 topic info -v /navigation_boundary` 显示
    `localPlanner` 是该 topic 的订阅者，QoS 为 `RELIABLE / KEEP_LAST(5)`。
  - 源码中 `boundaryHandler()` 会把收到的 polygon 边线离散成
    `boundaryCloud`，主循环再把 `boundaryCloud` 加入 `plannerCloudCrop`，
    因此导航局部规划会把这些边界作为障碍/约束处理。
- 限制：
  - 本次没有在完整导航闭环中发送目标并观察路径绕行，因为测试时运行容器未启动完整
    `start_nav.sh --route-planner` 链路。
