#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAR="/home/unitree/go2-fast-lio/unitree_humble_dev_latest.tar"
HOST_WS="/home/unitree/go2-fast-lio/nav_workspace"
CONTAINER_NAME="unitree_humble_nav"

if [[ ! -f "${IMAGE_TAR}" ]]; then
  echo "Image tar not found: ${IMAGE_TAR}" >&2
  exit 1
fi

if [[ ! -d "${HOST_WS}" ]]; then
  echo "Host workspace not found: ${HOST_WS}" >&2
  exit 1
fi

echo "Loading Docker image from ${IMAGE_TAR} ..."
LOAD_OUTPUT="$(docker load -i "${IMAGE_TAR}")"
echo "${LOAD_OUTPUT}"

IMAGE_NAME="$(printf '%s\n' "${LOAD_OUTPUT}" | awk -F': ' '/Loaded image:/ {print $2}' | tail -n 1)"
if [[ -z "${IMAGE_NAME}" ]]; then
  IMAGE_NAME="unitree_humble_dev:latest"
fi

if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
  if docker image inspect unitree_humble_dev:latest >/dev/null 2>&1; then
    IMAGE_NAME="unitree_humble_dev:latest"
  elif docker image inspect unitree_humble_dev >/dev/null 2>&1; then
    IMAGE_NAME="unitree_humble_dev"
  else
    echo "Could not determine loaded image name. Check 'docker images'." >&2
    exit 1
  fi
fi

echo "Using image: ${IMAGE_NAME}"

if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
  echo "Container ${CONTAINER_NAME} already exists. Starting it."
  docker start "${CONTAINER_NAME}" >/dev/null
  echo "Done. Enter it with:"
  echo "  docker exec -it ${CONTAINER_NAME} zsh"
  exit 0
fi

echo "Creating container ${CONTAINER_NAME} ..."
docker run -it \
  --name "${CONTAINER_NAME}" \
  --network host \
  --privileged \
  --runtime nvidia \
  -e DISPLAY="${DISPLAY:-}" \
  -e QT_X11_NO_MITSHM=1 \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
  -v "${HOST_WS}:/workspace/nav_ws" \
  "${IMAGE_NAME}" \
  zsh
