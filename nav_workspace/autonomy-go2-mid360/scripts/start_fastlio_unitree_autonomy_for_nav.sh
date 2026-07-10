#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${BASE_DIR}/../.." && pwd)"

# Dedicated FAST-LIO entrypoint for autonomy_stack_go2. This intentionally
# does not replace start_fastlio_unitree_for_nav.sh or the original mapping
# configs, so existing FAST-LIO/Unitree workflows keep their old behavior.
export CONTAINER="${CONTAINER:-mid360_go2_nav_humble}"
export CONTAINER_FASTLIO_RUNTIME_DIR="${CONTAINER_FASTLIO_RUNTIME_DIR:-/workspace/autonomy-go2-mid360/fast-lio-runtime}"

exec bash "${REPO_ROOT}/nav_workspace/fast-lio-mid360/scripts/fast_lio_mid360_mapping.sh" \
  --driver-mode unitree \
  --config-file unitree_go2_fastlio_autonomy.yaml \
  --output-dir /home/unitree/maps \
  --name autonomy_mid360_map \
  --keep-driver \
  "$@"
