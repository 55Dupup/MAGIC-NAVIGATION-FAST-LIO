#!/usr/bin/env bash
set -euo pipefail

DOCKER_CMD="${DOCKER_CMD:-docker}"
CONTAINER_NAME="${CONTAINER_NAME:-mid360_go2_nav_humble}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace/autonomy-go2-mid360/workspace}"
TIMEOUT_SEC="${TIMEOUT_SEC:-3}"

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

  echo 'Expected autonomy TF edges:'
  echo '  map -> camera_init'
  echo '  camera_init -> aft_mapped   dynamic; produced by the bridge from FAST-LIO /Odometry_loc'
  echo '  aft_mapped -> sensor'
  echo '  sensor -> vehicle'
  echo '  sensor -> camera'
  echo

  for pair in \
    'map camera_init' \
    'camera_init aft_mapped' \
    'aft_mapped sensor' \
    'sensor vehicle' \
    'sensor camera'; do
    set -- \${pair}
    parent=\$1
    child=\$2
    echo \"Checking TF \${parent} -> \${child} ...\"
    timeout '${TIMEOUT_SEC}' ros2 run tf2_ros tf2_echo \"\${parent}\" \"\${child}\" >/tmp/tf_check_one.txt 2>&1 || true
    if grep -q 'At time' /tmp/tf_check_one.txt; then
      echo '  ok'
      grep -E 'Translation:|Rotation: in RPY \\(degree\\)' /tmp/tf_check_one.txt | head -2
    else
      echo '  missing or timed out'
      sed -n '1,8p' /tmp/tf_check_one.txt || true
    fi
    echo
  done
"
