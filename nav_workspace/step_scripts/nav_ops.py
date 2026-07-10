#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

try:
    from ruamel.yaml import YAML
    from ruamel.yaml.comments import CommentedSeq
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "Missing dependency: ruamel.yaml. Install it before using this tool."
    ) from exc


ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_RECORD_FILE = ROOT_DIR / "nav_points_record.yaml"
DEFAULT_CLIENT_CONFIG = Path(
    "/home/unitree/unitree_sdk2_python/agent/config/client_config.json"
)
DEFAULT_GET_POSE_SCRIPT = Path(
    "/home/unitree/unitree_sdk2_python/navi_update/get_pose.py"
)


def now_string() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def yaml_loader() -> YAML:
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.indent(mapping=2, sequence=4, offset=2)
    return yaml


def default_pose_command(get_pose_script: Path) -> str:
    script = shlex.quote(str(get_pose_script))
    return (
        "unset ROS_DISTRO ROS_VERSION ROS_PYTHON_VERSION ROS_PACKAGE_PATH AMENT_PREFIX_PATH CMAKE_PREFIX_PATH && "
        "source /opt/ros/foxy/setup.bash >/dev/null && "
        "export RMW_IMPLEMENTATION=${UNITREE_NAV_RMW_IMPLEMENTATION:-${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}} && "
        "export CYCLONEDDS_HOME=${CYCLONEDDS_HOME:-/home/unitree/cyclonedds_ws/install/cyclonedds} && "
        "export LD_LIBRARY_PATH=${CYCLONEDDS_HOME}/lib:${LD_LIBRARY_PATH:-} && "
        "export ROS_LOG_DIR=${ROS_LOG_DIR:-/tmp} && "
        "export PYTHONPATH=/opt/ros/foxy/lib/python3.8/site-packages:/home/unitree/unitree_sdk2_python:${PYTHONPATH:-} && "
        f"timeout 5 /usr/bin/python3 {script} simple 2>/dev/null | tail -1"
    )


def load_record_file(record_file: Path) -> dict:
    if not record_file.exists():
        return {
            "map_name": "",
            "map_path": "",
            "recorded_by": "",
            "recorded_at": "",
            "notes": [
                "先完成重定位，再采点。",
                "每个 pose 的顺序固定为 [x, y, z, qx, qy, qz, qw]。",
            ],
            "locations": {},
        }

    yaml = yaml_loader()
    with record_file.open("r", encoding="utf-8") as handle:
        data = yaml.load(handle) or {}

    if "locations" not in data or data["locations"] is None:
        data["locations"] = {}
    return data


def save_record_file(record_file: Path, data: dict) -> None:
    record_file.parent.mkdir(parents=True, exist_ok=True)
    yaml = yaml_loader()
    with record_file.open("w", encoding="utf-8") as handle:
        yaml.dump(data, handle)


def validate_pose(values: list[float]) -> list[float]:
    if len(values) != 7:
        raise ValueError("Pose must contain exactly 7 values")
    return [float(value) for value in values]


def flow_pose(values: list[float]) -> CommentedSeq:
    pose = CommentedSeq(validate_pose(values))
    pose.fa.set_flow_style()
    return pose


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


def run_pose_command(command: str) -> list[float]:
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

    lines = [line for line in result.stdout.splitlines() if line.strip()]
    for line in reversed(lines):
        pose = parse_pose_line(line)
        if pose is not None:
            return pose

    raise RuntimeError("No valid pose received from /slam_info")


def sample_pose(command: str, samples: int, interval: float) -> list[list[float]]:
    poses: list[list[float]] = []
    for index in range(samples):
        poses.append(run_pose_command(command))
        if index != samples - 1:
            time.sleep(interval)
    return poses


def position_span(poses: list[list[float]]) -> tuple[float, float]:
    xs = [pose[0] for pose in poses]
    ys = [pose[1] for pose in poses]
    return max(xs) - min(xs), max(ys) - min(ys)


def backup_json_file(client_config: Path) -> Path:
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup = Path(f"{client_config}.bak.{timestamp}")
    backup.write_text(client_config.read_text(encoding="utf-8"), encoding="utf-8")
    return backup


def command_check(args: argparse.Namespace) -> int:
    command = args.pose_command or default_pose_command(args.get_pose_script)
    try:
        poses = sample_pose(command, args.samples, args.interval)
    except RuntimeError as exc:
        print(f"Relocalization check failed: {exc}", file=sys.stderr)
        print(
            "No valid currentPose was received from /slam_info. "
            "Go back to the go2_relocation tmux pane, press lowercase 'a', "
            "and confirm it prints 'Successfully started relocation'.",
            file=sys.stderr,
        )
        print(
            "If the pane prints 'Stop slam success' or ICP errorCode=509, "
            "relocalization is not valid yet.",
            file=sys.stderr,
        )
        return 2
    dx, dy = position_span(poses)

    print("Relocalization pose samples:")
    for idx, pose in enumerate(poses, start=1):
        print(f"  sample {idx}: {pose}")
    print(f"Position span: dx={dx:.4f} m, dy={dy:.4f} m")

    if dx > args.position_tolerance or dy > args.position_tolerance:
        print(
            "Warning: pose changed more than the configured tolerance. "
            "The robot may still be moving."
        )

    print("Relocalization looks valid. You can start recording points.")
    return 0


