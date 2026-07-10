#!/usr/bin/env bash
set -euo pipefail

DOCKER_CMD="${DOCKER_CMD:-docker}"
CONTAINER_NAME="${CONTAINER_NAME:-mid360_go2_nav_humble}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace/autonomy-go2-mid360/workspace}"

SOURCE_FRAME="camera_init"
TARGET_FRAME="camera_init"
POINTS_SPEC=""
DEFAULT_Z="0.0"
OUTPUT_Z="0.0"
CLOSE_BOUNDARY=true
REPEAT_COUNT="1"
RATE_HZ="1.0"
WAIT_TF_SEC="3.0"
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage:
  bash publish_navigation_boundary.sh [options] X1 Y1 Z1 X2 Y2 Z2 ...
  bash publish_navigation_boundary.sh [options] --points "x1,y1,z1;x2,y2,z2;..."

Publish a manual navigation boundary to /navigation_boundary.

The localPlanner consumes /navigation_boundary numerically in camera_init, so
this script always publishes camera_init after optional TF conversion.

Examples:
  # Direct camera_init coordinates, closed rectangle.
  bash publish_navigation_boundary.sh --frame camera_init \
    --points "1.0,-1.0,0; 3.0,-1.0,0; 3.0,1.0,0; 1.0,1.0,0"

  # Map-frame coordinates. The script transforms map -> camera_init first.
  bash publish_navigation_boundary.sh --frame map \
    --points "10.0,2.0,0; 12.0,2.0,0; 12.0,4.0,0; 10.0,4.0,0"

Options:
  --frame FRAME          Input coordinate frame: camera_init or map. Default: camera_init
  --source-frame FRAME   Alias for --frame
  --points SPEC          Points as "x,y,z;x,y,z;..." or "x,y;x,y;..." when --default-z is set
  --default-z Z          Z used for 2D points in --points. Default: 0.0
  --output-z Z           Published boundary z for every point. Default: 0.0
                         Use --preserve-z to keep transformed/input z values.
  --preserve-z           Do not overwrite published z values
  --close                Repeat the first point at the end if needed. Default
  --no-close             Publish the polyline exactly as provided
  --repeat N             Publish N times. Default: 1
  --rate HZ              Publish rate when --repeat > 1. Default: 1.0
  --wait-tf SEC          Seconds to wait for TF when --frame is not camera_init. Default: 3.0
  --dry-run              Print the generated ROS message but do not publish
  --container NAME       Docker container name. Default: mid360_go2_nav_humble
  -h, --help             Show this help

Notes:
  - At least 3 points are required for a closed boundary.
  - For durable annotations, store map-frame points in JSON and convert them
    at publish time. For quick testing, camera_init points are simpler.
EOF
}

POSITIONAL=()

is_numeric() {
  awk -v v="$1" 'BEGIN { exit !(v ~ /^-?([0-9]+([.][0-9]*)?|[.][0-9]+)$/) }'
}

is_positive_int() {
  awk -v v="$1" 'BEGIN { exit !(v ~ /^[1-9][0-9]*$/) }'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --frame|--source-frame)
      SOURCE_FRAME="$2"
      shift 2
      ;;
    --points)
      POINTS_SPEC="$2"
      shift 2
      ;;
    --default-z)
      DEFAULT_Z="$2"
      shift 2
      ;;
    --output-z)
      OUTPUT_Z="$2"
      shift 2
      ;;
    --preserve-z)
      OUTPUT_Z=""
      shift
      ;;
    --close)
      CLOSE_BOUNDARY=true
      shift
      ;;
    --no-close)
      CLOSE_BOUNDARY=false
      shift
      ;;
    --repeat)
      REPEAT_COUNT="$2"
      shift 2
      ;;
    --rate)
      RATE_HZ="$2"
      shift 2
      ;;
    --wait-tf)
      WAIT_TF_SEC="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --container)
      CONTAINER_NAME="$2"
      shift 2
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

