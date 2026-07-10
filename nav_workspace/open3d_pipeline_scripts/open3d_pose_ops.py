#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import shlex
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

try:
    from ruamel.yaml import YAML
    from ruamel.yaml.comments import CommentedSeq
except ImportError:  # pragma: no cover
    YAML = None
    CommentedSeq = list


ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_RECORD_FILE = ROOT_DIR / "open3d_nav_points_record.yaml"
DEFAULT_TRANSFORM_FILE = ROOT_DIR / "open3d_to_unitree_transform.yaml"
DEFAULT_CLIENT_CONFIG = Path(
    "/home/unitree/unitree_sdk2_python/agent/config/client_config.json"
)
DEFAULT_UNITREE_GET_POSE = Path(
    "/home/unitree/unitree_sdk2_python/navi_update/get_pose.py"
)


def yaml_loader() -> YAML:
    if YAML is None:
        raise SystemExit(
            "Missing dependency: ruamel.yaml. Use the conda/base python for record/sync, "
            "or install ruamel.yaml for the active Python."
        )
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.indent(mapping=2, sequence=4, offset=2)
    return yaml


def now_string() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def pose_to_flow(values: list[float]) -> CommentedSeq:
    pose = CommentedSeq(validate_pose(values))
    pose.fa.set_flow_style()
    return pose


def validate_pose(values: list[float]) -> list[float]:
    if len(values) != 7:
        raise ValueError("Pose must contain exactly 7 values")
    return [float(value) for value in values]


def parse_pose_line(line: str) -> list[float] | None:
    text = line.strip()
    if not text or text.startswith("#"):
        return None
    parts = text.split()
    if len(parts) != 7:
        return None
    try:
        pose = [float(part) for part in parts]
    except ValueError:
        return None
    if abs(pose[0]) < 1e-9 and abs(pose[1]) < 1e-9:
        return None
    return pose


