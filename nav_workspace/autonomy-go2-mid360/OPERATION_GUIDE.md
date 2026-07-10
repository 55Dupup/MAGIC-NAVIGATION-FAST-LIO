# 操作手册

宿主机先进入仓库：

```bash
cd /home/unitree/go2-fast-lio
```

autonomy 流程统一使用容器：

```text
mid360_go2_nav_humble
```

先用 `--no-real-robot` 验证，确认重定位、规划和 `/cmd_vel` 正常后再切 `--real-robot`。

## Step 0. 启动容器

环境：宿主机。
```bash
docker start mid360_go2_nav_humble || \
  bash nav_workspace/autonomy-go2-mid360/scripts/run_container.sh
```

检查：

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' | grep mid360_go2_nav_humble
```

## Step 1. FAST-LIO 建图

环境：宿主机，终端 1。

如有原厂 SLAM 会话，先停掉：

```bash
tmux kill-session -t go2_slam 2>/dev/null || true
```

启动 autonomy 专用建图：

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/start_fastlio_unitree_autonomy_for_nav.sh \
  --output-dir /home/unitree/maps \
  --name autonomy_go2_mid360_company-test
```

交互：

```text
s  开始建图
q  保存地图并退出
```

看到下面内容后再移动/转动狗：

```text
FAST-LIO is publishing odometry and registered cloud.
Mapping is running. Press q to save and quit.
```

输出地图：

```text
/home/unitree/maps/<name>_<timestamp>.pcd
```

当前 autonomy 建图配置：

```text
config: unitree_go2_fastlio_autonomy.yaml
point_filter_num: 1
filter_size_surf/map: 0.5
dense_publish_en: false
Open3D voxelsize_coarse/fine: 0.3
extrinsic_T: [0.1870, 0.0, 0.0803]
extrinsic_R: Ry(+0.226 rad)
```

不要混用 `unitree_go2_fastlio.yaml` 和 `unitree_go2_fastlio_autonomy.yaml` 建图/重定位。

## Step 2. 建图可视化

环境：Foxglove。

连接：

```text
ws://<狗的IP>:9001
```

建图常看：

```text
/Laser_map_1
/cloud_registered_1
/Odometry_loc
/tf
```

说明：

```text
/Laser_map_1 是建图累计地图，用于查看建图结果；建图时间越长单帧越大
/map 是 Open3D 重定位加载 PCD 后发布的地图，建图阶段通常没有
Foxglove bridge 默认使用宽白名单：保留 FAST-LIO、Open3D、FAR、TF、目标点、规划可视化和部分标准 Unitree 点云/里程计话题
默认排除 /api/*、/config_change_status、/utlidar/voxel_map_compressed 等易触发 Foxglove schema/graph 异常的自定义话题
```

FAST-LIO 当前保持 `dense_publish_en=false`，所以 `/cloud_registered_1` 是 FAST-LIO 下采样后的注册点云，会比原始 MID360 扫描稀疏。Open3D 重定位仍直接使用 `/cloud_registered_1`。

导航避障使用的 `/registered_scan` 当前为稳定轻量链路：`fastlio_topic_bridge` 将 `/cloud_registered_1` 改 `frame_id=camera_init` 后转发为 `/registered_scan`。高密度 Python planner scan bridge 已移除，因为现场验证它会占用接近一个 CPU 核，可能拖慢 FAST-LIO 实时性。

## Step 3. 启动重定位

重定位前必须先有 FAST-LIO 实时输出：

```text
/Odometry_loc
/cloud_registered_1
```

如果 Step 1 的 FAST-LIO 已经在运行，不要按 `q`，直接执行 Step 3.2。

### Step 3.1 启动 FAST-LIO 实时前端

环境：宿主机，终端 1。

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/start_fastlio_unitree_autonomy_for_nav.sh \
  --output-dir /home/unitree/maps \
  --name <map_name>
