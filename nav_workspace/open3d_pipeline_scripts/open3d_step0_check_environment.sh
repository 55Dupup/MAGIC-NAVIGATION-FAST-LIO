#!/usr/bin/env bash
set -euo pipefail

CONTAINER="unitree_humble_nav"
MAP_PATH="/workspace/nav_ws/maps/kitchen_pro.pcd"
CONFIG_PATH="/workspace/nav_ws/src/fast/open3d_loc/config/loc_param_go2.yaml"
CHECK_INPUT_TOPICS=false
TOPIC_TIMEOUT=5
DOCKER_CMD="${DOCKER_CMD:-docker}"
PIPELINE_RMW_IMPLEMENTATION="${OPEN3D_PIPELINE_RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"
ROS_ENV="cd /workspace/nav_ws && source install/setup.bash && export RMW_IMPLEMENTATION=${PIPELINE_RMW_IMPLEMENTATION}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container)
      if [[ $# -lt 2 ]]; then
        echo "$1 requires a container name"
        exit 2
      fi
      CONTAINER="$2"
      shift 2
      ;;
    --map|--maps)
      if [[ $# -lt 2 ]]; then
        echo "$1 requires a map path inside the container"
        exit 2
      fi
      MAP_PATH="$2"
      shift 2
      ;;
    --config)
      if [[ $# -lt 2 ]]; then
        echo "$1 requires a config path inside the container"
        exit 2
      fi
      CONFIG_PATH="$2"
      shift 2
      ;;
    --check-input-topics)
      CHECK_INPUT_TOPICS=true
      shift
      ;;
    --topic-timeout)
      if [[ $# -lt 2 ]]; then
        echo "$1 requires seconds"
        exit 2
      fi
      TOPIC_TIMEOUT="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: bash open3d_step0_check_environment.sh [--map /workspace/nav_ws/maps/map.pcd] [--config /workspace/nav_ws/src/fast/open3d_loc/config/loc_param_go2.yaml] [--check-input-topics] [--topic-timeout SEC]"
      exit 2
      ;;
  esac
done

docker_cmd() {
  ${DOCKER_CMD} "$@"
}

docker_exec() {
  docker_cmd exec "$@"
}

ok() {
  echo "OK: $*"
}

fail() {
  echo "FAIL: $*" >&2
  exit 2
}

check_container() {
  docker_cmd inspect -f '{{.State.Running}}' "${CONTAINER}" >/dev/null 2>&1 \
    || fail "Docker container is not running or not accessible: ${CONTAINER}"
  running="$(docker_cmd inspect -f '{{.State.Running}}' "${CONTAINER}")"
  [[ "${running}" == "true" ]] || fail "Docker container is not running: ${CONTAINER}"
  ok "container ${CONTAINER} is running"
}

check_workspace() {
  docker_exec "${CONTAINER}" bash -lc "test -d /workspace/nav_ws && test -f /workspace/nav_ws/install/setup.bash" \
    || fail "container workspace is missing /workspace/nav_ws/install/setup.bash"
  ok "container workspace is mounted at /workspace/nav_ws"
}

check_map() {
  docker_exec "${CONTAINER}" bash -lc "test -f '${MAP_PATH}'" \
    || fail "map file not found inside container: ${MAP_PATH}"
  ok "map exists inside container: ${MAP_PATH}"
}

check_ros_packages() {
  docker_exec "${CONTAINER}" bash -lc "${ROS_ENV} && ros2 pkg prefix fast_lio >/dev/null" \
    || fail "ROS2 package not found: fast_lio"
  ok "ROS2 package fast_lio is visible"

  docker_exec "${CONTAINER}" bash -lc "${ROS_ENV} && ros2 pkg prefix open3d_loc >/dev/null" \
    || fail "ROS2 package not found: open3d_loc"
  ok "ROS2 package open3d_loc is visible"
}

check_files() {
  docker_exec "${CONTAINER}" bash -lc "test -f /workspace/nav_ws/src/fast/FAST_LIO/launch/mapping.launch.py" \
    || fail "FAST-LIO launch file is missing"
  ok "FAST-LIO launch file exists"

  docker_exec "${CONTAINER}" bash -lc "test -f '${CONFIG_PATH}'" \
    || fail "Open3D localization config is missing: ${CONFIG_PATH}"
  ok "Open3D localization config exists: ${CONFIG_PATH}"

  docker_exec "${CONTAINER}" bash -lc "test -x /workspace/nav_ws/build/fast_lio/fastlio_mapping" \
    || fail "FAST-LIO executable is missing or not executable"
  ok "FAST-LIO executable exists"
}

check_launch_parse() {
  docker_exec "${CONTAINER}" bash -lc "${ROS_ENV} && ros2 launch fast_lio mapping.launch.py --show-args >/tmp/open3d_step0_fastlio_launch_args.log" \
    || fail "FAST-LIO launch file could not be parsed"
  ok "FAST-LIO launch file parses"
}

check_tmux() {
  if docker_exec "${CONTAINER}" bash -lc "command -v tmux >/dev/null 2>&1"; then
    ok "tmux is available in the container"
  else
    ok "tmux is not available; step1 will use PID-file detached mode"
  fi
}

check_existing_processes() {
  conflicts="$(
    docker_exec "${CONTAINER}" bash -lc \
      "pgrep -af '[r]os2 launch fast_lio mapping.launch.py|[f]astlio_mapping|[g]lobal_localization_node' || true"
  )"
  if [[ -n "${conflicts}" ]]; then
    echo "WARN: existing FAST-LIO/Open3D localization process detected:"
    echo "${conflicts}"
    echo "WARN: open3d_step1_start_fastlio_open3d_loc.sh will refuse to start another copy unless --allow-existing-fastlio is used."
  else
    ok "no existing FAST-LIO/Open3D localization process detected"
  fi
}

check_input_topics() {
  docker_exec "${CONTAINER}" bash -lc "${ROS_ENV} && timeout '${TOPIC_TIMEOUT}' ros2 topic echo --once /unitree/slam_lidar/points >/dev/null" \
    || fail "no sample received from /unitree/slam_lidar/points"
  ok "received one /unitree/slam_lidar/points sample"

  docker_exec "${CONTAINER}" bash -lc "${ROS_ENV} && timeout '${TOPIC_TIMEOUT}' ros2 topic echo --once /unitree/slam_lidar/imu >/dev/null" \
    || fail "no sample received from /unitree/slam_lidar/imu"
  ok "received one /unitree/slam_lidar/imu sample"
}

echo "Checking FAST-LIO/Open3D localization environment"
echo "Container: ${CONTAINER}"
echo "Map: ${MAP_PATH}"
echo "Open3D config: ${CONFIG_PATH}"
echo "Container RMW_IMPLEMENTATION: ${PIPELINE_RMW_IMPLEMENTATION}"

check_container
check_workspace
check_map
check_ros_packages
check_files
check_launch_parse
check_tmux
check_existing_processes

if [[ "${CHECK_INPUT_TOPICS}" == "true" ]]; then
  check_input_topics
else
  echo "SKIP: live input topic check. Add --check-input-topics after LiDAR input is running."
fi

echo "Environment check passed."