def command_record(args: argparse.Namespace) -> int:
    command = args.pose_command or default_pose_command(args.get_pose_script)
    try:
        poses = sample_pose(command, args.samples, args.interval)
    except RuntimeError as exc:
        print(f"Record failed: {exc}", file=sys.stderr)
        print(
            "No valid currentPose was received from /slam_info. "
            "Run step2 successfully before recording points.",
            file=sys.stderr,
        )
        return 2
    dx, dy = position_span(poses)
    selected_pose = validate_pose(poses[-1])

    data = load_record_file(args.record_file)
    locations = data.setdefault("locations", {})
    location_entry = locations.setdefault(args.name, {"poses": [], "note": ""})

    if args.mode == "overwrite":
        location_entry["poses"] = [flow_pose(selected_pose)]
    else:
        location_entry.setdefault("poses", [])
        location_entry["poses"].append(flow_pose(selected_pose))

    if args.note is not None:
        location_entry["note"] = args.note
    elif "note" not in location_entry:
        location_entry["note"] = ""

    if args.recorded_by:
        data["recorded_by"] = args.recorded_by
    data["recorded_at"] = now_string()
    save_record_file(args.record_file, data)

    print(f"Recorded location: {args.name}")
    print(f"Mode: {args.mode}")
    print(f"Selected pose: {selected_pose}")
    print(f"Position span during sampling: dx={dx:.4f} m, dy={dy:.4f} m")
    print(f"Saved to: {args.record_file}")
    return 0


def command_sync(args: argparse.Namespace) -> int:
    record_data = load_record_file(args.record_file)
    if not args.client_config.exists():
        raise SystemExit(f"Client config not found: {args.client_config}")

    with args.client_config.open("r", encoding="utf-8") as handle:
        client_data = json.load(handle)

    mapping = client_data.setdefault(args.mapping, {})
    updated_locations: list[str] = []

    for name, entry in record_data.get("locations", {}).items():
        poses = entry.get("poses", [])
        if not poses:
            continue
        mapping[name] = [validate_pose(pose) for pose in poses]
        updated_locations.append(name)

    if not updated_locations:
        print("No non-empty locations found in the record file. Nothing to sync.")
        return 0

    print(f"Target mapping: {args.mapping}")
    print("Locations to update:")
    for name in updated_locations:
        print(f"  - {name}")

    if args.dry_run:
        print("Dry-run only. client_config.json was not modified.")
        return 0

    if args.backup:
        backup = backup_json_file(args.client_config)
        print(f"Backup created: {backup}")

    with args.client_config.open("w", encoding="utf-8") as handle:
        json.dump(client_data, handle, ensure_ascii=False, indent=4)
        handle.write("\n")

    print(f"Synchronized to: {args.client_config}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Standalone waypoint operations for FAST-LIO + Unitree navigation."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    check = subparsers.add_parser("check", help="Check whether relocalization is valid")
    check.add_argument(
        "--get-pose-script",
        type=Path,
        default=DEFAULT_GET_POSE_SCRIPT,
        help="Path to get_pose.py",
    )
    check.add_argument(
        "--pose-command",
        default="",
        help="Override the pose sampling shell command",
    )
    check.add_argument("--samples", type=int, default=3, help="Number of pose samples")
    check.add_argument(
        "--interval", type=float, default=0.5, help="Seconds between pose samples"
    )
    check.add_argument(
        "--position-tolerance",
        type=float,
        default=0.15,
        help="Warning threshold for x/y span during sampling",
    )
    check.set_defaults(func=command_check)

    record = subparsers.add_parser("record", help="Record one waypoint into the YAML file")
    record.add_argument("--name", required=True, help="Location name")
    record.add_argument(
        "--mode",
        choices=("overwrite", "append"),
        default="overwrite",
        help="overwrite replaces the location poses, append adds one more pose",
    )
    record.add_argument(
        "--record-file",
        type=Path,
        default=DEFAULT_RECORD_FILE,
        help="YAML file used to store recorded locations",
    )
    record.add_argument(
        "--get-pose-script",
        type=Path,
        default=DEFAULT_GET_POSE_SCRIPT,
        help="Path to get_pose.py",
    )
    record.add_argument(
        "--pose-command",
        default="",
        help="Override the pose sampling shell command",
    )
    record.add_argument("--samples", type=int, default=3, help="Number of pose samples")
    record.add_argument(
        "--interval", type=float, default=0.5, help="Seconds between pose samples"
    )
    record.add_argument("--note", default=None, help="Optional location note")
    record.add_argument("--recorded-by", default="", help="Recorder name")
    record.set_defaults(func=command_record)

    sync = subparsers.add_parser("sync", help="Sync the YAML file into client_config.json")
    sync.add_argument(
        "--record-file",
        type=Path,
        default=DEFAULT_RECORD_FILE,
        help="YAML file used to store recorded locations",
    )
    sync.add_argument(
        "--client-config",
        type=Path,
        default=DEFAULT_CLIENT_CONFIG,
        help="Target client_config.json",
    )
    sync.add_argument(
        "--mapping",
        default="location_poses_mapping",
        help="Target mapping key in client_config.json",
    )
    sync.add_argument(
        "--dry-run",
        action="store_true",
        help="Only show the locations that would be updated",
    )
    sync.add_argument(
        "--no-backup",
        action="store_false",
        dest="backup",
        help="Skip the automatic JSON backup",
    )
    sync.set_defaults(func=command_sync, backup=True)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