```

按 `s`，看到 FAST-LIO 正常发布后保持运行。

### Step 3.2 启动重定位和规划

环境：宿主机，终端 2。

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/start_nav.sh \
  --global-localization \
  --route-planner \
  --map-file /workspace/maps/<map_name>_<timestamp>.pcd \
  --no-real-robot \
  --auto-initialpose \
  --max-speed 0.2 \
  --max-yaw-rate 30.0 \
  --no-rviz
```

如果狗确定在建图起点附近，可以保留 `--auto-initialpose`。否则改用 `--no-auto-initialpose`，并在 Foxglove/RViz 里手动给接近当前位置的 `/initialpose`。

`--global-localization` 默认会启动 Foxglove bridge。若同一台机器上已经有 bridge 占用 `9001`，启动时加 `--no-foxglove`。

### Step 3.3 检查重定位

环境：容器。

```bash
docker exec -it mid360_go2_nav_humble bash
source /opt/ros/humble/setup.bash
source /workspace/nav_ws/install/setup.bash
source /workspace/autonomy-go2-mid360/workspace/install/setup.bash
```

检查：

```bash
ros2 node list | grep global_loc
ros2 topic echo --once /map --field header
ros2 topic echo --once /localization_3d_confidence
ros2 topic echo --once /baselink2map
ros2 run tf2_ros tf2_echo map odom
```

正常：

```text
/global_loc_node 存在
/map frame_id 是 map
/localization_3d_confidence 有稳定数值
map->odom TF 存在
```

## Step 4. Foxglove 查看重定位

如果 Step 3.2 没有加 `--no-foxglove`，Foxglove 已经随重定位默认启动。不要再手动启动第二个同端口 bridge。

只有在单独调试且确认没有现存 bridge 时，才手动启动：

```bash
docker exec -it mid360_go2_nav_humble bash -lc '
source /opt/ros/humble/setup.bash
source /workspace/nav_ws/install/setup.bash
source /workspace/autonomy-go2-mid360/workspace/install/setup.bash
ros2 launch foxglove_bridge foxglove_bridge_launch.xml port:=9001 address:=0.0.0.0 send_buffer_limit:=100000000
'
```

环境：Foxglove。

连接：

```text
ws://<狗的IP>:9001
```

3D Panel：

```text
Fixed Frame: map
```

重定位/导航常看：

```text
/map
/scan2map
/submap
/cloud_registered_1
/registered_scan
/localization_3d
/localization_3d_delay_ms
/baselink2map
/odom2map
/motionlink2map
/far_reach_goal_status
/goal_point
/way_point_global
/way_point
/cmd_vel
/tf
```

如果 `/map` 看不到，先查：

```bash
ros2 topic info -v /map
```

`Publisher count` 必须大于 0，否则是 `global_loc_node` 没运行或已崩。

如果 `Publisher count > 0` 但 Foxglove 里仍没有 `/map`：

```bash
ros2 topic info -v /map
tail -n 80 /tmp/foxglove_filtered_runtime.log
```

正常时 `/map` 的 `Subscription count` 会出现 `foxglove_bridge`。如果 Foxglove 问题栏出现宇树自定义 topic 的 schema/encoding 报错，优先检查是否误启动了无白名单 bridge；标准 topic `/map`、`/cloud_registered_1`、`/goal_point`、`/viz_path_topic` 应能正常显示。

`far_planner` 启动时短暂提示 `Invalid frame ID "map"` 通常是 Open3D 还没发布 `map->odom`。当前 launch 不再固定延迟 `far_planner`，优先保证启动速度；等 `ros2 run tf2_ros tf2_echo map odom` 正常后再判断是否真的异常。

检查避障输入点云：

```bash
ros2 topic echo --once /registered_scan --field header.frame_id
ros2 topic echo --once /registered_scan --field width
```

正常应为：

```text
frame_id: camera_init
width: 通常接近 /cloud_registered_1
```

对比输入/输出点数：

```bash
ros2 topic echo --once /cloud_registered_1 --field width
ros2 topic echo --once /registered_scan --field width
```

当前开发版正常日志应包含：

```text
Bridging cloud /cloud_registered_1 -> /registered_scan
```

如果 Foxglove 提示 `/Laser_map_1` 消息大小超出限制：

