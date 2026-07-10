#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOST_NAV_WS="${HOST_NAV_WS:-$(cd "${BASE_DIR}/.." && pwd)}"
CONTAINER_NAV_WS="${CONTAINER_NAV_WS:-/workspace/nav_ws}"
CONTAINER="${CONTAINER:-unitree_humble_nav}"
DOCKER_CMD="${DOCKER_CMD:-docker}"
CONTAINER_LIVOX_WS="${CONTAINER_LIVOX_WS:-${CONTAINER_NAV_WS}/src/ws_livox}"
CONTAINER_FASTLIO_RUNTIME_DIR="${CONTAINER_FASTLIO_RUNTIME_DIR:-${CONTAINER_NAV_WS}/fast-lio-mid360}"

CONFIG_DIR="${CONFIG_DIR:-${BASE_DIR}/config}"
CONFIG_FILE="${CONFIG_FILE:-mid360_fastlio.yaml}"
CONTAINER_CONFIG_DIR="${CONTAINER_CONFIG_DIR:-${CONTAINER_NAV_WS}/fast-lio-mid360/config}"

OUTPUT_DIR="${OUTPUT_DIR:-${BASE_DIR}/maps}"
OUTPUT_NAME="${OUTPUT_NAME:-fastlio_mid360_map}"
NO_DATE=false
DRY_RUN=false

START_DRIVER=true
DRIVER_MODE="${DRIVER_MODE:-livox}"
KEEP_DRIVER=false
DRIVER_SESSION="${DRIVER_SESSION:-fast_lio_mid360_driver}"
MID360_BIN_DIR="${MID360_BIN_DIR:-/unitree/module/unitree_slam/bin}"
LIDAR_DRIVER="${LIDAR_DRIVER:-mid360_driver}"
LIVOX_CONFIG_FILE="${LIVOX_CONFIG_FILE:-MID360_config.json}"
LIVOX_XFER_FORMAT="${LIVOX_XFER_FORMAT:-1}"
LIVOX_PUBLISH_FREQ="${LIVOX_PUBLISH_FREQ:-10.0}"
LIVOX_FRAME_ID="${LIVOX_FRAME_ID:-livox_frame}"
LIVOX_BD_CODE="${LIVOX_BD_CODE:-livox0000000001}"

MAPPING_SESSION="${MAPPING_SESSION:-fast_lio_mid360_mapping}"
FOXGLOVE="${FOXGLOVE:-true}"
RVIZ="${RVIZ:-false}"
SERVICE_TIMEOUT="${SERVICE_TIMEOUT:-120}"
RMW_IMPLEMENTATION_VALUE="${RMW_IMPLEMENTATION_VALUE:-rmw_cyclonedds_cpp}"

DRIVER_STARTED_BY_SCRIPT=false
MAPPING_STARTED=false

