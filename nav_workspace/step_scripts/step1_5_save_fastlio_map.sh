#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${CONTAINER:-unitree_humble_nav}"
DOCKER_CMD="${DOCKER_CMD:-sudo docker}"
HOST_NAV_WS="${HOST_NAV_WS:-/home/unitree/go2-fast-lio/nav_workspace}"
CONTAINER_NAV_WS="${CONTAINER_NAV_WS:-/workspace/nav_ws}"
HOST_DIR="${HOST_DIR:-/home/unitree/maps}"
BASE_NAME=""
NO_DATE=false
NON_INTERACTIVE=false
DRY_RUN=false
SERVICE_TIMEOUT="${SERVICE_TIMEOUT:-120}"
CONFIG_PATH="${CONFIG_PATH:-/workspace/nav_ws/install/fast_lio/share/fast_lio/config/mid360.yaml}"
CONTAINER_MAP_PATH=""

usage() {
  cat <<'EOF'
Usage: bash step1_5_save_fastlio_map.sh [options]

Save the current FAST-LIO map through /map_save, then copy it to a host path.

Options:
  --host-dir DIR          Host output directory. Default: /home/unitree/maps
  --name NAME             Base output name. Default: fastlio_map
  --no-date               Do not append YYYYmmdd_HHMMSS to the output name
  --container NAME        Docker container name. Default: unitree_humble_nav
  --docker-cmd CMD        Docker command. Default: "sudo docker"
  --container-map PATH    Override FAST-LIO map path inside the container
  --non-interactive       Do not prompt; use defaults/options
  --dry-run               Print resolved paths without calling /map_save
  -h, --help              Show this help

Examples:
  bash step1_5_save_fastlio_map.sh
  bash step1_5_save_fastlio_map.sh --name company_001
  bash step1_5_save_fastlio_map.sh --host-dir /home/unitree/maps --name company_001
  DOCKER_CMD="sudo docker" bash step1_5_save_fastlio_map.sh --name company_001
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-dir)
      HOST_DIR="$2"
      shift 2
      ;;
    --name)
      BASE_NAME="$2"
      shift 2
      ;;
    --no-date)
      NO_DATE=true
      shift
      ;;
    --container)
      CONTAINER="$2"
      shift 2
      ;;
    --docker-cmd)
      DOCKER_CMD="$2"
      shift 2
      ;;
    --container-map)
      CONTAINER_MAP_PATH="$2"
      shift 2
      ;;
    --non-interactive)
      NON_INTERACTIVE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      NON_INTERACTIVE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${NON_INTERACTIVE}" != "true" && -t 0 ]]; then
  read -r -p "Host output directory [${HOST_DIR}]: " input_host_dir
  if [[ -n "${input_host_dir}" ]]; then
    HOST_DIR="${input_host_dir}"
  fi

  default_name="${BASE_NAME:-fastlio_map}"
  read -r -p "Map base name [${default_name}]: " input_name
  if [[ -n "${input_name}" ]]; then
    BASE_NAME="${input_name}"
  elif [[ -z "${BASE_NAME}" ]]; then
    BASE_NAME="${default_name}"
  fi
fi

if [[ -z "${BASE_NAME}" ]]; then
  BASE_NAME="fastlio_map"
fi

BASE_NAME="${BASE_NAME%.pcd}"
if [[ "${BASE_NAME}" == */* ]]; then
  echo "--name must be a file name, not a path: ${BASE_NAME}" >&2
  exit 2
fi

timestamp="$(date +%Y%m%d_%H%M%S)"
if [[ "${NO_DATE}" == "true" ]]; then
  OUTPUT_NAME="${BASE_NAME}.pcd"
else
  OUTPUT_NAME="${BASE_NAME}_${timestamp}.pcd"
fi
HOST_OUTPUT="${HOST_DIR%/}/${OUTPUT_NAME}"

docker_cmd() {
  # shellcheck disable=SC2086
  ${DOCKER_CMD} "$@"
}

docker_exec() {
  docker_cmd exec "$@"
}

if ! docker_cmd inspect -f '{{.State.Running}}' "${CONTAINER}" >/dev/null 2>&1; then
  echo "Docker container is not running or not accessible: ${CONTAINER}" >&2
  echo "Start it first:" >&2
  echo "  ${DOCKER_CMD} start ${CONTAINER}" >&2
  exit 2
fi

if [[ -z "${CONTAINER_MAP_PATH}" ]]; then
  CONTAINER_MAP_PATH="$(
    docker_exec "${CONTAINER}" bash -lc "
      if [[ -f '${CONFIG_PATH}' ]]; then
        grep -m1 'map_file_path:' '${CONFIG_PATH}' | sed -E 's/.*map_file_path:[[:space:]]*\"?([^\"[:space:]]+)\"?.*/\1/'
      fi
    " | tr -d '\r'
  )"
fi

if [[ -z "${CONTAINER_MAP_PATH}" ]]; then
  CONTAINER_MAP_PATH="${CONTAINER_NAV_WS}/maps/test.pcd"
fi

echo "FAST-LIO map_file_path inside container:"
echo "  ${CONTAINER_MAP_PATH}"
echo "Host output path:"
echo "  ${HOST_OUTPUT}"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "Dry-run only. /map_save was not called."
  exit 0
fi

mkdir -p "${HOST_DIR}"

echo "Calling /map_save ..."
docker_exec "${CONTAINER}" bash -lc "
  cd '${CONTAINER_NAV_WS}' &&
  source install/setup.bash &&
  export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp &&
  timeout '${SERVICE_TIMEOUT}' ros2 service call /map_save std_srvs/srv/Trigger
"

echo "Checking saved map ..."
docker_exec "${CONTAINER}" bash -lc "test -s '${CONTAINER_MAP_PATH}'"

if [[ "${CONTAINER_MAP_PATH}" == "${CONTAINER_NAV_WS}"/* ]]; then
  HOST_SOURCE="${HOST_NAV_WS}${CONTAINER_MAP_PATH#${CONTAINER_NAV_WS}}"
  if [[ -s "${HOST_SOURCE}" ]]; then
    cp -f "${HOST_SOURCE}" "${HOST_OUTPUT}"
  else
    docker_cmd cp "${CONTAINER}:${CONTAINER_MAP_PATH}" "${HOST_OUTPUT}"
  fi
else
  docker_cmd cp "${CONTAINER}:${CONTAINER_MAP_PATH}" "${HOST_OUTPUT}"
fi

if [[ ! -s "${HOST_OUTPUT}" ]]; then
  echo "Saved output is missing or empty:" >&2
  echo "  ${HOST_OUTPUT}" >&2
  exit 1
fi

echo "Saved FAST-LIO map:"
echo "  ${HOST_OUTPUT}"
ls -lh "${HOST_OUTPUT}"
