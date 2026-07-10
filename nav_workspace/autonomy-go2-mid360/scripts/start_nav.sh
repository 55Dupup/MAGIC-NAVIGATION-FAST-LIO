#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DOCKER_CMD="${DOCKER_CMD:-docker}"
CONTAINER_NAME="${CONTAINER_NAME:-mid360_go2_nav_humble}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace/autonomy-go2-mid360/workspace}"

REAL_ROBOT=false
ROUTE_PLANNER=false
GLOBAL_LOCALIZATION=false
FOXGLOVE=false
FOXGLOVE_AUTO=true
TERRAIN_EXT=false
RVIZ=false
AUTONOMY_MODE=true
AUTO_INITIALPOSE=true
AUTO_DISARM_ON_GOAL=false
AUTO_DISARM_STOP_COUNT="20"
INITIALPOSE_X="0.0"
INITIALPOSE_Y="0.0"
INITIALPOSE_Z="0.0"
INITIALPOSE_YAW="0.0"
MAX_SPEED="0.3"
MAX_YAW_RATE="30.0"
MAP_FILE="/workspace/maps/company_001-test_20260519_195622.pcd"
# Go2 MID360 factory relocation config:
# /unitree/module/unitree_slam/config/pl_relocation/mid360.yaml
# Go2 pose_imu_lidar tx = 0.1870. Upstream autonomy_stack_go2 L1 default is 0.30.
SENSOR_OFFSET_X="0.187"
SENSOR_OFFSET_Y="0.0"

docker_cmd() {
  # shellcheck disable=SC2086
  ${DOCKER_CMD} "$@"
}

usage() {
  cat <<'EOF'
Usage: bash start_nav.sh [options]

Launch the autonomy_stack_go2 navigation layer with FAST-LIO/MID360 inputs.

Options:
  --real-robot             Publish Unitree /api/sport/request commands
  --no-real-robot          Only publish /cmd_vel. Default
  --route-planner          Include FAR route planner
  --global-localization    Include Open3D PCD global relocalization
                           Also starts Foxglove by default unless --no-foxglove is set
  --map-file FILE          PCD map path inside container. Default: /workspace/maps/company_001-test_20260519_195622.pcd
  --foxglove               Start foxglove_bridge on port 9001
  --no-foxglove            Do not start foxglove_bridge
  --terrain-ext            Include terrain_analysis_ext
  --rviz                   Start RViz
  --no-rviz                Do not start RViz. Default
  --autonomy-mode          Enable autonomous speed in localPlanner/pathFollower. Default
  --manual-speed-gate      Keep upstream joystick/speed gate behavior
  --auto-disarm-on-goal    After /far_reach_goal_status=true, send StopMove then stop publishing sport requests
  --no-auto-disarm-on-goal Keep publishing sport requests after goal completion. Default
  --auto-disarm-stop-count N
                           Number of StopMove requests before sport control release. Default: 20
  --auto-initialpose       Auto publish /initialpose at startup. Default
  --no-auto-initialpose    Do not auto publish startup /initialpose
  --initialpose X Y Z YAW  Startup robot pose in map. Yaw is radians. Default: 0 0 0 0
  --initialpose-x M        Startup initialpose X in map. Default: 0.0
  --initialpose-y M        Startup initialpose Y in map. Default: 0.0
  --initialpose-z M        Startup initialpose Z in map. Default: 0.0
  --initialpose-yaw RAD    Startup initialpose yaw in map. Default: 0.0
  --max-speed MPS          Planner max speed. Default: 0.3
  --max-yaw-rate DEG_S     Path follower max yaw rate. Default: 30.0
  --sensor-offset-x M      Sensor X offset used by planner. Default: 0.187
  --sensor-offset-y M      Sensor Y offset used by planner. Default: 0.0
  -h, --help               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --real-robot)
      REAL_ROBOT=true
      shift
      ;;
    --no-real-robot)
      REAL_ROBOT=false
      shift
      ;;
    --route-planner)
      ROUTE_PLANNER=true
      TERRAIN_EXT=true
      shift
      ;;
    --global-localization)
      GLOBAL_LOCALIZATION=true
      shift
      ;;
    --foxglove)
      FOXGLOVE=true
      FOXGLOVE_AUTO=false
      shift
      ;;
    --no-foxglove)
      FOXGLOVE=false
      FOXGLOVE_AUTO=false
      shift
      ;;
    --map-file)
      MAP_FILE="$2"
      shift 2
      ;;
    --terrain-ext)
      TERRAIN_EXT=true
      shift
      ;;
    --rviz)
      RVIZ=true
      shift
      ;;
    --no-rviz)
      RVIZ=false
      shift
      ;;
    --autonomy-mode)
      AUTONOMY_MODE=true
      shift
      ;;
    --manual-speed-gate)
      AUTONOMY_MODE=false
      shift
      ;;
    --auto-disarm-on-goal)
      AUTO_DISARM_ON_GOAL=true
      shift
      ;;
    --no-auto-disarm-on-goal)
      AUTO_DISARM_ON_GOAL=false
      shift
      ;;
    --auto-disarm-stop-count)
      AUTO_DISARM_STOP_COUNT="$2"
      shift 2
      ;;
    --auto-initialpose)
      AUTO_INITIALPOSE=true
      shift
      ;;
    --no-auto-initialpose)
      AUTO_INITIALPOSE=false
      shift
      ;;
    --initialpose)
      INITIALPOSE_X="$2"
      INITIALPOSE_Y="$3"
      INITIALPOSE_Z="$4"
      INITIALPOSE_YAW="$5"
      shift 5
      ;;
    --initialpose-x)
      INITIALPOSE_X="$2"
      shift 2
      ;;
    --initialpose-y)
      INITIALPOSE_Y="$2"
      shift 2
      ;;
    --initialpose-z)
      INITIALPOSE_Z="$2"
      shift 2
      ;;
    --initialpose-yaw)
      INITIALPOSE_YAW="$2"
      shift 2
      ;;
    --max-speed)
      MAX_SPEED="$2"
      shift 2
      ;;
    --max-yaw-rate)
      MAX_YAW_RATE="$2"
      shift 2
      ;;
    --sensor-offset-x)
      SENSOR_OFFSET_X="$2"
      shift 2
      ;;
    --sensor-offset-y)
      SENSOR_OFFSET_Y="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${FOXGLOVE_AUTO}" == "true" && "${GLOBAL_LOCALIZATION}" == "true" ]]; then
  FOXGLOVE=true