```text
/Laser_map_1 是 FAST-LIO 累计地图，建图时间越长单帧越大
当前 bridge 已把 send_buffer_limit 提到 100MB，并启用压缩
如果仍然超限或卡顿，临时取消订阅 /Laser_map_1，改看 /cloud_registered_1 实时点云，保存地图后在重定位阶段看 /map
```

## Step 5. 发布目标点

前提：Step 3 重定位稳定。

环境：容器。

读取当前位置作为目标点：

```bash
ros2 topic echo --once /baselink2map
```

取输出里的：

```text
pose.pose.position.x
pose.pose.position.y
pose.pose.position.z
```

查看已经发布的目标点：

```bash
ros2 topic echo --once /goal_point
```

安全发布目标点：

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh X Y Z
```

默认会检查容器、重定位、FAR planner、V-Graph、`/goal_point` 订阅者，并等待 `/way_point_global`、`/way_point`、`/viz_path_topic` 输出。如果检测到当前已有未完成的 `/way_point_global`，会拒绝覆盖。

到达一个目标点后发布下一个目标点，推荐先重置 FAR 可见图：

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --reset-graph X Y Z
```

`--reset-graph` 会先向 `/reset_visibility_graph` 发布一次 `std_msgs/msg/Empty`，等待 `/robot_vgraph` 重新变为非空，再发布新的 `/goal_point`。如果 FAR graph 重建较慢，可加长等待时间：

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --reset-graph --wait 40 X Y Z
```

强制切换到新目标：

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --force X Y Z
```

手动发布目标点，仅用于调试：

```bash
ros2 topic pub --once /goal_point geometry_msgs/msg/PointStamped \
"{header: {frame_id: map}, point: {x: X, y: Y, z: Z}}"
```

示例：

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh \
  -3.467642079644214 -2.586964652231151 0.4984068124813883
