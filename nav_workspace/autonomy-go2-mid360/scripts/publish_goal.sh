#!/usr/bin/env bash
# Usage example:
#   # After reaching a goal, reset FAR graph, wait for rebuild, then publish a new map-frame goal.
#   bash /home/unitree/go2-fast-lio/nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --reset-graph --real-robot-ok 1.0 2.0 0.0
set -euo pipefail

DOCKER_CMD="${DOCKER_CMD:-docker}"
CONTAINER_NAME="${CONTAINER_NAME:-mid360_go2_nav_humble}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace/autonomy-go2-mid360/workspace}"

FORCE=false
ALLOW_REAL_ROBOT=false
CHECK_ONLY=false
FRAME_ID="map"
WAIT_SECONDS="20"
VERIFY=true
RESET_GRAPH=false

usage() {
  cat <<'EOF'
Usage: bash publish_goal.sh [options] X Y Z

Publish a guarded FAR planner goal to /goal_point.

Example:
  bash /home/unitree/go2-fast-lio/nav_workspace/autonomy-go2-mid360/scripts/publish_goal.sh --reset-graph --real-robot-ok X Y Z

Options:
  --force          Publish even if an active /way_point_global is detected
  --real-robot-ok  Allow publishing when pathFollower has is_real_robot=true
  --check-only     Run readiness checks but do not publish a goal
  --reset-graph    Publish /reset_visibility_graph and wait for /robot_vgraph before the goal
  --frame FRAME    Goal frame_id. Default: map
  --wait SEC       Seconds to wait for planner output after publishing. Default: 20
  --no-verify      Publish only; do not wait for /way_point_global and /viz_path_topic
  -h, --help       Show this help

Default behavior:
  - Requires the container, relocalization, FAR planner, and V-Graph to be ready
  - Refuses to overwrite an active goal unless --force is used
EOF
}

