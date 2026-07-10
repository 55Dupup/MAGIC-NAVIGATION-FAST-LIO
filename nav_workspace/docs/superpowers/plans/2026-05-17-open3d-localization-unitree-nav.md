# Open3D Localization Unitree Nav Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a parallel Open3D-localization-based pipeline that records navigation points from `/localization_3d` and still runs Unitree's existing navigation client.

**Architecture:** Keep the current FAST-LIO + Unitree SLAM pipeline untouched. Add a new `open3d_pipeline_scripts` directory with standalone scripts and a new README. Open3D pose capture reads ROS2 `/localization_3d`, optionally applies an Open3D-to-Unitree planar transform, records points to a separate YAML, then syncs them into a selected Unitree navigation JSON.

**Tech Stack:** Bash, Python 3, ROS2 Foxy `rclpy`, `geometry_msgs/PoseStamped`, `std_msgs/Float32`, YAML via `ruamel.yaml`, existing Unitree `client_recon_v1.py` wrapper behavior.

---

### Task 1: Create Open3D Pose Operations Tool

**Files:**
- Create: `/home/unitree/go2-fast-lio/nav_workspace/open3d_pipeline_scripts/open3d_pose_ops.py`

- [ ] **Step 1: Implement pose sampling from `/localization_3d`**

Create a Python CLI with subcommands `check`, `record`, `compare`, and `sync`. It must read `geometry_msgs/msg/PoseStamped` from `/localization_3d`, read optional confidence from `/localization_3d_confidence`, print 7-value poses, and write YAML records.

- [ ] **Step 2: Implement optional transform application**

Support a transform file with `translation: [dx, dy, dz]` and `yaw_offset_rad`. If present, convert Open3D pose into Unitree target pose before writing YAML.

- [ ] **Step 3: Implement comparison**

Compare one Open3D pose command with one Unitree pose command. Print positional delta and yaw delta. Optionally save a planar transform.

### Task 2: Add Open3D Pipeline Shell Scripts

**Files:**
- Create: `/home/unitree/go2-fast-lio/nav_workspace/open3d_pipeline_scripts/open3d_step1_start_fastlio_open3d_loc.sh`
- Create: `/home/unitree/go2-fast-lio/nav_workspace/open3d_pipeline_scripts/open3d_step2_check_localization.sh`
- Create: `/home/unitree/go2-fast-lio/nav_workspace/open3d_pipeline_scripts/open3d_step2b_compare_pose_frame.sh`
- Create: `/home/unitree/go2-fast-lio/nav_workspace/open3d_pipeline_scripts/open3d_step3_record_nav_point.sh`
- Create: `/home/unitree/go2-fast-lio/nav_workspace/open3d_pipeline_scripts/open3d_step4_sync_nav_points.sh`
- Create: `/home/unitree/go2-fast-lio/nav_workspace/open3d_pipeline_scripts/open3d_step5_run_unitree_nav.sh`

- [ ] **Step 1: Start FAST-LIO and Open3D localization**

Create a Docker-host script that starts tmux sessions inside `unitree_humble_nav` for FAST-LIO and Open3D localization. It accepts `--map`, `--container`, `--dry-run`, and optional `--initialpose`.

- [ ] **Step 2: Wrap pose operations**

Make step2, step2b, step3, and step4 call `open3d_pose_ops.py` with clear defaults.

- [ ] **Step 3: Reuse Unitree navigation runner**

Make step5 call existing `/home/unitree/go2-fast-lio/nav_workspace/step_scripts/step5_run_nav_client.sh`, preserving `--config`.

### Task 3: Add Documentation and Verify

**Files:**
- Create: `/home/unitree/go2-fast-lio/nav_workspace/README_open3d_localization_unitree_nav.md`

- [ ] **Step 1: Document execution environments**

Specify which commands run on Jetson host, which commands start Docker processes, and how to avoid mixing this pipeline with the existing Unitree-relocation pipeline.

- [ ] **Step 2: Document coordinate validation**

Make it explicit that Open3D pose is not assumed equivalent to Unitree pose until `open3d_step2b_compare_pose_frame.sh` validates or saves a transform.

- [ ] **Step 3: Verify**

Run `bash -n` for all scripts, compile Python files, run dry-run checks, run mock pose recording/sync with temp files, and clean temp files.
