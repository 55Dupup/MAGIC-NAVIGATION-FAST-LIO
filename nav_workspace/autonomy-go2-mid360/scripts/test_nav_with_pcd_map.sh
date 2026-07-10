#!/usr/bin/env bash
set -euo pipefail

DOCKER_CMD="${DOCKER_CMD:-docker}"
CONTAINER_NAME="${CONTAINER_NAME:-mid360_go2_nav_humble}"
MAP_FILE="${1:-/home/unitree/maps/company_001-test_20260519_195622.pcd}"
TEST_SECONDS="${TEST_SECONDS:-12}"
RESTART_AFTER_TEST="${RESTART_AFTER_TEST:-1}"
CONTAINER_MAP="/tmp/$(basename "${MAP_FILE}")"

if [[ ! -f "${MAP_FILE}" ]]; then
  echo "PCD file not found: ${MAP_FILE}" >&2
  exit 2
fi

if ! "${DOCKER_CMD}" inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" >/dev/null 2>&1; then
  echo "Container is not running: ${CONTAINER_NAME}" >&2
  echo "Start it first:" >&2
  echo "  bash nav_workspace/autonomy-go2-mid360/scripts/run_container.sh" >&2
  exit 2
fi

"${DOCKER_CMD}" cp "${MAP_FILE}" "${CONTAINER_NAME}:${CONTAINER_MAP}"

set +e
"${DOCKER_CMD}" exec -i "${CONTAINER_NAME}" bash -s -- "${CONTAINER_MAP}" "${TEST_SECONDS}" <<'EOF'
set -euo pipefail

CONTAINER_MAP="$1"
TEST_SECONDS="$2"

set +u
source /opt/ros/humble/setup.bash
source /workspace/autonomy-go2-mid360/workspace/install/setup.bash
set -u

rm -f /tmp/nav_pcd_test.log /tmp/odom_test.log /tmp/pcd_test.log
rm -f /tmp/state_test.txt /tmp/scan_test.txt /tmp/topic_test.txt

cleanup() {
  if [[ -n "${nav_pid:-}" ]]; then
    kill -INT -"${nav_pid}" >/dev/null 2>&1 || true
  fi

  for pid in "${pcd_pid:-}" "${odom_pid:-}"; do
    if [[ -n "${pid}" ]]; then
      kill -TERM -"${pid}" >/dev/null 2>&1 || true
    fi
  done
  sleep 1
  for pid in "${pcd_pid:-}" "${odom_pid:-}"; do
    if [[ -n "${pid}" ]]; then
      kill -KILL -"${pid}" >/dev/null 2>&1 || true
    fi
  done
}
trap cleanup EXIT

setsid ros2 launch mid360_go2_nav_bridge fastlio_mid360_nav.launch.py \
  rviz:=false \
  real_robot:=false \
  route_planner:=false \
  terrain_ext:=false \
  max_speed:=0.3 \
  > /tmp/nav_pcd_test.log 2>&1 &
nav_pid=$!

sleep 5

setsid ros2 topic pub -r 5 /Odometry_loc nav_msgs/msg/Odometry \
  "{header: {frame_id: camera_init}, child_frame_id: aft_mapped, pose: {pose: {orientation: {w: 1.0}}}}" \
  > /tmp/odom_test.log 2>&1 &
odom_pid=$!

setsid ros2 run pcl_ros pcd_to_pointcloud --ros-args \
  -p "file_name:=${CONTAINER_MAP}" \
  -r cloud_pcd:=/cloud_registered_1 \
  > /tmp/pcd_test.log 2>&1 &
pcd_pid=$!

sleep "${TEST_SECONDS}"

ros2 topic list | sort | grep -E 'Odometry_loc|cloud_registered_1|state_estimation|registered_scan|cmd_vel|api/sport/request' > /tmp/topic_test.txt || true
timeout 5 ros2 topic echo --once /state_estimation > /tmp/state_test.txt
state_status=$?
timeout 5 ros2 topic echo --once /registered_scan > /tmp/scan_test.txt
scan_status=$?

printf '%s\n' '--- topics ---'
cat /tmp/topic_test.txt
printf '%s\n' ''
printf '%s\n' '--- state_estimation head ---'
head -n 12 /tmp/state_test.txt
printf '%s\n' ''
printf '%s\n' '--- registered_scan head ---'
head -n 20 /tmp/scan_test.txt
printf '%s\n' ''
printf '%s\n' '--- nav log important lines ---'
grep -E 'ERROR|Error|Exception|Traceback|process has died|Bridging|Initialization complete|process started' /tmp/nav_pcd_test.log || true
printf '%s\n' ''
printf '%s\n' '--- pcd log ---'
cat /tmp/pcd_test.log

if [[ ${state_status} -ne 0 || ${scan_status} -ne 0 ]]; then
  exit 20
fi

if grep -E 'ERROR|Exception|Traceback|process has died' /tmp/nav_pcd_test.log >/dev/null; then
  exit 21
fi
EOF
test_status=$?
set -e

if [[ "${RESTART_AFTER_TEST}" = "1" ]]; then
  "${DOCKER_CMD}" restart "${CONTAINER_NAME}" >/dev/null
  echo "Restarted container after test: ${CONTAINER_NAME}"
fi

exit "${test_status}"
