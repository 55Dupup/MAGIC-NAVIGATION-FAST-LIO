#!/usr/bin/env bash
set -euo pipefail

CONTAINER="unitree_humble_nav"
PID_DIR="/tmp/open3d_pipeline_pids"
DOCKER_CMD="${DOCKER_CMD:-docker}"

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
    *)
      echo "Unknown option: $1"
      echo "Usage: bash open3d_stop_pipeline.sh [--container unitree_humble_nav]"
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

if ! docker_cmd inspect -f '{{.State.Running}}' "${CONTAINER}" >/dev/null 2>&1; then
  echo "Docker container is not running or not accessible: ${CONTAINER}" >&2
  exit 2
fi

if docker_exec "${CONTAINER}" bash -lc "command -v tmux >/dev/null 2>&1"; then
  for session in open3d_fastlio open3d_tf_imu_base open3d_tf_base_motion open3d_localization; do
    docker_exec "${CONTAINER}" bash -lc "tmux kill-session -t '${session}' 2>/dev/null || true"
  done
  echo "Stopped Open3D pipeline tmux sessions."
fi

docker_exec "${CONTAINER}" bash -lc "
  for name in fastlio tf_imu_base tf_base_motion localization; do
    pid_file='${PID_DIR}'/\${name}.pid
    if [[ -f \"\${pid_file}\" ]]; then
      pid=\$(cat \"\${pid_file}\" 2>/dev/null || true)
      if [[ -n \"\${pid}\" ]] && kill -0 \"\${pid}\" 2>/dev/null; then
        kill -- -\"\${pid}\" 2>/dev/null || kill \"\${pid}\" 2>/dev/null || true
        sleep 0.5
        kill -9 -- -\"\${pid}\" 2>/dev/null || true
      fi
      rm -f \"\${pid_file}\"
    fi
  done
"

docker_exec "${CONTAINER}" bash -lc "
  patterns=(
    '[r]os2 launch fast_lio mapping.launch.py'
    '[f]astlio_mapping'
    '[r]os2 run open3d_loc global_localization_node'
    '[g]lobal_localization_node'
    '[r]os2 run tf2_ros static_transform_publisher'
    '/opt/ros/.*/[s]tatic_transform_publisher'
    '[o]pen3d_pipeline_pids'
    '[o]pen3d_fastlio.log'
    '[o]pen3d_localization.log'
    '[o]pen3d_tf_imu_base.log'
    '[o]pen3d_tf_base_motion.log'
  )

  for pattern in \"\${patterns[@]}\"; do
    pkill -TERM -f \"\${pattern}\" 2>/dev/null || true
  done
  sleep 0.5
  for pattern in \"\${patterns[@]}\"; do
    pkill -KILL -f \"\${pattern}\" 2>/dev/null || true
  done
  rm -rf '${PID_DIR}'
"

docker_exec "${CONTAINER}" bash -lc "
  residual_pids=\$(ps -eo pid=,args= | awk '
    /ros2 launch fast_lio mapping\\.launch\\.py|fastlio_mapping|global_localization_node|static_transform_publisher/ &&
    \$0 !~ /awk/ &&
    \$0 !~ /bash -lc/ {
      print \$1
    }
  ')
  if [[ -n \"\${residual_pids}\" ]]; then
    kill \${residual_pids} 2>/dev/null || true
    sleep 0.5
    for pid in \${residual_pids}; do
      kill -0 \"\${pid}\" 2>/dev/null && kill -9 \"\${pid}\" 2>/dev/null || true
    done
  fi
"

echo "Stopped Open3D pipeline detached processes recorded under ${PID_DIR}."
echo "Stopped residual FAST-LIO/Open3D/static TF processes in ${CONTAINER}."
