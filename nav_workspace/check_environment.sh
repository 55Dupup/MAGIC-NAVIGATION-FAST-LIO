#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="${CONTAINER:-unitree_humble_nav}"
DOCKER_CMD="${DOCKER_CMD:-docker}"

status=0

check_file() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    echo "OK file: ${path}"
  else
    echo "MISSING file: ${path}"
    status=1
  fi
}

check_executable() {
  local path="$1"
  if [[ -x "${path}" ]]; then
    echo "OK exec: ${path}"
  else
    echo "MISSING exec: ${path}"
    status=1
  fi
}

check_dir() {
  local path="$1"
  if [[ -d "${path}" ]]; then
    echo "OK dir:  ${path}"
  else
    echo "MISSING dir:  ${path}"
    status=1
  fi
}

docker_cmd() {
  ${DOCKER_CMD} "$@"
}

echo "== Host paths =="
check_dir "${ROOT_DIR}"
check_file "${ROOT_DIR}/maps/kitchen_pro.pcd"
check_file "/opt/ros/foxy/setup.bash"
check_file "/home/unitree/cyclonedds_ws/install/cyclonedds/lib/libddsc.so"
check_file "/home/unitree/unitree_sdk2_python/scripts_v2/start_slam.sh"
check_file "/home/unitree/unitree_sdk2_python/navi_update/get_pose.py"
check_file "/home/unitree/unitree_sdk2_python/navi_update/client_recon_v1.py"
check_file "/home/unitree/unitree_sdk2_python/agent/config/client_config.json"
check_file "/home/unitree/unitree_sdk2_python/scripts_v2/dog_state_topic_bridge_light.py"
check_executable "/unitree/module/unitree_slam/bin/unitree_slam"
check_executable "/unitree/module/unitree_slam/bin/mid360_driver"
check_executable "/unitree/module/unitree_slam/example/build/keyDemo_changemap"

echo
echo "== Optional scripts_v2 topic stack =="
if [[ -f "/home/unitree/go2_workspace/scripts/start_mid360_scan_bridge_light.sh" ]]; then
  echo "OK optional scan bridge: /home/unitree/go2_workspace/scripts/start_mid360_scan_bridge_light.sh"
else
  echo "MISSING optional scan bridge: /home/unitree/go2_workspace/scripts/start_mid360_scan_bridge_light.sh"
  echo "  scripts_v2/start_topic.sh needs this file; FAST-LIO/Open3D and step1-step5 do not."
fi

echo
echo "== Docker =="
if docker_cmd inspect -f '{{.State.Running}}' "${CONTAINER}" >/dev/null 2>&1; then
  running="$(docker_cmd inspect -f '{{.State.Running}}' "${CONTAINER}")"
  echo "OK container: ${CONTAINER} running=${running}"
  if docker_cmd exec "${CONTAINER}" bash -lc "test -d /workspace/nav_ws && test -f /workspace/nav_ws/install/setup.bash"; then
    echo "OK container workspace: /workspace/nav_ws"
  else
    echo "MISSING container workspace: /workspace/nav_ws/install/setup.bash"
    status=1
  fi
  if docker_cmd exec "${CONTAINER}" bash -lc "test -f /workspace/nav_ws/maps/kitchen_pro.pcd"; then
    echo "OK container map: /workspace/nav_ws/maps/kitchen_pro.pcd"
  else
    echo "MISSING container map: /workspace/nav_ws/maps/kitchen_pro.pcd"
    status=1
  fi
else
  echo "Docker container not accessible: ${CONTAINER}"
  echo "If Docker requires sudo, rerun as: DOCKER_CMD='sudo docker' bash ${ROOT_DIR}/check_environment.sh"
  status=1
fi

exit "${status}"
