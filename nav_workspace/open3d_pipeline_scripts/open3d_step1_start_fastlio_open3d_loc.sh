#!/usr/bin/env bash
set -euo pipefail

CONTAINER="unitree_humble_nav"
MAP_PATH="/workspace/nav_ws/maps/kitchen_pro.pcd"
CONFIG_PATH="/workspace/nav_ws/src/fast/open3d_loc/config/loc_param_go2.yaml"
DRY_RUN=false
ALLOW_EXISTING_FASTLIO=false
INITIALPOSE="0.0,0.0,0.0,0.0,0.0,0.0"
SESS_FASTLIO="open3d_fastlio"
SESS_LOC="open3d_localization"
SESS_TF_IMU="open3d_tf_imu_base"
SESS_TF_MOTION="open3d_tf_base_motion"
LOG_FASTLIO="/tmp/open3d_fastlio.log"
LOG_TF_IMU="/tmp/open3d_tf_imu_base.log"
LOG_TF_MOTION="/tmp/open3d_tf_base_motion.log"
LOG_LOC="/tmp/open3d_localization.log"
PID_DIR="/tmp/open3d_pipeline_pids"
WAIT_TOPIC_TIMEOUT=30
DOCKER_CMD="${DOCKER_CMD:-docker}"
PIPELINE_RMW_IMPLEMENTATION="${OPEN3D_PIPELINE_RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"
# Go2 + MID360 外参，来自宇树原厂 Go2 重定位配置：
# /unitree/module/unitree_slam/config/pl_relocation/mid360.yaml
# pose_imu_lidar: [qw, qx, qy, qz, tx, ty, tz] = [1, 0, 0, 0, 0.1870, 0, 0.0803]
# 这里按 ROS2 static_transform_publisher 格式发布 base_link -> imu_link:
# [x, y, z, qx, qy, qz, qw]。
BASE_TO_IMU_X="${OPEN3D_BASE_TO_IMU_X:-${OPEN3D_IMU_TO_BASE_X:-0.1870}}"
BASE_TO_IMU_Y="${OPEN3D_BASE_TO_IMU_Y:-${OPEN3D_IMU_TO_BASE_Y:-0.0}}"
BASE_TO_IMU_Z="${OPEN3D_BASE_TO_IMU_Z:-${OPEN3D_IMU_TO_BASE_Z:-0.0803}}"
BASE_TO_IMU_QX="${OPEN3D_BASE_TO_IMU_QX:-${OPEN3D_IMU_TO_BASE_QX:-0.0}}"
BASE_TO_IMU_QY="${OPEN3D_BASE_TO_IMU_QY:-${OPEN3D_IMU_TO_BASE_QY:-0.0}}"
BASE_TO_IMU_QZ="${OPEN3D_BASE_TO_IMU_QZ:-${OPEN3D_IMU_TO_BASE_QZ:-0.0}}"
BASE_TO_IMU_QW="${OPEN3D_BASE_TO_IMU_QW:-${OPEN3D_IMU_TO_BASE_QW:-1.0}}"

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
    --initialpose)
      if [[ $# -lt 2 ]]; then
        echo "$1 requires x,y,z,roll,pitch,yaw"
        exit 2
      fi
      INITIALPOSE="$2"
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
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --allow-existing-fastlio)
      ALLOW_EXISTING_FASTLIO=true
      shift
      ;;
    --wait-topic-timeout)
      if [[ $# -lt 2 ]]; then
        echo "$1 requires seconds"
        exit 2
      fi
      WAIT_TOPIC_TIMEOUT="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: bash open3d_step1_start_fastlio_open3d_loc.sh [--map /workspace/nav_ws/maps/map.pcd] [--config /workspace/nav_ws/src/fast/open3d_loc/config/loc_param_go2.yaml] [--initialpose x,y,z,roll,pitch,yaw] [--wait-topic-timeout SEC] [--allow-existing-fastlio] [--dry-run]"
      exit 2
      ;;
  esac
done

normalize_initialpose() {
  local value="$1"
  /usr/bin/python3 - "$value" <<'PY'
import sys

text = sys.argv[1]
parts = [part.strip() for part in text.split(",")]
if len(parts) != 6:
    raise SystemExit("initialpose must contain exactly 6 comma-separated values: x,y,z,roll,pitch,yaw")

try:
    values = [float(part) for part in parts]
except ValueError as exc:
    raise SystemExit(f"initialpose contains a non-numeric value: {text}") from exc

print(",".join(f"{value:.6f}" for value in values))
PY
}

if ! INITIALPOSE="$(normalize_initialpose "${INITIALPOSE}")"; then
  echo "Invalid --initialpose: ${INITIALPOSE}" >&2
  exit 2
fi

ENV_CMD="cd /workspace/nav_ws && source install/setup.bash && export RMW_IMPLEMENTATION=${PIPELINE_RMW_IMPLEMENTATION}"
FASTLIO_CMD="${ENV_CMD} && ros2 launch fast_lio mapping.launch.py"
TF_IMU_CMD="${ENV_CMD} && ros2 run tf2_ros static_transform_publisher ${BASE_TO_IMU_X} ${BASE_TO_IMU_Y} ${BASE_TO_IMU_Z} ${BASE_TO_IMU_QX} ${BASE_TO_IMU_QY} ${BASE_TO_IMU_QZ} ${BASE_TO_IMU_QW} base_link imu_link"
TF_MOTION_CMD="${ENV_CMD} && ros2 run tf2_ros static_transform_publisher 0 0 0 0 0 0 1 base_link motion_link"
OPEN3D_CMD="${ENV_CMD} && ros2 run open3d_loc global_localization_node --ros-args --params-file ${CONFIG_PATH} -p path_map:=${MAP_PATH} -p initialpose:=[${INITIALPOSE}]"

docker_cmd() {
  ${DOCKER_CMD} "$@"
}

docker_exec() {
  docker_cmd exec "$@"
}

stop_pid_file() {
  local name="$1"
  local pid_file="${PID_DIR}/${name}.pid"
  docker_exec "${CONTAINER}" bash -lc "
    if [[ -f '${pid_file}' ]]; then
      pid=\$(cat '${pid_file}' 2>/dev/null || true)
      if [[ -n \"\${pid}\" ]] && kill -0 \"\${pid}\" 2>/dev/null; then
        kill -- -\"\${pid}\" 2>/dev/null || kill \"\${pid}\" 2>/dev/null || true
        sleep 0.5
        kill -9 -- -\"\${pid}\" 2>/dev/null || true
      fi
      rm -f '${pid_file}'
    fi
  "
}

start_detached_with_pid() {
  local name="$1"
  local command="$2"
  local log_file="$3"
  local pid_file="${PID_DIR}/${name}.pid"
  docker_exec -d "${CONTAINER}" bash -lc "mkdir -p '${PID_DIR}' && setsid bash -lc 'echo \$\$ >\"${pid_file}\"; exec bash -lc \"${command}\"' >'${log_file}' 2>&1"
}

require_no_conflicting_processes() {
  if [[ "${ALLOW_EXISTING_FASTLIO}" == "true" ]]; then
    echo "Skipping FAST-LIO/Open3D process conflict check because --allow-existing-fastlio was set."
    return
  fi

  local conflicts
  conflicts="$(
    docker_exec "${CONTAINER}" bash -lc \
      "pgrep -af '[r]os2 launch fast_lio mapping.launch.py|[f]astlio_mapping|[g]lobal_localization_node' || true"
  )"
  if [[ -n "${conflicts}" ]]; then
    echo "Existing FAST-LIO/Open3D localization process detected in container:" >&2
    echo "${conflicts}" >&2
    echo "Stop it first, or rerun with --allow-existing-fastlio if you intentionally want to manage the conflict yourself." >&2
    exit 5
  fi
}

require_no_host_unitree_slam_conflicts() {
  local tmux_conflicts=()
  for session in go2_slam go2_lidar go2_relocation; do
    if tmux has-session -t "${session}" 2>/dev/null; then
      tmux_conflicts+=("${session}")
    fi
  done

  local process_conflicts
  process_conflicts="$(
    ps -eo pid=,args= | awk '
      /(^|[ \\/])(unitree_slam|keyDemo_changemap)([ ]|$)/ &&
      $0 !~ /awk/ {
        print
      }
    '
  )"

  if [[ ${#tmux_conflicts[@]} -gt 0 || -n "${process_conflicts}" ]]; then
    echo "Conflicting Unitree original SLAM chain detected on host." >&2
    if [[ ${#tmux_conflicts[@]} -gt 0 ]]; then
      echo "tmux sessions:" >&2
      printf '  %s\n' "${tmux_conflicts[@]}" >&2
    fi
    if [[ -n "${process_conflicts}" ]]; then
      echo "processes:" >&2
      echo "${process_conflicts}" >&2
    fi
    echo "Do not run Unitree original unitree_slam/keyDemo_changemap together with Open3D/FAST-LIO." >&2
    echo "Stop the Unitree original chain first, then restart the Open3D pipeline." >&2
    exit 5
  fi
}

require_container_ready() {
  if ! docker_cmd inspect -f '{{.State.Running}}' "${CONTAINER}" >/dev/null 2>&1; then
    echo "Docker container is not running or is not accessible: ${CONTAINER}" >&2
    echo "Start it first, for example: sudo docker start ${CONTAINER}" >&2
    echo "If your user cannot access Docker, run with: DOCKER_CMD='sudo docker' bash $0 ..." >&2
    exit 2
  fi
  if ! docker_exec "${CONTAINER}" bash -lc "test -d /workspace/nav_ws && test -f /workspace/nav_ws/install/setup.bash"; then
    echo "Container workspace is not ready: /workspace/nav_ws/install/setup.bash is missing." >&2
    exit 2
  fi
  if ! docker_exec "${CONTAINER}" bash -lc "test -f '${MAP_PATH}'"; then
    echo "Map file not found inside container:" >&2
    echo "  ${MAP_PATH}" >&2
    exit 2
  fi
  if ! docker_exec "${CONTAINER}" bash -lc "test -f '${CONFIG_PATH}'"; then
    echo "Open3D localization config not found inside container:" >&2
    echo "  ${CONFIG_PATH}" >&2
    exit 2
  fi
}

wait_for_topic_once() {
  local topic="$1"
  echo "Waiting for ${topic} ..."
  if ! docker_exec "${CONTAINER}" bash -lc "${ENV_CMD} && timeout ${WAIT_TOPIC_TIMEOUT} ros2 topic echo --once ${topic} >/dev/null 2>&1"; then
    echo "Timed out waiting for ${topic}. Check FAST-LIO input and logs before starting Open3D localization."
    exit 4
  fi
}

echo "Container: ${CONTAINER}"
echo "Open3D map: ${MAP_PATH}"
echo "Open3D config: ${CONFIG_PATH}"
echo "Initial pose: [${INITIALPOSE}]"
echo "FAST-LIO tmux session: ${SESS_FASTLIO}"
echo "TF tmux sessions: ${SESS_TF_IMU}, ${SESS_TF_MOTION}"
echo "Go2 base_link -> imu_link TF: xyz=[${BASE_TO_IMU_X}, ${BASE_TO_IMU_Y}, ${BASE_TO_IMU_Z}], qxyzw=[${BASE_TO_IMU_QX}, ${BASE_TO_IMU_QY}, ${BASE_TO_IMU_QZ}, ${BASE_TO_IMU_QW}]"
echo "Open3D tmux session: ${SESS_LOC}"
echo "Detached PID directory: ${PID_DIR}"
echo "Allow existing FAST-LIO/Open3D processes: ${ALLOW_EXISTING_FASTLIO}"
echo "Container RMW_IMPLEMENTATION: ${PIPELINE_RMW_IMPLEMENTATION}"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "Dry-run FAST-LIO command:"
  echo "  ${FASTLIO_CMD}"
  echo "Dry-run static TF commands:"
  echo "  ${TF_IMU_CMD}"
  echo "  ${TF_MOTION_CMD}"
  echo "Dry-run Open3D localization command:"
  echo "  ${OPEN3D_CMD}"
  echo "If tmux is unavailable in the container, commands run detached with logs:"
  echo "  ${LOG_FASTLIO}"
  echo "  ${LOG_TF_IMU}"
  echo "  ${LOG_TF_MOTION}"
  echo "  ${LOG_LOC}"
  echo "Detached mode only stops PIDs previously written under:"
  echo "  ${PID_DIR}"
  exit 0
fi

require_no_host_unitree_slam_conflicts
require_container_ready

if docker_exec "${CONTAINER}" bash -lc "command -v tmux >/dev/null 2>&1"; then
  docker_exec "${CONTAINER}" bash -lc "tmux kill-session -t ${SESS_FASTLIO} 2>/dev/null || true"
  docker_exec "${CONTAINER}" bash -lc "tmux kill-session -t ${SESS_TF_IMU} 2>/dev/null || true"
  docker_exec "${CONTAINER}" bash -lc "tmux kill-session -t ${SESS_TF_MOTION} 2>/dev/null || true"
  docker_exec "${CONTAINER}" bash -lc "tmux kill-session -t ${SESS_LOC} 2>/dev/null || true"
  require_no_conflicting_processes

  docker_exec "${CONTAINER}" bash -lc "tmux new-session -d -s ${SESS_FASTLIO} '${FASTLIO_CMD}'"
  sleep 3
  docker_exec "${CONTAINER}" bash -lc "tmux new-session -d -s ${SESS_TF_IMU} '${TF_IMU_CMD}'"
  docker_exec "${CONTAINER}" bash -lc "tmux new-session -d -s ${SESS_TF_MOTION} '${TF_MOTION_CMD}'"
  sleep 1
  wait_for_topic_once "/Odometry_loc"
  wait_for_topic_once "/cloud_registered_1"
  docker_exec "${CONTAINER}" bash -lc "tmux new-session -d -s ${SESS_LOC} '${OPEN3D_CMD}'"

  echo "Started Open3D localization pipeline with tmux."
  echo "Inspect FAST-LIO:"
  echo "  docker exec -it ${CONTAINER} tmux attach -t ${SESS_FASTLIO}"
  echo "Inspect Open3D localization:"
  echo "  docker exec -it ${CONTAINER} tmux attach -t ${SESS_LOC}"
else
  echo "tmux is not available in container; using detached docker exec mode."
  echo "Only processes previously started by this script are stopped via ${PID_DIR}."
  stop_pid_file "fastlio"
  stop_pid_file "tf_imu_base"
  stop_pid_file "tf_base_motion"
  stop_pid_file "localization"
  require_no_conflicting_processes

  start_detached_with_pid "fastlio" "${FASTLIO_CMD}" "${LOG_FASTLIO}"
  sleep 3
  start_detached_with_pid "tf_imu_base" "${TF_IMU_CMD}" "${LOG_TF_IMU}"
  start_detached_with_pid "tf_base_motion" "${TF_MOTION_CMD}" "${LOG_TF_MOTION}"
  sleep 1
  wait_for_topic_once "/Odometry_loc"
  wait_for_topic_once "/cloud_registered_1"
  start_detached_with_pid "localization" "${OPEN3D_CMD}" "${LOG_LOC}"

  echo "Started Open3D localization pipeline detached."
  echo "Inspect logs:"
  echo "  docker exec ${CONTAINER} tail -n 80 ${LOG_FASTLIO}"
  echo "  docker exec ${CONTAINER} tail -n 80 ${LOG_LOC}"
fi