```
## 6-30 测试
沙发：
ros2 topic pub --once /goal_point geometry_msgs/msg/PointStamped \
"{header: {frame_id: map}, point: { x: 4.631581484290042, y: -1.3085985848872264, z: -0.2902845431255161}}"

bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --reset-graph --real-robot-ok 4.631581484290042 -1.3085985848872264 -0.2902845431255161
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --real-robot-ok 4.631581484290042 -1.3085985848872264 -0.2902845431255161

工位边：
ros2 topic pub --once /goal_point geometry_msgs/msg/PointStamped \
"{header: {frame_id: map}, point: { x: -9.209053166999642, y: -1.6957972171725157, z: 1.0643356269382425}}"

bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --reset-graph --real-robot-ok -9.209053166999642 -1.6957972171725157 1.0643356269382425
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --real-robot-ok -9.209053166999642 -1.6957972171725157 1.0643356269382425

工位与展厅拐角：
      x: -15.446592716823343
      y: -0.49017753013916876
      z: 1.6794409362678302
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --reset-graph --real-robot-ok -15.446592716823343 -0.49017753013916876 1.6794409362678302
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --real-robot-ok -15.446592716823343 -0.49017753013916876 1.6794409362678302

展厅内部的具体位置：
x: -22.507451174158554
y: 0.7694344048640434
z: -0.7406245131151484


展厅边空地：
ros2 topic pub --once /goal_point geometry_msgs/msg/PointStamped \
"{header: {frame_id: map}, point: {  x: -15.951452307880588,  y: 4.434339316010321, z: 1.6772551057986225}}"

bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --reset-graph --real-robot-ok -15.951452307880588 4.434339316010321 1.6772551057986225
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --real-robot-ok -15.951452307880588 4.434339316010321 1.6772551057986225

东侧工作区：
      x: 6.1904696135953206
      y: 24.396355920520957
      z: -0.31860461032207954
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --real-robot-ok 6.1904696135953206 24.396355920520957 -0.31860461032207954

机房
      x: -3.5488442063576637
      y: 26.743501420303204
      z: 0.5838668635211696
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --real-robot-ok -3.5488442063576637 26.743501420303204 0.5838668635211696

吧台
      x: -11.832858978247533
      y: 28.06862922047938
      z: 1.365568340092026
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --real-robot-ok -11.832858978247533 28.06862922047938 1.365568340092026

前台
      x: -14.600557879616547
      y: 17.247886817447778
      z: 1.6123827509159774
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --real-robot-ok -14.600557879616547 17.247886817447778 1.6123827509159774

空旷地区测试：

办公室门口：
      x: 0.28475847995892095
      y: -3.1713867645533917
      z: 0.13920187986747276
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --real-robot-ok 0.28475847995892095 -3.1713867645533917 0.13920187986747276

餐桌：
      x: 2.5898152797976026
      y: 0.8513057735536578
      z: -0.06158085002671825
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --reset-graph --real-robot-ok 2.5898152797976026 0.8513057735536578 -0.06158085002671825
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --real-robot-ok 2.5898152797976026 0.8513057735536578 -0.06158085002671825

会议室门口：
      x: 2.633935028184215
      y: 3.6730187750114625
      z: -0.060898555766191284
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --real-robot-ok 2.633935028184215 3.6730187750114625 -0.060898555766191284


7-2测试 沙发：    position:
      x: 5.23204014308132
      y: -0.3418501908472842
      z: -0.2991187424776699
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --real-robot-ok 5.23204014308132 -0.3418501908472842  -0.2991187424776699
      餐桌：    position:
      x: 2.249205030294739
      y: 2.525432164302837
      z: 0.04065647909603118
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --real-robot-ok 2.249205030294739 2.525432164302837  0.04065647909603118
      工位pan：    position:
      x: -4.9372871840425
      y: -2.7806453134428457
      z: 0.572149015528141
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --real-robot-ok -4.9372871840425 -2.7806453134428457  0.572149015528141
只使用 `x/y/z`，目标朝向当前不参与 FAR planner。

检查规划和控制：

```bash
ros2 topic echo /way_point_global
ros2 topic echo /way_point
ros2 topic echo /cmd_vel
```

正常：

```text
/way_point_global 有 map 坐标航点
/way_point 有 camera_init 坐标航点
/cmd_vel 有合理速度
```

Foxglove 可视化：

```text
Fixed Frame: map
/goal_point        目标点，PointStamped
/way_point_global  FAR 当前输出的全局航点，PointStamped
/viz_path_topic    FAR 全局规划路径，Marker/LINE_STRIP
/viz_graph_topic   FAR 可见图，MarkerArray
/graph_decoder_viz 解码后的可见图，MarkerArray
```

如果看不到这些 topic，先确认已经用 `--route-planner` 启动导航；只启动 FAST-LIO 建图时不会有这些规划话题。

## Step 6. 添加禁行区

6.1 添加prior graph

docker exec -it mid360_go2_nav_humble bash -lc '
source /opt/ros/humble/setup.bash
source /workspace/autonomy-go2-mid360/workspace/install/setup.bash
ros2 topic pub --once /read_file_dir std_msgs/msg/String "{data: /workspace/autonomy-go2-mid360/workspace/prior_graphs/my_prior_graph_1.vgh}"
'

前提：

```text
Step 3 重定位和规划已经启动
localPlanner 正在运行
统一使用开发容器 mid360_go2_nav_humble
```

禁行区通过 `/navigation_boundary` 发布给 `localPlanner`：

```text
话题: /navigation_boundary
类型: geometry_msgs/msg/PolygonStamped
规划输入: 是
可视化输入: 不一定明显
```

`localPlanner` 最终按 `camera_init` 数值坐标使用边界。脚本支持两种输入：

```text
--frame camera_init  直接发布 camera_init 坐标
--frame map          输入 map 坐标，脚本读取 TF 后转换到 camera_init 再发布
```

### Step 6.1 使用 camera_init 坐标添加禁行区

适合临时测试，或者已经知道禁行区在当前 `camera_init` 下的位置。

例如：在狗前方约 2m 处添加一个 `1m x 1m` 的禁行区：

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/publish_navigation_boundary.sh \
  --container mid360_go2_nav_humble \
  --frame camera_init \
  --points "1.5,-0.5,0; 2.5,-0.5,0; 2.5,0.5,0; 1.5,0.5,0" \
  --repeat 5 \
  --rate 2
```

