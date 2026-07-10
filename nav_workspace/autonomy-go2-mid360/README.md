# MID360 FAST-LIO + autonomy_stack_go2 navigation

This folder is an isolated integration workspace. It does not modify the
existing FAST-LIO workspace, `fast-lio-mid360`, or the current Unitree step
scripts.

Goal:

1. Keep the current MID360 + FAST-LIO mapping/localization chain.
2. Reuse the navigation and planning layer from
   `jizhang-cmu/autonomy_stack_go2`.
3. Run the new autonomy layer in a separate ROS2 Humble Docker container.

## Architecture

Recommended data path:

```text
MID360 driver + FAST-LIO container
  /Odometry_loc
  /cloud_registered_1
          |
          v
mid360_go2_nav_bridge
  /state_estimation
  /registered_scan
          |
          v
autonomy_stack_go2 navigation layer
  local_planner
  terrain_analysis
  optional terrain_analysis_ext
  optional far_planner
          |
          v
  /cmd_vel and, when enabled, /api/sport/request
```

The integration intentionally does not start `point_lio_unilidar`. FAST-LIO is
the state estimator, and the bridge only adapts topic names and frame IDs to
what the autonomy stack expects.

## Files

- `docker/Dockerfile.humble`: ROS2 Humble image with build dependencies.
- `scripts/build_image.sh`: builds the isolated Docker image.
- `scripts/run_container.sh`: creates or starts the isolated Docker container.
- `scripts/setup_workspace.sh`: clones and builds `autonomy_stack_go2` plus the
  local bridge package inside the container.
- `scripts/start_nav.sh`: launches the FAST-LIO bridge and autonomy navigation.
- `scripts/check_topics.sh`: checks the required input/output topics.
- `workspace/src/mid360_go2_nav_bridge`: local ROS2 package with bridge node and
  launch files.

## Build

Run these from the repository root on the host:

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/build_image.sh
bash nav_workspace/autonomy-go2-mid360/scripts/run_container.sh
```

`run_container.sh` defaults to a non-privileged container with host networking.
Host networking is needed for ROS2 DDS topic discovery between FAST-LIO,
Unitree topics, and the autonomy layer. Extra device access is opt-in:

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/run_container.sh --dev-input
bash nav_workspace/autonomy-go2-mid360/scripts/run_container.sh --privileged
```

On this Go2 machine, an existing local Humble image can be used when Docker Hub
is slow or unavailable:

```bash
BASE_IMAGE=unitree_humble_dev:latest \
INSTALL_APT_DEPS=0 \
INSTALL_PIP_DEPS=0 \
bash nav_workspace/autonomy-go2-mid360/scripts/build_image.sh
```

Then enter the container:

```bash
docker exec -it mid360_go2_nav_humble bash
```

Inside the container:

```bash
cd /workspace/autonomy-go2-mid360
bash scripts/setup_workspace.sh
```

If `rosdep update` is blocked by network access, skip it and build with the
dependencies already present in the image:

```bash
SKIP_ROSDEP=1 CLEAN_CMAKE_CACHE=1 bash scripts/setup_workspace.sh
```

If GitHub access from Docker is blocked but the host proxy works, clone the
upstream repo on the host first:

```bash
env http_proxy=http://127.0.0.1:7896 \
  https_proxy=http://127.0.0.1:7896 \
  git clone --branch foxy-humble --depth 1 \
  https://github.com/jizhang-cmu/autonomy_stack_go2.git \
  nav_workspace/autonomy-go2-mid360/workspace/src/autonomy_stack_go2
```

If Docker requires sudo on your host, set:

```bash
DOCKER_CMD="sudo docker"
```

The upstream repository notes that real-robot use is best tested on Foxy, while
Humble can show larger DDS delay on some external-computer setups. This folder
uses Humble because it keeps the new work isolated from the existing onboard
Foxy environment. Before real motion, check delay in RViz and keep speed low.

## Run

