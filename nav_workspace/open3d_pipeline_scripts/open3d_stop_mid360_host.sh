#!/usr/bin/env bash
set -euo pipefail

SESSION="${OPEN3D_MID360_SESSION:-open3d_mid360_host}"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is required on the host."
  exit 2
fi

if tmux has-session -t "${SESSION}" 2>/dev/null; then
  tmux kill-session -t "${SESSION}"
  echo "Stopped host MID360 driver session: ${SESSION}"
else
  echo "Host MID360 driver session is not running: ${SESSION}"
fi
