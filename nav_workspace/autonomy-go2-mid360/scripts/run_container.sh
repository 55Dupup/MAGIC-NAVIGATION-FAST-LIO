#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${BASE_DIR}/../.." && pwd)"

DOCKER_CMD="${DOCKER_CMD:-docker}"
IMAGE_NAME="${IMAGE_NAME:-mid360-go2-nav:humble}"
CONTAINER_NAME="${CONTAINER_NAME:-mid360_go2_nav_humble}"
NETWORK_MODE="${NETWORK_MODE:-host}"
PRIVILEGED="${PRIVILEGED:-0}"
MOUNT_DEV_INPUT="${MOUNT_DEV_INPUT:-0}"
MAPS_DIR="${MAPS_DIR:-/home/unitree/maps}"

usage() {
  cat <<'EOF'
Usage: bash run_container.sh [options]

Create or start the isolated autonomy container.

Options:
  --privileged            Run the container with Docker --privileged.
  --dev-input             Mount /dev/input for joystick/manual input devices.
  --network MODE          Docker network mode. Default: host.
  -h, --help              Show this help.

The default is non-privileged. Host networking is kept because ROS2 DDS needs
to see the existing FAST-LIO and Unitree topics on the robot network.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --privileged)
      PRIVILEGED=1
      shift
      ;;
    --dev-input)
      MOUNT_DEV_INPUT=1
      shift
      ;;
    --network)
      NETWORK_MODE="$2"
      shift 2
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

if "${DOCKER_CMD}" inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
  if [[ "$("${DOCKER_CMD}" inspect -f '{{.State.Running}}' "${CONTAINER_NAME}")" == "true" ]]; then
    echo "Container already running: ${CONTAINER_NAME}"
  else
    "${DOCKER_CMD}" start "${CONTAINER_NAME}" >/dev/null
    echo "Started container: ${CONTAINER_NAME}"
  fi
  exit 0
fi

DOCKER_RUN_ARGS=(
  run -d
  --name "${CONTAINER_NAME}"
  --network "${NETWORK_MODE}"
  -e RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"
	  -v "${REPO_ROOT}/nav_workspace/autonomy-go2-mid360:/workspace/autonomy-go2-mid360"
	  -v "${REPO_ROOT}/nav_workspace:/workspace/nav_ws:ro"
	)

if [[ -d "${MAPS_DIR}" ]]; then
  DOCKER_RUN_ARGS+=(-v "${MAPS_DIR}:/workspace/maps:ro")
fi

if [[ "${PRIVILEGED}" = "1" ]]; then
  DOCKER_RUN_ARGS+=(--privileged)
fi

if [[ "${MOUNT_DEV_INPUT}" = "1" ]]; then
  DOCKER_RUN_ARGS+=(-v /dev/input:/dev/input)
fi

DOCKER_RUN_ARGS+=(
  "${IMAGE_NAME}"
  bash -lc "sleep infinity"
)

"${DOCKER_CMD}" "${DOCKER_RUN_ARGS[@]}"

echo "Created container: ${CONTAINER_NAME}"
echo "Enter with:"
echo "  ${DOCKER_CMD} exec -it ${CONTAINER_NAME} bash"
