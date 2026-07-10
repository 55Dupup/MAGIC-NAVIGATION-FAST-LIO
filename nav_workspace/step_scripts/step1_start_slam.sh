#!/usr/bin/env bash
set -euo pipefail

START_SLAM="${START_SLAM:-/home/unitree/unitree_sdk2_python/scripts_v2/start_slam.sh}"
KEYDEMO_CHANGEMAP="${KEYDEMO_CHANGEMAP:-/unitree/module/unitree_slam/example/build/keyDemo_changemap}"
DRY_RUN=false
MAP_PATH="/home/unitree/go2-fast-lio/nav_workspace/maps/kitchen_pro.pcd"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --map|--maps)
      if [[ $# -lt 2 ]]; then
        echo "$1 requires a map path"
        exit 2
      fi
      MAP_PATH="$2"
      shift 2
      ;;
    --start-slam)
      if [[ $# -lt 2 ]]; then
        echo "$1 requires a script path"
        exit 2
      fi
      START_SLAM="$2"
      shift 2
      ;;
    --keydemo)
      if [[ $# -lt 2 ]]; then
        echo "$1 requires a keyDemo_changemap path"
        exit 2
      fi
      KEYDEMO_CHANGEMAP="$2"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1"
      echo "Usage: bash step1_start_slam.sh [--dry-run] [--map PATH] [--start-slam PATH] [--keydemo PATH]"
      exit 2
      ;;
    *)
      MAP_PATH="$1"
      shift
      ;;
  esac
done

TMP_START_SLAM="$(mktemp /tmp/step1_start_slam.XXXXXX.sh)"

cleanup() {
  rm -f "${TMP_START_SLAM}"
}
trap cleanup EXIT

if [[ ! -f "${MAP_PATH}" ]]; then
  echo "Map file not found:"
  echo "  ${MAP_PATH}"
  exit 2
fi

if [[ ! -f "${START_SLAM}" ]]; then
  echo "Unitree SLAM startup script not found:"
  echo "  ${START_SLAM}"
  exit 2
fi

if [[ ! -x "${KEYDEMO_CHANGEMAP}" ]]; then
  echo "keyDemo_changemap not found or not executable:"
  echo "  ${KEYDEMO_CHANGEMAP}"
  exit 2
fi

if [[ "${MAP_PATH}" == *\"* ]]; then
  echo "Map path cannot contain double quotes:"
  echo "  ${MAP_PATH}"
  exit 2
fi

if ! grep -Eq 'keyDemo_(v3|changemap)[^"]*eth0' "${START_SLAM}"; then
  echo "Cannot find keyDemo startup line in:"
  echo "  ${START_SLAM}"
  exit 3
fi

/usr/bin/python3 - "${START_SLAM}" "${TMP_START_SLAM}" "${KEYDEMO_CHANGEMAP}" "${MAP_PATH}" <<'PY'
import sys
import re
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
keydemo = Path(sys.argv[3])
map_path = sys.argv[4]

text = src.read_text(encoding="utf-8")
new_reloc = f'cd {keydemo.parent} && ./{keydemo.name} eth0 {map_path}'
text, reloc_count = re.subn(
    r'cd [^"]+ && \./keyDemo_(?:v3|changemap) eth0(?: [^"]+)?',
    new_reloc,
    text,
    count=1,
)
if reloc_count != 1:
    raise SystemExit(f"Cannot find supported relocation command in {src}")

old_lidar = 'cd $SLAM_DIR && ./${LIDAR_TYPE}_driver'
new_lidar = 'export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH && cd $SLAM_DIR && ./${LIDAR_TYPE}_driver'
if old_lidar in text:
    text = text.replace(old_lidar, new_lidar, 1)

dst.write_text(text, encoding="utf-8")
PY
chmod +x "${TMP_START_SLAM}"

echo "Using map:"
echo "  ${MAP_PATH}"
echo "Using Unitree startup script:"
echo "  ${START_SLAM}"
echo "Using relocalization binary:"
echo "  ${KEYDEMO_CHANGEMAP}"
echo "Running temporary startup script:"
echo "  ${TMP_START_SLAM}"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "Dry-run keyDemo_changemap line:"
  grep -F "./keyDemo_changemap" "${TMP_START_SLAM}" || true
  echo "Dry-run mid360_driver line:"
  grep -F './${LIDAR_TYPE}_driver' "${TMP_START_SLAM}" || true
  exit 0
fi

bash "${TMP_START_SLAM}"