usage() {
  cat <<'EOF'
Usage: bash fast_lio_mid360_mapping.sh [options]

Interactive FAST-LIO mapping for a movable MID360 setup.

Keys:
  s                       Start FAST-LIO mapping
  q                       Save map, stop mapping, then quit

Options:
  --output-dir DIR         Host output directory. Default: fast-lio-mid360/maps
  --name NAME              Output base name. Default: fastlio_mid360_map
  --no-date                Do not append YYYYmmdd_HHMMSS
  --container NAME         Docker container. Default: unitree_humble_nav
  --docker-cmd CMD         Docker command. Default: docker
  --config-file NAME       FAST-LIO config file under config/. Default: mid360_fastlio.yaml
  --driver-mode MODE       Driver mode: livox, unitree, external. Default: livox
  --no-driver              Same as --driver-mode external
  --keep-driver            Keep the driver session running after q
  --driver-bin-dir DIR     Host directory containing mid360_driver
  --driver NAME            Driver binary name. Default: mid360_driver
  --livox-config NAME      Livox config JSON under config/. Default: MID360_config.json
  --no-foxglove            Do not start foxglove_bridge from FAST-LIO launch
  --rviz                   Start RViz from FAST-LIO launch if available
  --dry-run                Print resolved commands and exit
  -h, --help               Show this help

Examples:
  bash nav_workspace/fast-lio-mid360/scripts/fast_lio_mid360_mapping.sh
  bash nav_workspace/fast-lio-mid360/scripts/fast_lio_mid360_mapping.sh --driver-mode unitree --config-file unitree_go2_fastlio.yaml
  bash nav_workspace/fast-lio-mid360/scripts/fast_lio_mid360_mapping.sh --output-dir /home/unitree/maps --name factory_floor
  bash nav_workspace/fast-lio-mid360/scripts/fast_lio_mid360_mapping.sh --driver-mode external
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --name)
      OUTPUT_NAME="$2"
      shift 2
      ;;
    --no-date)
      NO_DATE=true
      shift
      ;;
    --container)
      CONTAINER="$2"
      shift 2
      ;;
    --docker-cmd)
      DOCKER_CMD="$2"
      shift 2
      ;;
    --config-file)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --driver-mode)
      DRIVER_MODE="$2"
      shift 2
      ;;
    --no-driver)
      START_DRIVER=false
      DRIVER_MODE="external"
      shift
      ;;
    --keep-driver)
      KEEP_DRIVER=true
      shift
      ;;
    --driver-bin-dir)
      MID360_BIN_DIR="$2"
      shift 2
      ;;
    --driver)
      LIDAR_DRIVER="$2"
      shift 2
      ;;
    --livox-config)
      LIVOX_CONFIG_FILE="$2"
      shift 2
      ;;
    --no-foxglove)
      FOXGLOVE=false
      shift
      ;;
    --rviz)
      RVIZ=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
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

