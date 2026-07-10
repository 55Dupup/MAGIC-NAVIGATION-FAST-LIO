#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


ACTIVE_CONFIG = Path("/unitree/module/unitree_slam/config/pl_relocation/mid360.yaml")
SLAM_DIR = "/unitree/module/unitree_slam/bin"
KEYDEMO_CHANGEMAP = "/unitree/module/unitree_slam/example/build/keyDemo_changemap"
POSE_CHECK = Path("/home/unitree/go2-fast-lio/nav_workspace/step_scripts/step2_check_relocalization.sh")


@dataclass(frozen=True)
class Variant:
    name: str
    values: dict[str, str]


VARIANTS = [
    Variant(
        "original_sanitized",
        {
            "filter_num": "35",
            "scan_resolution": "0.3",
            "map_resolution": "0.3",
            "icp_score": "0.03",
            "dist_sq_threshold": "0.1",
            "ground_ang": "60.0",
        },
    ),
    Variant(
        "filter25",
        {
            "filter_num": "25",
            "scan_resolution": "0.3",
            "map_resolution": "0.3",
            "icp_score": "0.03",
            "dist_sq_threshold": "0.1",
            "ground_ang": "60.0",
        },
    ),
    Variant(
        "filter15",
        {
            "filter_num": "15",
            "scan_resolution": "0.3",
            "map_resolution": "0.3",
            "icp_score": "0.03",
            "dist_sq_threshold": "0.1",
            "ground_ang": "60.0",
        },
    ),
    Variant(
        "filter35_res05",
        {
            "filter_num": "35",
            "scan_resolution": "0.5",
            "map_resolution": "0.5",
            "icp_score": "0.03",
            "dist_sq_threshold": "0.1",
            "ground_ang": "60.0",
        },
    ),
    Variant(
        "filter25_res05",
        {
            "filter_num": "25",
            "scan_resolution": "0.5",
            "map_resolution": "0.5",
            "icp_score": "0.03",
            "dist_sq_threshold": "0.1",
            "ground_ang": "60.0",
        },
    ),
    Variant(
        "filter15_res05",
        {
            "filter_num": "15",
            "scan_resolution": "0.5",
            "map_resolution": "0.5",
            "icp_score": "0.03",
            "dist_sq_threshold": "0.1",
            "ground_ang": "60.0",
        },
    ),
    Variant(
        "filter15_res05_ground75",
        {
            "filter_num": "15",
            "scan_resolution": "0.5",
            "map_resolution": "0.5",
            "icp_score": "0.03",
            "dist_sq_threshold": "0.1",
            "ground_ang": "75.0",
        },
    ),
]


