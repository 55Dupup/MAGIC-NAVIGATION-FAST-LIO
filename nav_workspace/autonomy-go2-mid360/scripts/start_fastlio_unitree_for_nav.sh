#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${BASE_DIR}/../.." && pwd)"

exec bash "${REPO_ROOT}/nav_workspace/fast-lio-mid360/scripts/fast_lio_mid360_mapping.sh" \
  --driver-mode unitree \
  --config-file unitree_go2_fastlio.yaml \
  --keep-driver \
  "$@"