case "$SOURCE_FRAME" in
  camera_init|map) ;;
  *)
    echo "Unsupported --frame: ${SOURCE_FRAME}. Use camera_init or map." >&2
    exit 2
    ;;
esac

for value in "$DEFAULT_Z" "$WAIT_TF_SEC" "$RATE_HZ"; do
  if ! is_numeric "$value"; then
    echo "Invalid numeric value: $value" >&2
    exit 2
  fi
done

if [[ -n "$OUTPUT_Z" ]] && ! is_numeric "$OUTPUT_Z"; then
  echo "Invalid --output-z value: $OUTPUT_Z" >&2
  exit 2
fi

if ! is_positive_int "$REPEAT_COUNT"; then
  echo "Invalid --repeat value: $REPEAT_COUNT" >&2
  exit 2
fi

if [[ -n "$POINTS_SPEC" && ${#POSITIONAL[@]} -gt 0 ]]; then
  echo "Use either --points or positional coordinates, not both." >&2
  exit 2
fi

if [[ -z "$POINTS_SPEC" && ${#POSITIONAL[@]} -eq 0 ]]; then
  usage >&2
  exit 2
fi

if ! "${DOCKER_CMD}" inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" >/dev/null 2>&1; then
  echo "Container is not running: ${CONTAINER_NAME}" >&2
  echo "Start it first, for example:" >&2
  echo "  bash /home/unitree/go2-fast-lio/nav_workspace/autonomy-go2-mid360/scripts/run_container.sh" >&2
  exit 2
fi

"${DOCKER_CMD}" exec -i "${CONTAINER_NAME}" bash -s -- \
  "$SOURCE_FRAME" "$TARGET_FRAME" "$POINTS_SPEC" "$DEFAULT_Z" "$OUTPUT_Z" \
  "$CLOSE_BOUNDARY" "$REPEAT_COUNT" "$RATE_HZ" "$WAIT_TF_SEC" "$DRY_RUN" \
  "$WORKSPACE_DIR" "${POSITIONAL[@]}" <<'EOF'
set -euo pipefail

SOURCE_FRAME="$1"
TARGET_FRAME="$2"
POINTS_SPEC="$3"
DEFAULT_Z="$4"
OUTPUT_Z="$5"
CLOSE_BOUNDARY="$6"
REPEAT_COUNT="$7"
RATE_HZ="$8"
WAIT_TF_SEC="$9"
DRY_RUN="${10}"
WORKSPACE_DIR="${11}"
shift 11
POINT_ARGS=("$@")

set +u
source /opt/ros/humble/setup.bash
if [[ -f /workspace/nav_ws/install/setup.bash ]]; then
  source /workspace/nav_ws/install/setup.bash
fi
source "${WORKSPACE_DIR}/install/setup.bash"
set -u
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"

MSG="$(
  python3 - "$SOURCE_FRAME" "$TARGET_FRAME" "$POINTS_SPEC" "$DEFAULT_Z" \
    "$OUTPUT_Z" "$CLOSE_BOUNDARY" "$WAIT_TF_SEC" "${POINT_ARGS[@]}" <<'PY'
import math
import re
import sys
import time

source_frame = sys.argv[1]
target_frame = sys.argv[2]
points_spec = sys.argv[3]
default_z = float(sys.argv[4])
output_z_arg = sys.argv[5]
output_z = None if output_z_arg == "" else float(output_z_arg)
close_boundary = sys.argv[6].lower() == "true"
wait_tf_sec = float(sys.argv[7])
point_args = sys.argv[8:]


def parse_points():
    points = []
    if points_spec:
        chunks = [c.strip() for c in points_spec.split(";") if c.strip()]
        for chunk in chunks:
            values = [v for v in re.split(r"[\s,]+", chunk) if v]
            if len(values) == 2:
                x, y = map(float, values)
                z = default_z
            elif len(values) == 3:
                x, y, z = map(float, values)
            else:
                raise SystemExit(
                    f"Invalid point '{chunk}'. Use x,y or x,y,z."
                )
            points.append((x, y, z))
    else:
        if len(point_args) % 3 != 0:
            raise SystemExit(
                "Positional coordinates must be X Y Z triplets. "
                "Use --points for x,y pairs."
            )
        for i in range(0, len(point_args), 3):
            points.append(tuple(map(float, point_args[i : i + 3])))

    min_points = 3 if close_boundary else 2
    if len(points) < min_points:
        raise SystemExit(f"Need at least {min_points} points.")
    return points


def quat_rotate(q, p):
    qx, qy, qz, qw = q
    x, y, z = p
    tx = 2.0 * (qy * z - qz * y)
    ty = 2.0 * (qz * x - qx * z)
    tz = 2.0 * (qx * y - qy * x)
    return (
        x + qw * tx + (qy * tz - qz * ty),
        y + qw * ty + (qz * tx - qx * tz),
        z + qw * tz + (qx * ty - qy * tx),
    )


def lookup_transform():
    if source_frame == target_frame:
        return None
    try:
        import rclpy
        from rclpy.time import Time
        import tf2_ros
    except Exception as exc:
        raise SystemExit(f"Cannot import ROS2 tf2 Python modules: {exc}")

    rclpy.init(args=None)
    node = rclpy.create_node("manual_boundary_tf_lookup")
    buffer = tf2_ros.Buffer()
    listener = tf2_ros.TransformListener(buffer, node)
    deadline = time.time() + wait_tf_sec
    last_error = None
    try:
        while time.time() < deadline:
            rclpy.spin_once(node, timeout_sec=0.1)
            try:
                return buffer.lookup_transform(target_frame, source_frame, Time())
            except Exception as exc:
                last_error = exc
        raise SystemExit(
            f"Cannot lookup TF {source_frame} -> {target_frame}: {last_error}"
        )
    finally:
        node.destroy_node()
        rclpy.shutdown()


points = parse_points()
transform = lookup_transform()
out_points = []

if transform is None:
    out_points = list(points)
else:
    t = transform.transform.translation
    r = transform.transform.rotation
    quat = (r.x, r.y, r.z, r.w)
    trans = (t.x, t.y, t.z)
    for p in points:
        rx, ry, rz = quat_rotate(quat, p)
        out_points.append((rx + trans[0], ry + trans[1], rz + trans[2]))

if output_z is not None:
    out_points = [(x, y, output_z) for x, y, _ in out_points]

if close_boundary:
    first = out_points[0]
    last = out_points[-1]
    if any(abs(first[i] - last[i]) > 1e-6 for i in range(3)):
        out_points.append(first)

point_items = []
for x, y, z in out_points:
    point_items.append(f"{{x: {x:.6f}, y: {y:.6f}, z: {z:.6f}}}")

print(
    "{header: {frame_id: "
    + target_frame
    + "}, polygon: {points: ["
    + ", ".join(point_items)
    + "]}}"
)
PY
)"

echo "Input frame: ${SOURCE_FRAME}"
echo "Publish frame: ${TARGET_FRAME}"
echo "Message:"
echo "${MSG}"

if [[ "${DRY_RUN}" == "true" ]]; then
  exit 0
fi

SUB_COUNT="$(ros2 topic info -v /navigation_boundary 2>/dev/null | awk -F': ' '$1 == "Subscription count" {print $2; exit}' || true)"
SUB_COUNT="${SUB_COUNT:-0}"
if (( SUB_COUNT < 1 )); then
  echo "WARNING: /navigation_boundary has no subscribers. Is localPlanner running?" >&2
fi

INTERVAL="$(awk -v hz="${RATE_HZ}" 'BEGIN { if (hz <= 0) print "1.0"; else printf "%.6f", 1.0 / hz }')"
for ((i = 1; i <= REPEAT_COUNT; i++)); do
  echo "Publishing /navigation_boundary (${i}/${REPEAT_COUNT})"
  ros2 topic pub --once /navigation_boundary geometry_msgs/msg/PolygonStamped "${MSG}"
  if (( i < REPEAT_COUNT )); then
    sleep "${INTERVAL}"
  fi
done
EOF