含义：

```text
x = 1.5 到 2.5，中心在狗前方约 2m
y = -0.5 到 0.5，左右宽度约 1m
z = 0，保持同一高度，localPlanner 才会连成闭合边界
```

注意：`camera_init` 是当前定位链路的局部世界坐标，不是实时跟随狗身体的 `base_link` 坐标。狗移动后，这个禁行区会留在原来的 `camera_init` 位置，不会跟着狗移动。

### Step 6.2 使用 map 坐标添加禁行区

适合把禁行区作为场景标注保存下来。输入 `map` 坐标后，脚本会读取当前 TF，把点转换成 `camera_init` 后发布到 `/navigation_boundary`。

示例：

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/publish_navigation_boundary.sh \
  --container mid360_go2_nav_humble \
  --frame map \
  --points "10.0,2.0,0; 11.0,2.0,0; 11.0,3.0,0; 10.0,3.0,0" \
  --repeat 5 \
  --rate 2
```

如果 TF 还没有准备好，可以加长等待时间：

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/publish_navigation_boundary.sh \
  --container mid360_go2_nav_humble \
  --frame map \
  --points "10.0,2.0,0; 11.0,2.0,0; 11.0,3.0,0; 10.0,3.0,0" \
  --wait-tf 10 \
  --repeat 5 \
  --rate 2
```

### Step 6.3 调试和检查

只生成消息、不发布：

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/publish_navigation_boundary.sh \
  --container mid360_go2_nav_humble \
  --frame camera_init \
  --points "1.5,-0.5,0; 2.5,-0.5,0; 2.5,0.5,0; 1.5,0.5,0" \
  --dry-run
```

检查 `localPlanner` 是否订阅了禁行区：

```bash
docker exec -it mid360_go2_nav_humble bash -lc \
  'source /opt/ros/humble/setup.bash; ros2 topic info -v /navigation_boundary'
```

正常应看到：

```text
Subscription count > 0
Node name: localPlanner
```

如果要用 `ros2 topic echo --once` 看内容，必须先开 echo，再重新发布禁行区；`/navigation_boundary` 不是持久化消息，发布完以后再 echo 通常看不到历史消息。

终端 1：

```bash
docker exec -it mid360_go2_nav_humble bash -lc \
  'source /opt/ros/humble/setup.bash; ros2 topic echo --once /navigation_boundary'
```

终端 2 重新发布：

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/publish_navigation_boundary.sh \
  --container mid360_go2_nav_humble \
  --frame camera_init \
  --points "1.5,-0.5,0; 2.5,-0.5,0; 2.5,0.5,0; 1.5,0.5,0" \
  --repeat 5 \
  --rate 2
```

Foxglove 中建议叠加查看：

```text
Fixed Frame: camera_init
/navigation_boundary  禁行边界，PolygonStamped
/free_paths           localPlanner 候选可行路径
/path 或 /path_1      当前路径
/terrain_map          原始局部障碍物/地形点云
/terrain_map_ext      扩展地形点云
```

如果 Foxglove 里 `/navigation_boundary` 显示不明显，这是正常现象；它主要是规划输入，不是专门的可视化 marker。真正判断是否生效，优先看 `/free_paths` 和 `/path_1` 是否避开该边界区域。

读取当前机器人的 `camera_init` 坐标：

```bash
docker exec -it mid360_go2_nav_humble bash -lc \
  'source /opt/ros/humble/setup.bash; ros2 topic echo --once /state_estimation --field pose.pose.position'
```

读取当前机器人的 `map` 坐标：

```bash
docker exec -it mid360_go2_nav_humble bash -lc \
  'source /opt/ros/humble/setup.bash; ros2 topic echo --once /baselink2map --field pose.pose.position'
```


### 7-7 公司禁行区
办公室走廊2：
  pose:
    position:
      x: 1.8767804353761415
      y: 4.127921029030081
      z: 0.026332603393748374
办公室走廊1：
    position:
      x: 1.8277126900639646
      y: 2.457399238569214
      z: -0.26026573844479095
