#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_CMD="${DOCKER_CMD:-docker}"
IMAGE_NAME="${IMAGE_NAME:-mid360-go2-nav:humble}"
BASE_IMAGE="${BASE_IMAGE:-ros:humble-ros-base}"
INSTALL_APT_DEPS="${INSTALL_APT_DEPS:-1}"
INSTALL_PIP_DEPS="${INSTALL_PIP_DEPS:-1}"

"${DOCKER_CMD}" build \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "INSTALL_APT_DEPS=${INSTALL_APT_DEPS}" \
  --build-arg "INSTALL_PIP_DEPS=${INSTALL_PIP_DEPS}" \
  -t "${IMAGE_NAME}" \
  -f "${BASE_DIR}/docker/Dockerfile.humble" \
  "${BASE_DIR}"

echo "Built image: ${IMAGE_NAME}"
