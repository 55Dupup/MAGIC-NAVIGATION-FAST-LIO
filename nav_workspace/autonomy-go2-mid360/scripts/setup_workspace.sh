#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${BASE_DIR:-/workspace/autonomy-go2-mid360}"
WORKSPACE_DIR="${WORKSPACE_DIR:-${BASE_DIR}/workspace}"
AUTONOMY_REPO="${AUTONOMY_REPO:-https://github.com/jizhang-cmu/autonomy_stack_go2.git}"
AUTONOMY_BRANCH="${AUTONOMY_BRANCH:-foxy-humble}"
SKIP_ROSDEP="${SKIP_ROSDEP:-0}"
CLEAN_CMAKE_CACHE="${CLEAN_CMAKE_CACHE:-0}"
ENABLE_OPEN3D_LOC="${ENABLE_OPEN3D_LOC:-1}"
CC="${NAV_CC:-/usr/bin/gcc}"
CXX="${NAV_CXX:-/usr/bin/g++}"
export CC CXX

set +u
source /opt/ros/humble/setup.bash
set -u

mkdir -p "${WORKSPACE_DIR}/src"

if [[ ! -d "${WORKSPACE_DIR}/src/autonomy_stack_go2/.git" ]]; then
  if ! git clone --branch "${AUTONOMY_BRANCH}" --depth 1 \
      "${AUTONOMY_REPO}" \
      "${WORKSPACE_DIR}/src/autonomy_stack_go2"; then
    echo "Initial clone failed; retrying with Git HTTP/1.1 ..." >&2
    rm -rf "${WORKSPACE_DIR}/src/autonomy_stack_go2"
    git -c http.version=HTTP/1.1 clone --branch "${AUTONOMY_BRANCH}" --depth 1 \
      "${AUTONOMY_REPO}" \
      "${WORKSPACE_DIR}/src/autonomy_stack_go2"
  fi
else
  echo "autonomy_stack_go2 already exists; skipping clone."
fi

BRIDGE_SRC="${BASE_DIR}/workspace/src/mid360_go2_nav_bridge"
if [[ ! -d "${BRIDGE_SRC}" ]]; then
  echo "Bridge package is missing: ${BRIDGE_SRC}" >&2
  exit 2
fi

if [[ "${ENABLE_OPEN3D_LOC}" = "1" ]]; then
  OPEN3D_LOC_SRC="/workspace/nav_ws/src/fast/open3d_loc"
  OPEN3D_LOC_LINK="${WORKSPACE_DIR}/src/open3d_loc"
  if [[ -d "${OPEN3D_LOC_SRC}" && ! -e "${OPEN3D_LOC_LINK}" ]]; then
    ln -s "${OPEN3D_LOC_SRC}" "${OPEN3D_LOC_LINK}"
    echo "Linked Open3D localization package: ${OPEN3D_LOC_LINK}"
  elif [[ ! -d "${OPEN3D_LOC_SRC}" ]]; then
    echo "Open3D localization source not found; skipping: ${OPEN3D_LOC_SRC}" >&2
  fi
else
  echo "ENABLE_OPEN3D_LOC=0; not linking Open3D localization package."
fi

cd "${WORKSPACE_DIR}"

if [[ "${SKIP_ROSDEP}" = "1" ]]; then
  echo "SKIP_ROSDEP=1; skipping rosdep update/install."
elif command -v rosdep >/dev/null 2>&1; then
  rosdep update || true
  rosdep install --from-paths src --ignore-src -r -y || true
fi

COLCON_ARGS=(--symlink-install)
if [[ "${CLEAN_CMAKE_CACHE}" = "1" ]]; then
  COLCON_ARGS+=(--cmake-clean-cache)
fi
COLCON_ARGS+=(--cmake-args -DCMAKE_BUILD_TYPE=Release)

colcon build "${COLCON_ARGS[@]}"

echo "Workspace built:"
echo "  ${WORKSPACE_DIR}"
echo "Source it with:"
echo "  source ${WORKSPACE_DIR}/install/setup.bash"
