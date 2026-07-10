#!/usr/bin/env bash
set -euo pipefail

DOCKER_CMD="${DOCKER_CMD:-docker}"
CONTAINER_NAME="${CONTAINER_NAME:-mid360_go2_nav_humble}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace/autonomy-go2-mid360/workspace}"
TIMEOUT_SEC="${TIMEOUT_SEC:-5}"

if ! "${DOCKER_CMD}" inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" >/dev/null 2>&1; then
  echo "Container is not running: ${CONTAINER_NAME}" >&2
  exit 2
fi

"${DOCKER_CMD}" exec "${CONTAINER_NAME}" bash -lc "
  set -euo pipefail
  set +u
  source /opt/ros/humble/setup.bash
  if [[ -f '${WORKSPACE_DIR}/install/setup.bash' ]]; then
    source '${WORKSPACE_DIR}/install/setup.bash'
  fi
  set -u
  export RMW_IMPLEMENTATION=\${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}
  echo 'Topic list:'
  ros2 topic list | sort | grep -E 'Odometry_loc|cloud_registered_1|state_estimation|registered_scan|cmd_vel|api/sport/request' || true
  echo
  for topic in /Odometry_loc /cloud_registered_1 /state_estimation /registered_scan; do
    echo \"Checking \${topic} ...\"
    timeout '${TIMEOUT_SEC}' ros2 topic echo --once \"\${topic}\" >/dev/null && echo \"  ok\" || echo \"  missing or no data\"
  done
"