CONFIG_HOST_PATH="${CONFIG_DIR}/${CONFIG_FILE}"
LIVOX_CONFIG_HOST_PATH="${CONFIG_DIR}/${LIVOX_CONFIG_FILE}"
OUTPUT_NAME="${OUTPUT_NAME%.pcd}"
if [[ "${OUTPUT_NAME}" == */* ]]; then
  echo "--name must be a file name, not a path: ${OUTPUT_NAME}" >&2
  exit 2
fi

timestamp="$(date +%Y%m%d_%H%M%S)"
if [[ "${NO_DATE}" == "true" ]]; then
  FINAL_MAP_NAME="${OUTPUT_NAME}.pcd"
else
  FINAL_MAP_NAME="${OUTPUT_NAME}_${timestamp}.pcd"
fi
FINAL_MAP_PATH="${OUTPUT_DIR%/}/${FINAL_MAP_NAME}"

docker_cmd() {
  # shellcheck disable=SC2086
  ${DOCKER_CMD} "$@"
}

docker_exec() {
  # Keep stdin open so heredoc-fed helper scripts passed to `bash -s` actually
  # reach the container. Without -i, those helpers can exit successfully without
  # running, which makes readiness/save checks report false positives.
  docker_cmd exec -i "$@"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

validate_driver_mode() {
  case "${DRIVER_MODE}" in
    livox|unitree|external) ;;
    *) fail "--driver-mode must be one of: livox, unitree, external" ;;
  esac
}

check_prerequisites() {
  [[ -f "${CONFIG_HOST_PATH}" ]] || fail "FAST-LIO config not found: ${CONFIG_HOST_PATH}"
  validate_driver_mode

  if ! docker_running="$(docker_cmd inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)"; then
    fail "Docker container is not accessible: ${CONTAINER}"
  fi
  if [[ "${docker_running}" != "true" ]]; then
    fail "Docker container is not running: ${CONTAINER}"
  fi

  docker_exec "${CONTAINER}" bash -lc "test -f '${CONTAINER_CONFIG_DIR}/${CONFIG_FILE}'" \
    || fail "Config is not visible inside container: ${CONTAINER_CONFIG_DIR}/${CONFIG_FILE}"

  docker_exec "${CONTAINER}" bash -lc "source /opt/ros/humble/setup.bash && cd '${CONTAINER_NAV_WS}' && source install/setup.bash && ros2 pkg prefix fast_lio >/dev/null" \
    || fail "ROS2 package fast_lio is not visible inside container"
  if [[ "${FOXGLOVE}" == "true" ]]; then
    docker_exec "${CONTAINER}" bash -lc "source /opt/ros/humble/setup.bash && cd '${CONTAINER_NAV_WS}' && source install/setup.bash && ros2 pkg prefix foxglove_bridge >/dev/null" \
      || fail "ROS2 package foxglove_bridge is not visible inside container. Rebuild the container or run with --no-foxglove."
  fi

  if [[ "${DRIVER_MODE}" == "livox" ]]; then
    [[ -f "${LIVOX_CONFIG_HOST_PATH}" ]] || fail "Livox config not found: ${LIVOX_CONFIG_HOST_PATH}"
    docker_exec "${CONTAINER}" bash -lc "test -f '${CONTAINER_CONFIG_DIR}/${LIVOX_CONFIG_FILE}'" \
      || fail "Livox config is not visible inside container: ${CONTAINER_CONFIG_DIR}/${LIVOX_CONFIG_FILE}"
    docker_exec "${CONTAINER}" bash -lc "source /opt/ros/humble/setup.bash && source '${CONTAINER_LIVOX_WS}/install/setup.bash' && ros2 pkg prefix livox_ros_driver2 >/dev/null" \
      || fail "ROS2 package livox_ros_driver2 is not visible inside container"
  elif [[ "${DRIVER_MODE}" == "unitree" && "${START_DRIVER}" == "true" ]]; then
    command -v tmux >/dev/null 2>&1 || fail "tmux is required on host to run ${LIDAR_DRIVER}"
    [[ -x "${MID360_BIN_DIR}/${LIDAR_DRIVER}" ]] || fail "MID360 driver is not executable: ${MID360_BIN_DIR}/${LIDAR_DRIVER}"
  fi
}

print_summary() {
  cat <<EOF
FAST-LIO MID360 mapping
  host workspace:       ${HOST_NAV_WS}
  container workspace:  ${CONTAINER_NAV_WS}
  container:            ${CONTAINER}
  runtime dir:          ${CONTAINER_FASTLIO_RUNTIME_DIR}
  fast-lio config:      ${CONFIG_HOST_PATH}
  final map:            ${FINAL_MAP_PATH}
  driver mode:          ${DRIVER_MODE}
  livox config:         ${LIVOX_CONFIG_HOST_PATH}
  unitree driver:       ${MID360_BIN_DIR}/${LIDAR_DRIVER}
  mapping session:      ${MAPPING_SESSION}
EOF
}

start_driver() {
  [[ "${START_DRIVER}" == "true" ]] || return 0
  case "${DRIVER_MODE}" in
    livox)
      start_livox_driver
      ;;
    unitree)
      start_unitree_driver
      ;;
    external)
      return 0
      ;;
  esac
}

start_unitree_driver() {

  for session in go2_slam go2_lidar go2_relocation; do
    if tmux has-session -t "${session}" 2>/dev/null; then
      fail "Conflicting Unitree original SLAM tmux session is running: ${session}"
    fi
  done

  if tmux has-session -t "${DRIVER_SESSION}" 2>/dev/null; then
    echo "MID360 driver session already exists: ${DRIVER_SESSION}"
    return 0
  fi

  tmux new-session -d -s "${DRIVER_SESSION}" \
    "bash --noprofile --norc -lc 'set +u; source /opt/ros/noetic/setup.bash 2>/dev/null || true; cd \"${MID360_BIN_DIR}\"; exec ./\"${LIDAR_DRIVER}\"'"
  DRIVER_STARTED_BY_SCRIPT=true
  echo "Started MID360 driver session: ${DRIVER_SESSION}"
}

start_livox_driver() {
  livox_driver_output="$(
    docker_exec "${CONTAINER}" bash -s -- \
    "${CONTAINER_NAV_WS}" \
    "${CONTAINER_LIVOX_WS}" \
    "${CONTAINER_CONFIG_DIR}/${LIVOX_CONFIG_FILE}" \
    "${DRIVER_SESSION}" \
    "${LIVOX_XFER_FORMAT}" \
    "${LIVOX_PUBLISH_FREQ}" \
    "${LIVOX_FRAME_ID}" \
    "${LIVOX_BD_CODE}" \
    "${RMW_IMPLEMENTATION_VALUE}" <<'EOS'
set -euo pipefail
nav_ws="$1"
livox_ws="$2"
config_path="$3"
session="$4"
xfer_format="$5"
publish_freq="$6"
frame_id="$7"
bd_code="$8"
rmw="$9"
log_dir="${nav_ws}/fast-lio-mid360/logs"
pid_file="/tmp/${session}.pid"
mkdir -p "${log_dir}"

if command -v tmux >/dev/null 2>&1 && tmux has-session -t "${session}" 2>/dev/null; then
  echo "Livox driver session already exists: ${session}"
  echo "STARTED_BY_SCRIPT=0"
  exit 0
fi
if [[ -f "${pid_file}" ]] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
  echo "Livox driver pid already exists: $(cat "${pid_file}")"
  echo "STARTED_BY_SCRIPT=0"
  exit 0
fi
if pgrep -af 'livox_ros_driver2_node' >/dev/null 2>&1; then
  echo "A livox_ros_driver2_node process is already running in the container."
  echo "STARTED_BY_SCRIPT=0"
  exit 0
fi

driver_cmd=(
  ros2 run livox_ros_driver2 livox_ros_driver2_node
  --ros-args
  -p "xfer_format:=${xfer_format}"
  -p "multi_topic:=0"
  -p "data_src:=0"
  -p "publish_freq:=${publish_freq}"
  -p "output_data_type:=0"
  -p "frame_id:=${frame_id}"
  -p "user_config_path:=${config_path}"
  -p "cmdline_input_bd_code:=${bd_code}"
)
quoted_driver="$(printf '%q ' "${driver_cmd[@]}")"
full_cmd="source /opt/ros/humble/setup.bash && source $(printf '%q' "${livox_ws}/install/setup.bash") && export RMW_IMPLEMENTATION=$(printf '%q' "${rmw}") && exec ${quoted_driver}"

if command -v tmux >/dev/null 2>&1; then
  tmux new-session -d -s "${session}" "bash -lc $(printf '%q' "${full_cmd}")"
  echo "Started Livox MID360 driver tmux session: ${session}"
  echo "STARTED_BY_SCRIPT=1"
else
  nohup bash -lc "${full_cmd}" > "${log_dir}/livox_driver.log" 2>&1 < /dev/null &
  echo "$!" > "${pid_file}"
  echo "Started Livox MID360 driver pid: $(cat "${pid_file}")"
  echo "Log: ${log_dir}/livox_driver.log"
  echo "STARTED_BY_SCRIPT=1"
fi
EOS
  )"
  echo "${livox_driver_output}" | sed '/^STARTED_BY_SCRIPT=/d'
  if echo "${livox_driver_output}" | grep -qx 'STARTED_BY_SCRIPT=1'; then
    DRIVER_STARTED_BY_SCRIPT=true
  fi
}

start_mapping() {
  docker_exec "${CONTAINER}" bash -s -- \
    "${CONTAINER_NAV_WS}" \
    "${CONTAINER_LIVOX_WS}" \
    "${CONTAINER_CONFIG_DIR}" \
    "${CONFIG_FILE}" \
    "${MAPPING_SESSION}" \
    "${FOXGLOVE}" \
    "${RVIZ}" \
    "${CONTAINER_FASTLIO_RUNTIME_DIR}" \
    "${RMW_IMPLEMENTATION_VALUE}" <<'EOS' || return 1
set -euo pipefail
nav_ws="$1"
livox_ws="$2"
config_dir="$3"
config_file="$4"
session="$5"
foxglove="$6"
rviz="$7"
runtime_dir="$8"
rmw="$9"
log_dir="${runtime_dir}/logs"
pid_file="/tmp/${session}.pid"
mkdir -p "${runtime_dir}/output" "${log_dir}"

if command -v tmux >/dev/null 2>&1 && tmux has-session -t "${session}" 2>/dev/null; then
  echo "FAST-LIO mapping session already exists: ${session}" >&2
  exit 6
fi
if [[ -f "${pid_file}" ]] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
  pid="$(cat "${pid_file}")"
  stat="$(ps -o stat= -p "${pid}" 2>/dev/null | awk '{print $1}' || true)"
  if [[ -n "${stat}" && "${stat}" != Z* ]]; then
    echo "FAST-LIO mapping pid already exists: ${pid}" >&2
    exit 6
  fi
  rm -f "${pid_file}"
fi
active_mapping_process=false
for pid in $(pgrep -f 'ros2 launch fast_lio mapping.launch.py|fastlio_mapping' || true); do
  stat="$(ps -o stat= -p "${pid}" 2>/dev/null | awk '{print $1}' || true)"
  if [[ -n "${stat}" && "${stat}" != Z* ]]; then
    active_mapping_process=true
    break
  fi
done
if [[ "${active_mapping_process}" == "true" ]]; then
  echo "Another FAST-LIO mapping process is already running in the container." >&2
  exit 6
fi

launch_cmd=(
  ros2 launch fast_lio mapping.launch.py
  "config_path:=${config_dir}"
  "config_file:=${config_file}"
  "foxglove:=${foxglove}"
  "rviz:=${rviz}"
)
quoted_launch="$(printf '%q ' "${launch_cmd[@]}")"
full_cmd="cd $(printf '%q' "${nav_ws}") && source /opt/ros/humble/setup.bash && source install/setup.bash && if [[ -f $(printf '%q' "${livox_ws}/install/setup.bash") ]]; then source $(printf '%q' "${livox_ws}/install/setup.bash"); fi && export RMW_IMPLEMENTATION=$(printf '%q' "${rmw}") && exec ${quoted_launch}"

if command -v tmux >/dev/null 2>&1; then
  tmux new-session -d -s "${session}" "bash -lc $(printf '%q' "${full_cmd}")"
  echo "Started FAST-LIO mapping tmux session: ${session}"
else
  nohup bash -lc "${full_cmd}" > "${log_dir}/mapping.log" 2>&1 < /dev/null &
  echo "$!" > "${pid_file}"
  echo "Started FAST-LIO mapping pid: $(cat "${pid_file}")"
  echo "Log: ${log_dir}/mapping.log"
fi
EOS
  MAPPING_STARTED=true
}

wait_for_mapping_ready() {
  echo "Waiting for FAST-LIO /map_save, /Odometry_loc, and /cloud_registered_1 ..."
  docker_exec "${CONTAINER}" bash -s -- "${CONTAINER_NAV_WS}" "${SERVICE_TIMEOUT}" "${RMW_IMPLEMENTATION_VALUE}" <<'EOS'
set -euo pipefail
nav_ws="$1"
timeout_sec="$2"
rmw="$3"
cd "${nav_ws}"
set +u
source /opt/ros/humble/setup.bash
source install/setup.bash
set -u
export RMW_IMPLEMENTATION="${rmw}"

deadline=$((SECONDS + timeout_sec))
while (( SECONDS < deadline )); do
  service_ready=false
  odom_ready=false
  cloud_ready=false

  if ros2 service list 2>/dev/null | grep -qx '/map_save'; then
    service_ready=true
  fi
  if timeout 2 ros2 topic echo --once /Odometry_loc >/dev/null 2>&1; then
    odom_ready=true
  fi
  if timeout 2 ros2 topic echo --once /cloud_registered_1 >/dev/null 2>&1; then
    cloud_ready=true
  fi

  if [[ "${service_ready}" == "true" && "${odom_ready}" == "true" && "${cloud_ready}" == "true" ]]; then
    exit 0
  fi
  sleep 1
done
echo "Timed out waiting for /map_save, /Odometry_loc, and /cloud_registered_1." >&2
exit 1
EOS
  rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    return "${rc}"
  fi
  echo "FAST-LIO is publishing odometry and registered cloud."
}

read_container_map_path() {
  docker_exec "${CONTAINER}" bash -s -- "${CONTAINER_CONFIG_DIR}/${CONFIG_FILE}" "${CONTAINER_FASTLIO_RUNTIME_DIR}/output/current_map.pcd" <<'EOS'
set -euo pipefail
config_path="$1"
fallback="$2"
map_path=""
if [[ -f "${config_path}" ]]; then
  map_path="$(grep -m1 'map_file_path:' "${config_path}" | sed -E 's/.*map_file_path:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/' || true)"
fi
if [[ -n "${map_path}" ]]; then
  printf '%s\n' "${map_path}"
else
  printf '%s\n' "${fallback}"
fi
EOS
}

save_map() {
  mkdir -p "${OUTPUT_DIR}" || return 1
  container_map_path="$(read_container_map_path | tr -d '\r')" || return 1
  if [[ -z "${container_map_path}" ]]; then
    echo "ERROR: Could not resolve map_file_path from container config: ${CONTAINER_CONFIG_DIR}/${CONFIG_FILE}" >&2
    return 1
  fi

  echo "FAST-LIO map path inside container:"
  echo "  ${container_map_path}"
  backup_map_path="${container_map_path}.bak.$(date +%Y%m%d_%H%M%S)"
  backup_created=false
  if docker_exec "${CONTAINER}" bash -s -- "${container_map_path}" <<'EOS'
set -euo pipefail
test -s "$1"
EOS
  then
    docker_exec "${CONTAINER}" bash -s -- "${container_map_path}" "${backup_map_path}" <<'EOS' || return 1
set -euo pipefail
mv -f "$1" "$2"
EOS
    backup_created=true
  fi

  echo "Calling /map_save ..."
  docker_exec "${CONTAINER}" bash -s -- "${CONTAINER_NAV_WS}" "${SERVICE_TIMEOUT}" "${RMW_IMPLEMENTATION_VALUE}" <<'EOS'
set -euo pipefail
nav_ws="$1"
timeout_sec="$2"
rmw="$3"
cd "${nav_ws}"
set +u
source /opt/ros/humble/setup.bash
source install/setup.bash
set -u
export RMW_IMPLEMENTATION="${rmw}"
timeout "${timeout_sec}" ros2 service call /map_save std_srvs/srv/Trigger
EOS
  rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    if [[ "${backup_created}" == "true" ]]; then
      docker_exec "${CONTAINER}" bash -s -- "${backup_map_path}" "${container_map_path}" <<'EOS' || true
set -euo pipefail
if [[ -s "$1" ]]; then
  mv -f "$1" "$2"
fi
EOS
    fi
    return "${rc}"
  fi

  echo "FAST-LIO saved map path inside container:"
  echo "  ${container_map_path}"

  if ! docker_exec "${CONTAINER}" bash -s -- "${container_map_path}" <<'EOS'
set -euo pipefail
test -s "$1"
EOS
  then
    echo "ERROR: Saved map is missing or empty inside container: ${container_map_path}" >&2
    if [[ "${backup_created}" == "true" ]]; then
      docker_exec "${CONTAINER}" bash -s -- "${backup_map_path}" "${container_map_path}" <<'EOS' || true
set -euo pipefail
if [[ -s "$1" ]]; then
  mv -f "$1" "$2"
fi
EOS
    fi
    return 1
  fi

  if [[ "${container_map_path}" == "${CONTAINER_NAV_WS}"/* ]]; then
    host_source="${HOST_NAV_WS}${container_map_path#${CONTAINER_NAV_WS}}"
    if [[ -s "${host_source}" ]]; then
      cp -f "${host_source}" "${FINAL_MAP_PATH}" || return 1
    else
      docker_cmd cp "${CONTAINER}:${container_map_path}" "${FINAL_MAP_PATH}" || return 1
    fi
  else
    docker_cmd cp "${CONTAINER}:${container_map_path}" "${FINAL_MAP_PATH}" || return 1
  fi

  if [[ ! -s "${FINAL_MAP_PATH}" ]]; then
    echo "ERROR: Final map is missing or empty: ${FINAL_MAP_PATH}" >&2
    if [[ "${backup_created}" == "true" ]]; then
      docker_exec "${CONTAINER}" bash -s -- "${backup_map_path}" "${container_map_path}" <<'EOS' || true
set -euo pipefail
if [[ -s "$1" ]]; then
  mv -f "$1" "$2"
fi
EOS
    fi
    return 1
  fi
  if [[ "${backup_created}" == "true" ]]; then
    docker_exec "${CONTAINER}" bash -s -- "${backup_map_path}" <<'EOS' || true
set -euo pipefail
rm -f "$1"
EOS
  fi
  echo "Saved final map:"
  echo "  ${FINAL_MAP_PATH}"
  ls -lh "${FINAL_MAP_PATH}"
}

stop_mapping() {
  [[ "${MAPPING_STARTED}" == "true" ]] || return 0
  docker_exec "${CONTAINER}" bash -s -- "${MAPPING_SESSION}" <<'EOS' || true
set -euo pipefail
session="$1"
pid_file="/tmp/${session}.pid"
if command -v tmux >/dev/null 2>&1 && tmux has-session -t "${session}" 2>/dev/null; then
  tmux send-keys -t "${session}" C-c || true
  sleep 2
  tmux kill-session -t "${session}" || true
fi
if [[ -f "${pid_file}" ]]; then
  pid="$(cat "${pid_file}")"
  if kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" || true
    sleep 2
    kill -9 "${pid}" 2>/dev/null || true
  fi
  rm -f "${pid_file}"
fi
EOS
  MAPPING_STARTED=false
}

stop_driver() {
  [[ "${START_DRIVER}" == "true" ]] || return 0
  [[ "${KEEP_DRIVER}" == "false" ]] || return 0
  [[ "${DRIVER_STARTED_BY_SCRIPT}" == "true" ]] || return 0
  if [[ "${DRIVER_MODE}" == "unitree" ]] && tmux has-session -t "${DRIVER_SESSION}" 2>/dev/null; then
    tmux send-keys -t "${DRIVER_SESSION}" C-c || true
    sleep 1
    tmux kill-session -t "${DRIVER_SESSION}" || true
    echo "Stopped MID360 driver session: ${DRIVER_SESSION}"
  fi
  if [[ "${DRIVER_MODE}" == "livox" ]]; then
    docker_exec "${CONTAINER}" bash -s -- "${DRIVER_SESSION}" <<'EOS' || true
set -euo pipefail
session="$1"
pid_file="/tmp/${session}.pid"
if command -v tmux >/dev/null 2>&1 && tmux has-session -t "${session}" 2>/dev/null; then
  tmux send-keys -t "${session}" C-c || true
  sleep 1
  tmux kill-session -t "${session}" || true
fi
if [[ -f "${pid_file}" ]]; then
  pid="$(cat "${pid_file}")"
  if kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" || true
    sleep 1
    kill -9 "${pid}" 2>/dev/null || true
  fi
  rm -f "${pid_file}"
fi
EOS
    echo "Stopped Livox MID360 driver session: ${DRIVER_SESSION}"
  fi
}

cleanup_on_interrupt() {
  echo
  echo "Interrupted. Stopping sessions without saving."
  stop_mapping
  stop_driver
}
trap cleanup_on_interrupt INT TERM

[[ -f "${CONFIG_HOST_PATH}" ]] || fail "FAST-LIO config not found: ${CONFIG_HOST_PATH}"
validate_driver_mode
print_summary

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "Dry-run only. No driver, mapping, or save command was started."
  exit 0
fi

check_prerequisites
start_driver

echo
echo "Press s to start mapping. Press q to save and quit."
while true; do
  IFS= read -rsn1 key
  case "${key}" in
    s|S)
      if [[ "${MAPPING_STARTED}" == "true" ]]; then
        echo "Mapping is already running."
      else
        if ! start_mapping; then
          stop_driver
          fail "Failed to start FAST-LIO mapping."
        fi
        if ! wait_for_mapping_ready; then
          stop_mapping
          stop_driver
          fail "FAST-LIO did not become ready before timeout."
        fi
        echo "Mapping is running. Press q to save and quit."
      fi
      ;;
    q|Q)
      if [[ "${MAPPING_STARTED}" == "true" ]]; then
        if ! save_map; then
          stop_mapping
          stop_driver
          fail "Failed to save FAST-LIO map."
        fi
        stop_mapping
      else
        echo "Mapping was not started; nothing to save."
      fi
      stop_driver
      exit 0
      ;;
  esac
done