fi

if ! docker_cmd inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" >/dev/null 2>&1; then
  echo "Container is not running: ${CONTAINER_NAME}" >&2
  echo "Start it first:" >&2
  echo "  bash ${BASE_DIR}/scripts/run_container.sh" >&2
  exit 2
fi

DOCKER_EXEC_ARGS=(exec)
if [[ -t 0 && -t 1 ]]; then
  DOCKER_EXEC_ARGS+=(-it)
fi

docker_cmd "${DOCKER_EXEC_ARGS[@]}" "${CONTAINER_NAME}" bash -lc "
  set -euo pipefail
  set +u
  source /opt/ros/humble/setup.bash
  if [ -f /workspace/nav_ws/install/setup.bash ]; then
    source /workspace/nav_ws/install/setup.bash
  fi
  source '${WORKSPACE_DIR}/install/setup.bash'
  set -u
  export RMW_IMPLEMENTATION=\${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}
  ros2 launch mid360_go2_nav_bridge fastlio_mid360_nav.launch.py \
    real_robot:=${REAL_ROBOT} \
    route_planner:=${ROUTE_PLANNER} \
    global_localization:=${GLOBAL_LOCALIZATION} \
    foxglove:=${FOXGLOVE} \
    map_file:=${MAP_FILE} \
    terrain_ext:=${TERRAIN_EXT} \
    rviz:=${RVIZ} \
    autonomy_mode:=${AUTONOMY_MODE} \
    auto_disarm_on_goal:=${AUTO_DISARM_ON_GOAL} \
    auto_disarm_stop_count:=${AUTO_DISARM_STOP_COUNT} \
    auto_initialpose:=${AUTO_INITIALPOSE} \
    initialpose_x:=${INITIALPOSE_X} \
    initialpose_y:=${INITIALPOSE_Y} \
    initialpose_z:=${INITIALPOSE_Z} \
    initialpose_yaw:=${INITIALPOSE_YAW} \
    max_speed:=${MAX_SPEED} \
    max_yaw_rate:=${MAX_YAW_RATE} \
    sensor_offset_x:=${SENSOR_OFFSET_X} \
    sensor_offset_y:=${SENSOR_OFFSET_Y}
"
