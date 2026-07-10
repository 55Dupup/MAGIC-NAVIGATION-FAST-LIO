#!/usr/bin/env bash
set -euo pipefail

CLIENT_SCRIPT="${CLIENT_SCRIPT:-/home/unitree/unitree_sdk2_python/navi_update/client_recon_v1.py}"
CONFIG_PATH="${CONFIG_PATH:-/home/unitree/unitree_sdk2_python/agent/config/client_config.json}"
DRY_RUN=false
CLIENT_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config|--client-config)
      if [[ $# -lt 2 ]]; then
        echo "$1 requires a config path"
        exit 2
      fi
      CONFIG_PATH="$2"
      shift 2
      ;;
    --client-script)
      if [[ $# -lt 2 ]]; then
        echo "$1 requires a client script path"
        exit 2
      fi
      CLIENT_SCRIPT="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      CLIENT_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "Client config not found:"
  echo "  ${CONFIG_PATH}"
  exit 2
fi

TMP_CLIENT="$(mktemp /tmp/step5_client_recon_v1.XXXXXX.py)"

cleanup() {
  rm -f "${TMP_CLIENT}"
}
trap cleanup EXIT

if [[ ! -f "${CLIENT_SCRIPT}" ]]; then
  echo "Navigation client script not found:"
  echo "  ${CLIENT_SCRIPT}"
  exit 2
fi

/usr/bin/python3 - "${CLIENT_SCRIPT}" "${TMP_CLIENT}" "${CONFIG_PATH}" <<'PY'
import json
import pprint
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
config = sys.argv[3]

text = src.read_text(encoding="utf-8")
with Path(config).open("r", encoding="utf-8") as handle:
    config_data = json.load(handle)

updated = text
path_injection = (
    "sys.path.insert(0, '/home/unitree/unitree_sdk2_python/navi_update')\n"
    "sys.path.insert(0, '/home/unitree/dky/go2_python_sdk2')"
)
updated = re.sub(
    r"sys\.path\.insert\(0,\s*['\"]/home/unitree/dky/go2_python_sdk2['\"]\)",
    path_injection,
    updated,
    count=1,
)
if "/home/unitree/unitree_sdk2_python/navi_update" not in updated:
    updated = updated.replace("import sys\n", "import sys\n" + path_injection + "\n", 1)
if "item_mapping" in config_data:
    item_literal = pprint.pformat(config_data["item_mapping"], width=100, sort_dicts=False)
    updated, item_count = re.subn(
        r"(?ms)^item_mapping\s*=\s*\{.*?^# 地点到导航路径点列表的映射",
        f"item_mapping = {item_literal}\n\n# 地点到导航路径点列表的映射",
        updated,
        count=1,
    )
    if item_count != 1:
        raise SystemExit(f"Cannot replace item_mapping in {src}")

mapping = config_data.get("location_poses_mapping")
if not isinstance(mapping, dict):
    raise SystemExit(f"Cannot find location_poses_mapping in {config}")
mapping_literal = pprint.pformat(mapping, width=120, sort_dicts=False)
updated, mapping_count = re.subn(
    r"(?ms)^location_poses_mapping\s*=\s*\{.*?\n\}\n\n\n# =+",
    f"location_poses_mapping = {mapping_literal}\n\n\n# ============================================================",
    updated,
    count=1,
)
if mapping_count != 1:
    raise SystemExit(f"Cannot replace location_poses_mapping in {src}")
dst.write_text(updated, encoding="utf-8")
PY

/usr/bin/python3 -m py_compile "${TMP_CLIENT}"

echo "Using client config:"
echo "  ${CONFIG_PATH}"
echo "Using navigation client source:"
echo "  ${CLIENT_SCRIPT}"
echo "Running temporary navigation client:"
echo "  ${TMP_CLIENT}"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "Dry-run client mapping line:"
  grep -F "location_poses_mapping" "${TMP_CLIENT}" || true
  exit 0
fi

export CYCLONEDDS_HOME="${CYCLONEDDS_HOME:-/home/unitree/cyclonedds_ws/install/cyclonedds}"
export LD_LIBRARY_PATH="${CYCLONEDDS_HOME}/lib:${LD_LIBRARY_PATH:-}"
export PYTHONPATH="/opt/ros/foxy/lib/python3.8/site-packages:/home/unitree/unitree_sdk2_python:/home/unitree/unitree_sdk2_python/navi_update:/home/unitree/dky/go2_python_sdk2:${PYTHONPATH:-}"

python3 "${TMP_CLIENT}" "${CLIENT_ARGS[@]}"