def run(command: list[str], timeout: int | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(command, text=True, capture_output=True, timeout=timeout)


def run_shell(command: str, timeout: int | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        command,
        shell=True,
        executable="/bin/bash",
        text=True,
        capture_output=True,
        timeout=timeout,
    )


def replace_go2_values(config_text: str, values: dict[str, str]) -> str:
    if not values:
        return config_text

    match = re.search(r"(?ms)^Go2:\n.*?(?=^Go2_W:|\Z)", config_text)
    if not match:
        raise RuntimeError("Cannot find Go2 block in relocation config")

    block = match.group(0)
    updated = block
    for key, value in values.items():
        pattern = rf"(?m)^(\s*{re.escape(key)}:\s*).*$"
        updated, count = re.subn(pattern, rf"\g<1>{value}", updated, count=1)
        if count != 1:
            raise RuntimeError(f"Cannot update key in Go2 block: {key}")

    return config_text[: match.start()] + updated + config_text[match.end() :]


def write_variant_config(original_text: str, variant: Variant) -> None:
    ACTIVE_CONFIG.write_text(
        replace_go2_values(original_text, variant.values),
        encoding="utf-8",
    )


def tmux(command: str) -> subprocess.CompletedProcess:
    return run_shell(f"tmux {command}")


def start_slam_detached(map_path: str, startup_wait: int) -> None:
    for session in ("go2_slam", "go2_lidar", "go2_relocation"):
        tmux(f"kill-session -t {session} 2>/dev/null || true")

    tmux("new-session -d -s go2_slam")
    tmux('send-keys -t go2_slam "source /opt/ros/noetic/setup.bash" C-m')
    tmux('send-keys -t go2_slam "source ~/miniconda3/etc/profile.d/conda.sh" C-m')
    tmux('send-keys -t go2_slam "conda activate unitree_slam_lidar" C-m')
    tmux(
        'send-keys -t go2_slam '
        '"export LD_LIBRARY_PATH=\\$CONDA_PREFIX/lib:\\$LD_LIBRARY_PATH" C-m'
    )
    tmux(f'send-keys -t go2_slam "cd {SLAM_DIR} && ./unitree_slam" C-m')
    time.sleep(startup_wait)

    tmux("new-session -d -s go2_lidar")
    tmux('send-keys -t go2_lidar "source /opt/ros/noetic/setup.bash" C-m')
    tmux(
        'send-keys -t go2_lidar '
        f'"export LD_LIBRARY_PATH=/usr/local/lib:\\$LD_LIBRARY_PATH && cd {SLAM_DIR} && ./mid360_driver" C-m'
    )
    time.sleep(startup_wait)

    tmux("new-session -d -s go2_relocation")
    tmux('send-keys -t go2_relocation "source /opt/ros/noetic/setup.bash" C-m')
    tmux(
        'send-keys -t go2_relocation '
        f'"cd /unitree/module/unitree_slam/example/build && {KEYDEMO_CHANGEMAP} eth0 {map_path}" C-m'
    )
    time.sleep(3)


def wait_for_relocation_success(
    key_attempts: int,
    key_interval: int,
    restart_on_3104: bool,
) -> tuple[bool, str]:
    last_output = ""
    for _ in range(key_attempts):
        last_output = press_relocation_and_wait(key_interval)
        if "Successfully started relocation." in last_output:
            return True, last_output
        if restart_on_3104 and "statusCode:3104" in last_output:
            return False, last_output
    return False, last_output


def capture_relocation() -> str:
    result = tmux("capture-pane -t go2_relocation -p -S -200")
    return result.stdout


def press_relocation_and_wait(wait_seconds: int) -> str:
    tmux("send-keys -t go2_relocation a")
    time.sleep(wait_seconds)
    return capture_relocation()


def parse_relocation_output(text: str) -> tuple[str, str, str]:
    infos = re.findall(r'data:\s*(\{.*\})', text)
    status_codes = re.findall(r"statusCode:([0-9]+)", text)
    if not infos:
        return status_codes[-1] if status_codes else "", "", "no data json"

    raw = infos[-1]
    try:
        data = json.loads(raw)
        return (
            status_codes[-1] if status_codes else "",
            str(data.get("errorCode", "")),
            str(data.get("info", raw)),
        )
    except json.JSONDecodeError:
        return status_codes[-1] if status_codes else "", "", raw


def run_pose_check(samples: int, interval: float) -> tuple[bool, str, str, str]:
    result = run(
        [
            "bash",
            str(POSE_CHECK),
            "--samples",
            str(samples),
            "--interval",
            str(interval),
        ],
        timeout=max(20, samples * 8),
    )
    output = (result.stdout + result.stderr).strip()
    dx = ""
    dy = ""
    match = re.search(r"Position span: dx=([0-9.]+) m, dy=([0-9.]+) m", output)
    if match:
        dx, dy = match.groups()
    return result.returncode == 0, dx, dy, output


def write_report(rows: list[dict[str, str]], report_dir: Path) -> tuple[Path, Path]:
    report_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    csv_path = report_dir / f"relocation_sweep_{timestamp}.csv"
    md_path = report_dir / f"relocation_sweep_{timestamp}.md"

    fieldnames = [
        "variant",
        "status_code",
        "error_code",
        "info",
        "pose_ok",
        "dx",
        "dy",
        "elapsed_sec",
        "changed_values",
    ]
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    lines = [
        "# Relocation Parameter Sweep",
        "",
        "| variant | status | error | pose_ok | dx | dy | elapsed | info | changes |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for row in rows:
        lines.append(
            "| {variant} | {status_code} | {error_code} | {pose_ok} | {dx} | {dy} | {elapsed_sec} | {info} | {changed_values} |".format(
                **{k: str(v).replace("|", "/") for k, v in row.items()}
            )
        )
    md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return csv_path, md_path


def main() -> int:
    parser = argparse.ArgumentParser(description="Sweep Go2 relocation parameters at the current robot pose.")
    parser.add_argument(
        "--map",
        default="/home/unitree/go2-fast-lio/nav_workspace/maps/kitchen_pro.pcd",
    )
    parser.add_argument("--startup-wait", type=int, default=5)
    parser.add_argument("--relocation-key-interval", type=int, default=4)
    parser.add_argument("--relocation-key-attempts", type=int, default=4)
    parser.add_argument("--restarts", type=int, default=2)
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--interval", type=float, default=0.4)
    parser.add_argument(
        "--report-dir",
        type=Path,
        default=Path("/home/unitree/go2-fast-lio/nav_workspace/relocation_test_results"),
    )
    args = parser.parse_args()

    map_path = Path(args.map)
    if not map_path.exists():
        print(f"Map not found: {map_path}", file=sys.stderr)
        return 2

    original_text = ACTIVE_CONFIG.read_text(encoding="utf-8")
    backup_path = args.report_dir / "mid360.yaml.backup_before_last_sweep"
    args.report_dir.mkdir(parents=True, exist_ok=True)
    backup_path.write_text(original_text, encoding="utf-8")

    rows: list[dict[str, str]] = []
    try:
        for variant in VARIANTS:
            print(f"\n=== Testing {variant.name} ===", flush=True)
            write_variant_config(original_text, variant)
            start = time.time()
            status_code = ""
            error_code = ""
            info = ""
            pose_ok = False
            dx = ""
            dy = ""
            pose_output = ""

            for restart_idx in range(args.restarts):
                start_slam_detached(str(map_path), args.startup_wait)
                success, relocation_output = wait_for_relocation_success(
                    args.relocation_key_attempts,
                    args.relocation_key_interval,
                    restart_on_3104=True,
                )
                status_code, error_code, info = parse_relocation_output(relocation_output)
                if success:
                    pose_ok, dx, dy, pose_output = run_pose_check(args.samples, args.interval)
                    break

                print(
                    f"Restart {restart_idx + 1}/{args.restarts} did not reach successful relocation. "
                    f"statusCode={status_code}, info={info}",
                    flush=True,
                )

            elapsed = f"{time.time() - start:.1f}"
            row = {
                "variant": variant.name,
                "status_code": status_code,
                "error_code": error_code,
                "info": info,
                "pose_ok": str(pose_ok),
                "dx": dx,
                "dy": dy,
                "elapsed_sec": elapsed,
                "changed_values": json.dumps(variant.values, ensure_ascii=False),
            }
            rows.append(row)
            print(row, flush=True)
            if not pose_ok:
                print(pose_output, flush=True)
    finally:
        ACTIVE_CONFIG.write_text(original_text, encoding="utf-8")
        print(f"\nRestored original config: {ACTIVE_CONFIG}", flush=True)

    csv_path, md_path = write_report(rows, args.report_dir)
    print(f"CSV report: {csv_path}")
    print(f"Markdown report: {md_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