工位过道：
  pose:
    position:
      x: -2.081056258170555
      y: -1.580222566242443
      z: 0.39943501287450583
工位区域-展厅边角：
  pose:
    position:
      x: -14.23652655966361
      y: 0.10343188596838332
      z: 1.558082286654045
工位区域1-展厅侧墙角：
x: -15.8449838157195
y: 0.9723376435321327
z: -0.5445926571880504

展厅门口：
  pose:
    position:
      x: -15.013158477197274
      y: 6.903468049960187
      z: 1.6250037558384887

机房饮水机拐角：
point:
  x: -11.847021621407087
  y: 27.574120166716575
  z: 0.0

工位区域2办公室口拐角：
    position:
      x: 5.216659234737864
      y: 24.36297925031263
      z: -0.21720462005681207




构成对应的禁止通行区：

### 工位区域导航边界：
bash /home/unitree/go2-fast-lio/nav_workspace/autonomy-go2-mid360/scripts/publish_navigation_boundary.sh \
  --container mid360_go2_nav_humble \
  --frame map \
  --points "1.8767804353761415,4.127921029030081,0;1.8277126900639646,2.457399238569214,0; -2.081056258170555,-1.580222566242443,0; -14.23652655966361,0.10343188596838332,0; -15.013158477197274,6.903468049960187,0" \
  --wait-tf 10 \
  --repeat 10 \
  --rate 2

### 公司范围的导航边界：
bash /home/unitree/go2-fast-lio/nav_workspace/autonomy-go2-mid360/scripts/publish_navigation_boundary.sh \
  --container mid360_go2_nav_humble \
  --frame map \
  --points "1.8767804353761415,4.127921029030081,0.026332603393748374;1.8277126900639646,2.457399238569214,-0.26026573844479095;-2.081056258170555,-1.580222566242443,0.39943501287450583;-14.23652655966361,0.10343188596838332,1.558082286654045;-15.8449838157195,0.9723376435321327,-0.5445926571880504;-15.013158477197274,6.903468049960187,1.6250037558384887;-11.847021621407087,27.574120166716575, 0.0; 5.216659234737864,24.36297925031263,-0.21720462005681207" \
  --wait-tf 10 \
  --repeat 10 \
  --rate 2

## Step 7. 真机运动

前提：

```text
重定位稳定
Foxglove 中当前位置准确
目标点方向正确
/cmd_vel 方向和速度合理
```

环境：宿主机。

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/start_nav.sh \
  --global-localization \
  --route-planner \
  --map-file /workspace/maps/aaa-fuck-magic-company_20260630_100336.pcd \
  --real-robot \
  --max-speed 0.8 \
  --max-yaw-rate 80.0 \
  --auto-disarm-on-goal \
  --no-rviz
```

急停：优先 `Ctrl-C` 停止导航，必要时用宇树遥控器接管。

真机连续目标点测试时，发送新目标推荐使用：

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --reset-graph --real-robot-ok X Y Z
```

不要随意使用 `--force`。只有确认当前目标要被覆盖时才使用；否则旧 `/way_point_global` 和新目标状态可能混在一起，表现为全局航点跳动，进而让 `/cmd_vel.angular.z` 来回切换。

## 常用检查

查看关键 topic：

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/check_topics.sh
```

查看 TF：

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/check_tf_tree.sh
```

确认配置：

```bash
docker exec mid360_go2_nav_humble bash -lc \
  'grep -n "point_filter_num\|filter_size_surf\|filter_size_map\|dense_publish_en\|extrinsic_R" /workspace/nav_ws/fast-lio-mid360/config/unitree_go2_fastlio_autonomy.yaml && grep -n "voxelsize_coarse\|voxelsize_fine" /workspace/nav_ws/src/fast/open3d_loc/config/loc_param_go2.yaml'
```

确认残留进程：

```bash
docker exec mid360_go2_nav_humble bash -lc \
  'pgrep -af "[f]astlio_mapping|[g]lobal_localization|[l]ocalPlanner|[p]athFollower|[f]oxglove_bridge" || true'
```
