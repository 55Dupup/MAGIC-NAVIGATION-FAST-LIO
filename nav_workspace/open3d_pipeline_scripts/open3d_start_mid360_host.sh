#!/usr/bin/env bash
set -euo pipefail

SESSION="${OPEN3D_MID360_SESSION:-open3d_mid360_host}"
MID360_BIN_DIR="${MID360_BIN_DIR:-/unitree/module/unitree_slam/bin}"
LIDAR_DRIVER="${LIDAR_DRIVER:-mid360_driver}"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is required on the host. Install tmux first."
  exit 2
fi

if [[ ! -x "${MID360_BIN_DIR}/${LIDAR_DRIVER}" ]]; then
  echo "MID360 driver not found or not executable on host:"
  echo "  ${MID360_BIN_DIR}/${LIDAR_DRIVER}"
  exit 2
fi

for session in go2_slam go2_lidar go2_relocation; do
  if tmux has-session -t "${session}" 2>/dev/null; then
    echo "Conflicting Unitree original SLAM tmux session is running: ${session}" >&2
    echo "Stop the Unitree original SLAM chain before starting Open3D MID360 input." >&2
    echo "Example:" >&2
    echo "  tmux kill-session -t ${session}" >&2
    exit 5
  fi
done

if tmux has-session -t "${SESSION}" 2>/dev/null; then
  echo "Host MID360 driver session already exists: ${SESSION}"
  echo "Inspect it with:"
  echo "  tmux attach -t ${SESSION}"
  exit 0
fi

conflicts="$(
  ps -eo pid=,args= | awk '
    /(^|[ \\/])(mid360_driver|unitree_slam|keyDemo_changemap)([ ]|$)/ &&
    $0 !~ /awk/ {
      print
    }
  '
)"
if [[ -n "${conflicts}" ]]; then
  echo "Conflicting host SLAM/LiDAR process detected:" >&2
  echo "${conflicts}" >&2
  echo "Stop the existing process before starting Open3D MID360 input." >&2
  exit 5
fi

tmux new-session -d -s "${SESSION}" \
  "bash --noprofile --norc -lc 'set +u; source /opt/ros/noetic/setup.bash; cd \"${MID360_BIN_DIR}\"; exec ./\"${LIDAR_DRIVER}\"'"

echo "Started host MID360 driver session: ${SESSION}"
echo "Inspect it with:"
echo "  tmux attach -t ${SESSION}"
echo "Detach from tmux with Ctrl+B, then D."