def run_shell_pose_command(command: str) -> list[float]:
    result = subprocess.run(
        command,
        shell=True,
        executable="/bin/bash",
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode not in (0, 124):
        raise RuntimeError(
            f"Pose command failed with code {result.returncode}: {result.stderr.strip()}"
        )

    for line in reversed([line for line in result.stdout.splitlines() if line.strip()]):
        pose = parse_pose_line(line)
        if pose is not None:
            return pose
    raise RuntimeError("No valid pose received from pose command")


def ros2_env_prefix() -> str:
    return (
        "source /opt/ros/foxy/setup.bash >/dev/null && "
        "export RMW_IMPLEMENTATION=${OPEN3D_PIPELINE_RMW_IMPLEMENTATION:-${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}} && "
        "export CYCLONEDDS_HOME=${CYCLONEDDS_HOME:-/home/unitree/cyclonedds_ws/install/cyclonedds} && "
        "export LD_LIBRARY_PATH=${CYCLONEDDS_HOME}/lib:${LD_LIBRARY_PATH:-} && "
        "export ROS_LOG_DIR=${ROS_LOG_DIR:-/tmp} && "
        "export PYTHONPATH=/opt/ros/foxy/lib/python3.8/site-packages:/home/unitree/unitree_sdk2_python:${PYTHONPATH:-}"
    )


def unitree_pose_command(get_pose_script: Path = DEFAULT_UNITREE_GET_POSE) -> str:
    script = shlex.quote(str(get_pose_script))
    return f"{ros2_env_prefix()} && timeout 5 /usr/bin/python3 {script} simple 2>/dev/null | tail -1"


def open3d_pose_command(
    timeout: float,
    pose_topic: str,
    confidence_topic: str,
    min_confidence: float | None = None,
) -> str:
    self_path = shlex.quote(str(Path(__file__).resolve()))
    command = (
        f"{ros2_env_prefix()} && timeout {float(timeout):.1f} /usr/bin/python3 {self_path} "
        f"read-pose --pose-topic {shlex.quote(pose_topic)} "
        f"--confidence-topic {shlex.quote(confidence_topic)}"
    )
    if min_confidence is not None:
        command += f" --min-confidence {float(min_confidence):.6f}"
    return command


def quaternion_to_yaw(qx: float, qy: float, qz: float, qw: float) -> float:
    return math.atan2(2.0 * (qw * qz + qx * qy), 1.0 - 2.0 * (qy * qy + qz * qz))


def yaw_to_quaternion(yaw: float) -> tuple[float, float, float, float]:
    return 0.0, 0.0, math.sin(yaw * 0.5), math.cos(yaw * 0.5)


def normalize_angle(angle: float) -> float:
    while angle > math.pi:
        angle -= 2.0 * math.pi
    while angle < -math.pi:
        angle += 2.0 * math.pi
    return angle


def pose_yaw(pose: list[float]) -> float:
    return quaternion_to_yaw(pose[3], pose[4], pose[5], pose[6])


def planar_pose_transform(pose: list[float], transform: dict) -> list[float]:
    dx, dy, dz = [float(value) for value in transform.get("translation", [0.0, 0.0, 0.0])]
    yaw_offset = float(transform.get("yaw_offset_rad", 0.0))
    yaw = pose_yaw(pose) + yaw_offset
    qx, qy, qz, qw = yaw_to_quaternion(yaw)
    return [
        pose[0] + dx,
        pose[1] + dy,
        pose[2] + dz,
        qx,
        qy,
        qz,
        qw,
    ]


def transform_description(transform: dict | None) -> str:
    if transform is None:
        return "identity/no transform file applied"
    return (
        f"translation={transform.get('translation', [0.0, 0.0, 0.0])}, "
        f"yaw_offset_rad={float(transform.get('yaw_offset_rad', 0.0)):.6f}"
    )


def load_transform(path: Path) -> dict | None:
    if not path.exists():
        return None
    yaml = yaml_loader()
    with path.open("r", encoding="utf-8") as handle:
        data = yaml.load(handle) or {}
    return {
        "translation": data.get("translation", [0.0, 0.0, 0.0]),
        "yaw_offset_rad": float(data.get("yaw_offset_rad", 0.0)),
    }


def save_transform(path: Path, open3d_pose: list[float], unitree_pose: list[float]) -> dict:
    yaw_offset = normalize_angle(pose_yaw(unitree_pose) - pose_yaw(open3d_pose))
    transform = {
        "created_at": now_string(),
        "translation": [
            unitree_pose[0] - open3d_pose[0],
            unitree_pose[1] - open3d_pose[1],
            unitree_pose[2] - open3d_pose[2],
        ],
        "yaw_offset_rad": yaw_offset,
        "yaw_offset_deg": yaw_offset * 180.0 / math.pi,
        "source": "unitree_pose - open3d_pose at one calibration point",
    }
    yaml = yaml_loader()
    with path.open("w", encoding="utf-8") as handle:
        yaml.dump(transform, handle)
    return transform


def load_record_file(path: Path) -> dict:
    if not path.exists():
        return {
            "map_name": "",
            "map_path": "",
            "pose_source": "open3d_localization_3d",
            "transform_file": str(DEFAULT_TRANSFORM_FILE),
            "recorded_at": "",
            "notes": [
                "Pose order is [x, y, z, qx, qy, qz, qw].",
                "Run coordinate comparison before trusting Open3D poses for Unitree navigation.",
            ],
            "locations": {},
        }
    yaml = yaml_loader()
    with path.open("r", encoding="utf-8") as handle:
        data = yaml.load(handle) or {}
    data.setdefault("locations", {})
    return data


def save_record_file(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    yaml = yaml_loader()
    with path.open("w", encoding="utf-8") as handle:
        yaml.dump(data, handle)


def sample_pose(command: str, samples: int, interval: float) -> list[list[float]]:
    poses: list[list[float]] = []
    for index in range(samples):
        poses.append(run_shell_pose_command(command))
        if index != samples - 1:
            time.sleep(interval)
    return poses


def position_span(poses: list[list[float]]) -> tuple[float, float, float]:
    xs = [pose[0] for pose in poses]
    ys = [pose[1] for pose in poses]
    zs = [pose[2] for pose in poses]
    return max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs)


def backup_json_file(path: Path) -> Path:
    backup = Path(f"{path}.bak.{datetime.now().strftime('%Y%m%d_%H%M%S')}")
    backup.write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
    return backup


def command_read_pose(args: argparse.Namespace) -> int:
    # Imports stay local so sync/compare mock tests do not require ROS2.
    import rclpy
    from rclpy.node import Node
    from geometry_msgs.msg import PoseStamped
    from std_msgs.msg import Float32

    class PoseReader(Node):
        def __init__(self) -> None:
            super().__init__("open3d_pose_reader")
            self.pose: list[float] | None = None
            self.confidence: float | None = None
            self.create_subscription(PoseStamped, args.pose_topic, self.pose_cb, 10)
            self.create_subscription(Float32, args.confidence_topic, self.confidence_cb, 10)

        def confidence_cb(self, msg: Float32) -> None:
            self.confidence = float(msg.data)

        def pose_cb(self, msg: PoseStamped) -> None:
            p = msg.pose.position
            q = msg.pose.orientation
            pose = [p.x, p.y, p.z, q.x, q.y, q.z, q.w]
            if abs(pose[0]) > 1e-9 or abs(pose[1]) > 1e-9:
                self.pose = [float(value) for value in pose]

    rclpy.init(args=None)
    node = PoseReader()
    start = time.time()
    try:
        while rclpy.ok() and time.time() - start < args.timeout:
            rclpy.spin_once(node, timeout_sec=0.1)
            if node.pose is not None:
                if args.min_confidence is not None and node.confidence is not None:
                    if node.confidence < args.min_confidence:
                        continue
                print(" ".join(f"{value:.6f}" for value in node.pose))
                return 0
        print("No valid /localization_3d pose received", file=sys.stderr)
        return 2
    finally:
        node.destroy_node()
        rclpy.shutdown()


def command_check(args: argparse.Namespace) -> int:
    command = args.pose_command or open3d_pose_command(
        args.timeout, args.pose_topic, args.confidence_topic, args.min_confidence
    )
    try:
        poses = sample_pose(command, args.samples, args.interval)
    except RuntimeError as exc:
        print(f"Open3D localization check failed: {exc}", file=sys.stderr)
        print(
            "Make sure FAST-LIO and open3d_loc are running and /localization_3d is publishing.",
            file=sys.stderr,
        )
        return 2

    dx, dy, dz = position_span(poses)
    print("Open3D localization pose samples:")
    for idx, pose in enumerate(poses, start=1):
        print(f"  sample {idx}: {pose}")
    print(f"Position span: dx={dx:.4f} m, dy={dy:.4f} m, dz={dz:.4f} m")
    if (
        dx > args.position_tolerance
        or dy > args.position_tolerance
        or dz > args.position_tolerance
    ):
        print(
            "Open3D localization check failed: pose changed more than the configured tolerance.",
            file=sys.stderr,
        )
        print(
            "The pose is not stable enough for recording or navigation. "
            "Check for wrong global match, repeated scene features, bad initialpose, or mixed SLAM chains.",
            file=sys.stderr,
        )
        return 3
    print("Open3D localization is stable and above the configured confidence threshold.")
    print("Verify the global position on the map before recording points or starting navigation.")
    return 0


def command_compare(args: argparse.Namespace) -> int:
    open3d_command = args.open3d_pose_command or open3d_pose_command(
        args.timeout, args.pose_topic, args.confidence_topic, args.min_confidence
    )
    unitree_command = args.unitree_pose_command or unitree_pose_command(args.get_pose_script)
    open3d_pose = run_shell_pose_command(open3d_command)
    unitree_pose = run_shell_pose_command(unitree_command)

    delta = [
        unitree_pose[0] - open3d_pose[0],
        unitree_pose[1] - open3d_pose[1],
        unitree_pose[2] - open3d_pose[2],
    ]
    yaw_delta = normalize_angle(pose_yaw(unitree_pose) - pose_yaw(open3d_pose))
    print(f"Open3D pose:  {open3d_pose}")
    print(f"Unitree pose: {unitree_pose}")
    print(f"Delta xyz: dx={delta[0]:.4f}, dy={delta[1]:.4f}, dz={delta[2]:.4f}")
    print(f"Delta yaw: {yaw_delta:.6f} rad ({yaw_delta * 180.0 / math.pi:.3f} deg)")

    if args.save_transform:
        transform = save_transform(args.transform_file, open3d_pose, unitree_pose)
        print(f"Saved transform to: {args.transform_file}")
        print(json.dumps(transform, ensure_ascii=False, indent=2))

    if (
        abs(delta[0]) > args.max_position_delta
        or abs(delta[1]) > args.max_position_delta
        or abs(yaw_delta) > args.max_yaw_delta
    ):
        print("Warning: Open3D and Unitree frames are not directly equivalent.")
        return 1
    print("Open3D and Unitree pose frames are within configured tolerance.")
    return 0


def command_record(args: argparse.Namespace) -> int:
    command = args.pose_command or open3d_pose_command(
        args.timeout, args.pose_topic, args.confidence_topic, args.min_confidence
    )
    try:
        poses = sample_pose(command, args.samples, args.interval)
    except RuntimeError as exc:
        print(f"Record failed: {exc}", file=sys.stderr)
        return 2

    dx, dy, dz = position_span(poses)
    if (
        dx > args.position_tolerance
        or dy > args.position_tolerance
        or dz > args.position_tolerance
    ):
        print(
            "Record failed: Open3D pose changed more than the configured tolerance.",
            file=sys.stderr,
        )
        print(f"Position span during sampling: dx={dx:.4f} m, dy={dy:.4f} m, dz={dz:.4f} m")
        return 3

    selected_pose = validate_pose(poses[-1])
    should_apply_transform = (
        args.apply_transform if args.apply_transform is not None else args.transform_file.exists()
    )
    if should_apply_transform and not args.transform_file.exists():
        print(f"Record failed: transform file not found: {args.transform_file}", file=sys.stderr)
        return 2
    transform = load_transform(args.transform_file) if should_apply_transform else None
    output_pose = planar_pose_transform(selected_pose, transform) if transform else selected_pose

    data = load_record_file(args.record_file)
    data["recorded_at"] = now_string()
    data["pose_source"] = "open3d_localization_3d"
    data["record_format"] = "poses are unitree_frame_poses used for navigation; raw_open3d_poses keeps original /localization_3d"
    data["transform_file"] = str(args.transform_file) if transform else ""
    locations = data.setdefault("locations", {})
    entry = locations.setdefault(args.name, {"poses": [], "note": ""})
    raw_pose_flow = pose_to_flow(selected_pose)
    unitree_pose_flow = pose_to_flow(output_pose)
    if args.mode == "overwrite":
        entry["poses"] = [unitree_pose_flow]
        entry["raw_open3d_poses"] = [raw_pose_flow]
        entry["unitree_frame_poses"] = [pose_to_flow(output_pose)]
    else:
        entry.setdefault("poses", [])
        entry.setdefault("raw_open3d_poses", [])
        entry.setdefault("unitree_frame_poses", [])
        entry["poses"].append(unitree_pose_flow)
        entry["raw_open3d_poses"].append(raw_pose_flow)
        entry["unitree_frame_poses"].append(pose_to_flow(output_pose))
    if args.note is not None:
        entry["note"] = args.note
    entry["pose_source"] = "open3d_localization_3d"
    entry["poses_frame"] = "unitree_navigation_frame"
    entry["raw_open3d_poses_frame"] = "open3d_localization_3d"
    entry["unitree_frame_poses_frame"] = "unitree_navigation_frame"
    entry["transform_applied"] = bool(transform)
    entry["transform_file"] = str(args.transform_file) if transform else ""
    entry["transform_description"] = transform_description(transform)

    save_record_file(args.record_file, data)
    print(f"Recorded location: {args.name}")
    print(f"Raw Open3D pose: {selected_pose}")
    if transform:
        print(f"Applied transform: {args.transform_file}")
    else:
        print("Applied transform: none")
    print(f"Unitree-frame pose: {output_pose}")
    print("Saved pose field: unitree-frame pose")
    print(f"Position span during sampling: dx={dx:.4f} m, dy={dy:.4f} m, dz={dz:.4f} m")
    print(f"Saved to: {args.record_file}")
    return 0


def command_sync(args: argparse.Namespace) -> int:
    data = load_record_file(args.record_file)
    mapping: dict[str, list[list[float]]] = {}
    for name, entry in data.get("locations", {}).items():
        poses = entry.get("poses", [])
        if poses:
            mapping[name] = [validate_pose(pose) for pose in poses]

    if not mapping:
        print("No non-empty locations found in the record file. Nothing to sync.")
        return 0

    if not args.client_config.exists():
        print(f"Client config not found: {args.client_config}", file=sys.stderr)
        return 2

    client_data = json.loads(args.client_config.read_text(encoding="utf-8"))
    target_mapping = client_data.setdefault(args.mapping, {})
    for name, poses in mapping.items():
        target_mapping[name] = poses

    print(f"Target mapping: {args.mapping}")
    print("Locations to update:")
    for name in mapping:
        print(f"  - {name}")

    if args.dry_run:
        print("Dry-run only. client_config.json was not modified.")
        return 0

    if args.backup:
        backup = backup_json_file(args.client_config)
        print(f"Backup created: {backup}")
    args.client_config.write_text(
        json.dumps(client_data, ensure_ascii=False, indent=4) + "\n",
        encoding="utf-8",
    )
    print(f"Synchronized to: {args.client_config}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Open3D localization pose operations for Unitree navigation."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    read_pose = subparsers.add_parser("read-pose", help="Read one /localization_3d pose")
    read_pose.add_argument("--pose-topic", default="/localization_3d")
    read_pose.add_argument("--confidence-topic", default="/localization_3d_confidence")
    read_pose.add_argument("--timeout", type=float, default=5.0)
    read_pose.add_argument("--min-confidence", type=float, default=None)
    read_pose.set_defaults(func=command_read_pose)

    check = subparsers.add_parser("check", help="Check Open3D localization pose")
    check.add_argument("--pose-topic", default="/localization_3d")
    check.add_argument("--confidence-topic", default="/localization_3d_confidence")
    check.add_argument("--pose-command", default="")
    check.add_argument("--timeout", type=float, default=5.0)
    check.add_argument("--samples", type=int, default=3)
    check.add_argument("--interval", type=float, default=0.5)
    check.add_argument("--min-confidence", type=float, default=0.55)
    check.add_argument("--position-tolerance", type=float, default=0.15)
    check.set_defaults(func=command_check)

    compare = subparsers.add_parser("compare", help="Compare Open3D and Unitree pose frames")
    compare.add_argument("--pose-topic", default="/localization_3d")
    compare.add_argument("--confidence-topic", default="/localization_3d_confidence")
    compare.add_argument("--open3d-pose-command", default="")
    compare.add_argument("--unitree-pose-command", default="")
    compare.add_argument("--get-pose-script", type=Path, default=DEFAULT_UNITREE_GET_POSE)
    compare.add_argument("--timeout", type=float, default=5.0)
    compare.add_argument("--min-confidence", type=float, default=0.55)
    compare.add_argument("--save-transform", action="store_true")
    compare.add_argument("--transform-file", type=Path, default=DEFAULT_TRANSFORM_FILE)
    compare.add_argument("--max-position-delta", type=float, default=0.30)
    compare.add_argument("--max-yaw-delta", type=float, default=0.35)
    compare.set_defaults(func=command_compare)

    record = subparsers.add_parser("record", help="Record Open3D pose into YAML")
    record.add_argument("--name", required=True)
    record.add_argument("--mode", choices=("overwrite", "append"), default="overwrite")
    record.add_argument("--note", default=None)
    record.add_argument("--record-file", type=Path, default=DEFAULT_RECORD_FILE)
    record.add_argument("--transform-file", type=Path, default=DEFAULT_TRANSFORM_FILE)
    record.add_argument(
        "--apply-transform",
        action="store_true",
        default=None,
        help="Apply transform file before saving poses. Default: auto-apply when the file exists.",
    )
    record.add_argument(
        "--no-transform",
        action="store_false",
        dest="apply_transform",
        help="Do not apply transform even if the transform file exists.",
    )
    record.add_argument("--pose-topic", default="/localization_3d")
    record.add_argument("--confidence-topic", default="/localization_3d_confidence")
    record.add_argument("--pose-command", default="")
    record.add_argument("--timeout", type=float, default=5.0)
    record.add_argument("--min-confidence", type=float, default=0.55)
    record.add_argument("--samples", type=int, default=3)
    record.add_argument("--interval", type=float, default=0.5)
    record.add_argument("--position-tolerance", type=float, default=0.15)
    record.set_defaults(func=command_record)

    sync = subparsers.add_parser("sync", help="Sync Open3D YAML points into client JSON")
    sync.add_argument("--record-file", type=Path, default=DEFAULT_RECORD_FILE)
    sync.add_argument("--client-config", type=Path, default=DEFAULT_CLIENT_CONFIG)
    sync.add_argument("--mapping", default="location_poses_mapping")
    sync.add_argument("--dry-run", action="store_true")
    sync.add_argument("--no-backup", action="store_false", dest="backup")
    sync.set_defaults(func=command_sync, backup=True)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