POSITIONAL=()
is_numeric() {
  awk -v v="$1" 'BEGIN { exit !(v ~ /^-?([0-9]+([.][0-9]*)?|[.][0-9]+)$/) }'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=true
      shift
      ;;
    --real-robot-ok)
      ALLOW_REAL_ROBOT=true
      shift
      ;;
    --check-only)
      CHECK_ONLY=true
      shift
      ;;
    --reset-graph)
      RESET_GRAPH=true
      shift
      ;;
    --frame)
      FRAME_ID="$2"
      shift 2
      ;;
    --wait)
      WAIT_SECONDS="$2"
      shift 2
      ;;
    --no-verify)
      VERIFY=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        POSITIONAL+=("$1")
        shift
      done
      ;;
    -*)
      if is_numeric "$1"; then
        POSITIONAL+=("$1")
        shift
        continue
      fi
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [[ ${#POSITIONAL[@]} -ne 3 ]]; then
  usage >&2
  exit 2
fi

X="${POSITIONAL[0]}"
Y="${POSITIONAL[1]}"
Z="${POSITIONAL[2]}"

for value in "$X" "$Y" "$Z" "$WAIT_SECONDS"; do
  if ! is_numeric "$value"; then
    echo "Invalid numeric value: $value" >&2
    exit 2
  fi
done

if ! "${DOCKER_CMD}" inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" >/dev/null 2>&1; then
  echo "Container is not running: ${CONTAINER_NAME}" >&2
  exit 2
fi

"${DOCKER_CMD}" exec -i "${CONTAINER_NAME}" bash -s -- \
  "$X" "$Y" "$Z" "$FRAME_ID" "$FORCE" "$ALLOW_REAL_ROBOT" \
  "$CHECK_ONLY" "$WAIT_SECONDS" "$VERIFY" "$RESET_GRAPH" "$WORKSPACE_DIR" <<'EOF'
set -euo pipefail

X="$1"
Y="$2"
Z="$3"
FRAME_ID="$4"
FORCE="$5"
ALLOW_REAL_ROBOT="$6"
CHECK_ONLY="$7"
WAIT_SECONDS="$8"
VERIFY="$9"
RESET_GRAPH="${10}"
WORKSPACE_DIR="${11}"

set +u
source /opt/ros/humble/setup.bash
if [[ -f /workspace/nav_ws/install/setup.bash ]]; then
  source /workspace/nav_ws/install/setup.bash
fi
source "${WORKSPACE_DIR}/install/setup.bash"
set -u
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"

topic_count() {
  local topic="$1"
  local label="$2"
  ros2 topic info -v "$topic" 2>/dev/null | awk -F': ' -v label="$label" '$1 == label {print $2; exit}' || true
}

require_count() {
  local topic="$1"
  local label="$2"
  local min_count="$3"
  local count
  count="$(topic_count "$topic" "$label")"
  count="${count:-0}"
  if (( count < min_count )); then
    echo "ERROR: ${topic} ${label} ${count}, expected >= ${min_count}" >&2
    exit 1
  fi
}

echo "Checking navigation stack..."
require_count /goal_point "Subscription count" 1
require_count /way_point_global "Publisher count" 1
require_count /way_point "Publisher count" 1
require_count /far_reach_goal_status "Publisher count" 1
require_count /baselink2map "Publisher count" 1
require_count /robot_vgraph "Publisher count" 1
if [[ "$RESET_GRAPH" == "true" ]]; then
  require_count /reset_visibility_graph "Subscription count" 1
fi

PATH_FOLLOWER_REAL_ROBOT="unknown"
if PATH_FOLLOWER_PARAM="$(timeout 3 ros2 param get /pathFollower is_real_robot 2>/dev/null)"; then
  if grep -qi "true" <<<"${PATH_FOLLOWER_PARAM}"; then
    PATH_FOLLOWER_REAL_ROBOT="true"
  elif grep -qi "false" <<<"${PATH_FOLLOWER_PARAM}"; then
    PATH_FOLLOWER_REAL_ROBOT="false"
  fi
fi

if [[ "${PATH_FOLLOWER_REAL_ROBOT}" == "unknown" ]] && \
    ros2 topic info -v /api/sport/request 2>/dev/null | grep -q "Node name: pathFollower"; then
  echo "WARN: Could not read /pathFollower is_real_robot; treating sport publisher as real-robot control." >&2
  PATH_FOLLOWER_REAL_ROBOT="true"
fi

if [[ "${PATH_FOLLOWER_REAL_ROBOT}" == "true" && "$ALLOW_REAL_ROBOT" != "true" ]]; then
  echo "ERROR: pathFollower is configured with is_real_robot=true." >&2
  echo "Re-run with --real-robot-ok only after confirming that physical motion is intended." >&2
  exit 4
fi

if ! timeout 5 ros2 topic echo --once /baselink2map --field pose.pose.position >/tmp/publish_goal_pose 2>/tmp/publish_goal_pose.err; then
  echo "ERROR: Cannot read /baselink2map. Relocalization is not ready." >&2
  sed -n '1,40p' /tmp/publish_goal_pose.err >&2 || true
  exit 1
fi

if ! timeout 5 ros2 topic echo --once /robot_vgraph --field size >/tmp/publish_goal_graph_size 2>/tmp/publish_goal_graph.err; then
  echo "ERROR: Cannot read /robot_vgraph. FAR V-Graph is not ready." >&2
  sed -n '1,40p' /tmp/publish_goal_graph.err >&2 || true
  exit 1
fi

GRAPH_SIZE="$(tr -d '\r\n ' </tmp/publish_goal_graph_size)"
if [[ -z "$GRAPH_SIZE" || "$GRAPH_SIZE" == "0" ]]; then
  echo "ERROR: /robot_vgraph size is ${GRAPH_SIZE:-empty}. Wait for FAR V-Graph initialization." >&2
  exit 1
fi

ACTIVE_GOAL=false
if timeout 1.5 ros2 topic echo --once /way_point_global >/tmp/publish_goal_active_waypoint 2>/dev/null; then
  REACH_STATUS="unknown"
  if timeout 1.5 ros2 topic echo --once /far_reach_goal_status --field data >/tmp/publish_goal_reach_status 2>/dev/null; then
    REACH_STATUS="$(tr -d '\r\n ' </tmp/publish_goal_reach_status)"
  fi
  if [[ "$REACH_STATUS" != "true" ]]; then
    ACTIVE_GOAL=true
  fi
fi

if [[ "$ACTIVE_GOAL" == "true" && "$FORCE" != "true" && "$RESET_GRAPH" != "true" ]]; then
  echo "ERROR: Active /way_point_global detected and /far_reach_goal_status is not true." >&2
  echo "Refusing to overwrite the current goal. Re-run with --force to replace it, or --reset-graph to clear FAR graph first." >&2
  exit 3
fi

echo "Current /baselink2map position:"
sed -n '1,20p' /tmp/publish_goal_pose
echo "FAR graph size: ${GRAPH_SIZE}"
if [[ "$ACTIVE_GOAL" == "true" && "$FORCE" == "true" ]]; then
  echo "Active goal detected; replacing because --force was set."
elif [[ "$ACTIVE_GOAL" == "true" && "$RESET_GRAPH" == "true" ]]; then
  echo "Active goal detected; clearing FAR graph because --reset-graph was set."
fi

if [[ "$CHECK_ONLY" == "true" ]]; then
  echo "Check-only mode: goal was not published."
  exit 0
fi

if [[ "$RESET_GRAPH" == "true" ]]; then
  echo "Resetting FAR visibility graph..."
  ros2 topic pub --once /reset_visibility_graph std_msgs/msg/Empty "{}" >/tmp/publish_goal_reset_pub
  sed -n '1,20p' /tmp/publish_goal_reset_pub

  rm -f /tmp/publish_goal_graph_size_after_reset /tmp/publish_goal_graph_after_reset.err
  if ! timeout "$WAIT_SECONDS" bash -c '
    set -euo pipefail
    while true; do
      if timeout 2 ros2 topic echo --once /robot_vgraph --field size >/tmp/publish_goal_graph_size_after_reset 2>/tmp/publish_goal_graph_after_reset.err; then
        size="$(tr -d "\r\n " </tmp/publish_goal_graph_size_after_reset)"
        if [[ -n "$size" && "$size" != "0" ]]; then
          exit 0
        fi
      fi
      sleep 1
    done
  '; then
    echo "ERROR: /robot_vgraph did not become ready after reset within ${WAIT_SECONDS}s." >&2
    sed -n '1,40p' /tmp/publish_goal_graph_after_reset.err >&2 || true
    exit 1
  fi

  GRAPH_SIZE="$(tr -d '\r\n ' </tmp/publish_goal_graph_size_after_reset)"
  echo "FAR graph reset complete. Graph size: ${GRAPH_SIZE}"
fi

if [[ "$VERIFY" == "true" ]]; then
  rm -f /tmp/publish_goal_echo /tmp/publish_goal_waypoint_global /tmp/publish_goal_waypoint /tmp/publish_goal_path
  (timeout "$WAIT_SECONDS" ros2 topic echo --once /goal_point >/tmp/publish_goal_echo 2>&1) &
  goal_echo_pid=$!
  (timeout "$WAIT_SECONDS" ros2 topic echo --once /way_point_global >/tmp/publish_goal_waypoint_global 2>&1) &
  wpg_pid=$!
  (timeout "$WAIT_SECONDS" ros2 topic echo --once /way_point >/tmp/publish_goal_waypoint 2>&1) &
  wp_pid=$!
  (timeout "$WAIT_SECONDS" ros2 topic echo --once /viz_path_topic --field points >/tmp/publish_goal_path 2>&1) &
  path_pid=$!
  sleep 0.5
fi

echo "Publishing /goal_point: frame=${FRAME_ID}, x=${X}, y=${Y}, z=${Z}"
ros2 topic pub --once /goal_point geometry_msgs/msg/PointStamped \
  "{header: {frame_id: ${FRAME_ID}}, point: {x: ${X}, y: ${Y}, z: ${Z}}}" >/tmp/publish_goal_pub
sed -n '1,20p' /tmp/publish_goal_pub

if [[ "$VERIFY" != "true" ]]; then
  exit 0
fi

wait "$goal_echo_pid" || true
wait "$wpg_pid" || true
wait "$wp_pid" || true
wait "$path_pid" || true

if [[ ! -s /tmp/publish_goal_echo ]]; then
  echo "ERROR: Published goal was not observed on /goal_point." >&2
  exit 1
fi
if [[ ! -s /tmp/publish_goal_waypoint_global ]]; then
  echo "ERROR: No /way_point_global received after goal. FAR may not have accepted/planned the goal." >&2
  exit 1
fi
if [[ ! -s /tmp/publish_goal_waypoint ]]; then
  echo "ERROR: No /way_point received after goal. Frame bridge may not be working." >&2
  exit 1
fi

echo "Planner accepted goal."
echo "/way_point_global:"
sed -n '1,30p' /tmp/publish_goal_waypoint_global
echo "/way_point:"
sed -n '1,30p' /tmp/publish_goal_waypoint

if [[ -s /tmp/publish_goal_path ]]; then
  echo "/viz_path_topic points:"
  sed -n '1,20p' /tmp/publish_goal_path
else
  echo "WARN: No /viz_path_topic received within ${WAIT_SECONDS}s. Check Foxglove after planner updates."
fi
EOF