Start the existing MID360 + FAST-LIO chain first. For the current Unitree Go2
setup, use the isolated script from the previous folder:

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/start_fastlio_unitree_for_nav.sh
```

Press `s` to start FAST-LIO. Do not press `q` while using navigation; `q` saves
the map and stops FAST-LIO.

In another terminal, launch the autonomy layer:

```bash
DOCKER_CMD="sudo docker" bash nav_workspace/autonomy-go2-mid360/scripts/start_nav.sh
```

Before enabling real robot motion, start in command-preview mode:

```bash
DOCKER_CMD="sudo docker" bash nav_workspace/autonomy-go2-mid360/scripts/start_nav.sh --no-real-robot
```

In this mode the planner publishes `/cmd_vel`, but `pathFollower` should not
send `/api/sport/request` to Go2.

When `/cmd_vel` looks safe and the local terrain map is correct, enable real
robot output:

```bash
DOCKER_CMD="sudo docker" bash nav_workspace/autonomy-go2-mid360/scripts/start_nav.sh --real-robot
```

Optional route planner:

```bash
DOCKER_CMD="sudo docker" bash nav_workspace/autonomy-go2-mid360/scripts/start_nav.sh --route-planner --real-robot
```

## Verify

With FAST-LIO running:

```bash
DOCKER_CMD="sudo docker" bash nav_workspace/autonomy-go2-mid360/scripts/check_topics.sh
```

Required upstream topics:

- `/Odometry_loc`
- `/cloud_registered_1`

Bridge output topics:

- `/state_estimation`
- `/registered_scan`

Navigation output topics:

- `/cmd_vel`
- `/api/sport/request` only when `--real-robot` is used

To test startup with an existing FAST-LIO PCD map without moving the robot:

```bash
DOCKER_CMD="sudo docker" \
TEST_SECONDS=8 \
bash nav_workspace/autonomy-go2-mid360/scripts/test_nav_with_pcd_map.sh \
  /home/unitree/maps/company_001-test_20260519_195622.pcd
```

This starts the autonomy layer with `real_robot:=false`, publishes a static
`/Odometry_loc`, replays the PCD as `/cloud_registered_1`, verifies
`/state_estimation` and `/registered_scan`, then restarts the isolated
container to clear the temporary test processes.

To check the live TF tree after FAST-LIO and the autonomy layer are running:

```bash
DOCKER_CMD="sudo docker" \
bash nav_workspace/autonomy-go2-mid360/scripts/check_tf_tree.sh
```

The expected frame chain is:

```text
map -> camera_init -> aft_mapped -> sensor -> vehicle
                                      |
                                      v
                                    camera
```

`camera_init -> aft_mapped` is the dynamic odometry transform expected by the
autonomy stack. The current FAST-LIO build publishes `camera_init -> body`
itself, so the bridge converts the FAST-LIO body pose to the expected sensor
pose using the configured X/Y offset, then publishes
`camera_init -> aft_mapped` without modifying FAST-LIO source.

## Parameters to tune

Start conservatively:

```bash
bash nav_workspace/autonomy-go2-mid360/scripts/start_nav.sh \
  --no-real-robot \
  --max-speed 0.3 \
  --sensor-offset-x 0.187 \
  --sensor-offset-y 0.0
```

Important launch parameters:

- `sensor_offset_x`, `sensor_offset_y`: sensor position relative to vehicle
  center used by the planner. The default `sensor_offset_x=0.187` follows the
  Go2 MID360 factory relocation config
  `/unitree/module/unitree_slam/config/pl_relocation/mid360.yaml`
  (`pose_imu_lidar` translation x). The bridge uses the same X/Y values to
  convert FAST-LIO's IMU/body odometry pose into the sensor pose expected by
  `localPlanner`. The upstream L1 example used `0.30`.
- `max_speed`: cap before sending Go2 commands.
- `real_robot`: whether `pathFollower` sends `/api/sport/request`.
- `route_planner`: whether FAR planner is included.
- `terrain_ext`: whether terrain analysis extension is included.

## Safety rules

- Do not run the existing `step5_run_nav_client.sh` while this autonomy stack is
  sending real robot commands. Both can command Go2.
- Do not run `point_lio_unilidar` together with FAST-LIO for this integration.
- Start with `--no-real-robot`; verify `/cmd_vel` and RViz before enabling
  `/api/sport/request`.
- Keep `max_speed` low for the first real-robot tests.

## Alternative path

It is possible to modify `point_lio_unilidar` to consume MID360 instead of Go2
L1 lidar, but that duplicates a working state-estimation layer. The lower-risk
path is to keep FAST-LIO and bridge into the autonomy stack.
