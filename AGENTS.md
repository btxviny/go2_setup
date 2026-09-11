# AGENTS.md — Go2 EDU Project Context

Context for future OpenCode sessions working on this Go2 EDU robot setup. Read this before doing any networking, SSH, ROS2/DDS, or sensor-visualization work in this repo.

---

## Hardware/network topology

```
Workstation PC (this machine, "viny-GP72-6QF")
   Ethernet iface: enp3s0
   Static IP:      192.168.123.222/24   (persistent NetworkManager profile "go2-eth")
        |
        | RJ45 cable → dock's user-expansion Ethernet port
        v
Go2 expansion dock            192.168.123.18   (Jetson/Tegra arm64, Ubuntu 20.04 focal)
Go2 robot main computer       192.168.123.161  (do NOT assign this IP to anything else)
```

- Subnet: `192.168.123.0/24` for everything Go2-related.
- Never assign `192.168.123.161` to the PC or dock — it's the robot's own address.
- PC's static IP is configured persistently via `nmcli` (connection profile `go2-eth`, bound to `enp3s0`), not a transient `ip addr add` — survives reboot.

### Dock is now also reachable over WiFi (out-of-band, alongside the Ethernet link)

A USB WiFi adapter (TP-Link TL-WN823N, `RTL8192EU` chipset, shows up as `wlan0`
— driver already present out of the box, no extra install needed) was added
to the dock. It's joined to the **same WiFi network this workstation PC is
on** (`Cudy-17B9`), via a persistent `nmcli` connection profile (`autoconnect:
yes` — survives reboot as long as the network is in range).

This is in **addition to**, not instead of, the Ethernet link — `eth0`
(192.168.123.18, the Go2 subnet) is untouched. The dock is now dual-homed:
Ethernet for the robot/DDS traffic, WiFi for out-of-band PC access + internet
(no more needing to USB-tether a phone for connectivity).

```bash
ssh -i ~/.ssh/id_ed25519 unitree@ubuntu.local   # mDNS -- robust to DHCP changes, use this day-to-day
ssh -i ~/.ssh/id_ed25519 unitree@192.168.123.18 "ip -br addr show wlan0"   # or check the IP directly, via the Ethernet link
```
WiFi is on the `192.168.10.0/24` subnet (`Cudy-17B9`); IP was
`192.168.10.89/24` when set up — DHCP-assigned, so it can change; don't
hardcode it anywhere without re-checking (use `ubuntu.local` instead).
Full setup/troubleshooting walkthrough: README.md Section 5.

**`unitree`'s sudo password is the same as their SSH password (`123`)** —
needed for anything network-config related (`nmcli device wifi connect`,
etc.), since the account has no passwordless sudo.

## Credentials

| Target | User | Password |
|---|---|---|
| Go2 expansion dock (`192.168.123.18`), SSH + sudo | `unitree` | `123` |

## Critical gotcha: UFW silently drops DDS traffic

If `ros2 topic list` / DDS shows nothing even though `ping` and `tcpdump` look fine, **check UFW first**:

```bash
sudo ufw status verbose
sudo ufw allow in on enp3s0   # if active with default-deny INPUT
sudo ufw reload
```

`tcpdump` sees packets at the NIC level (before netfilter); a UFW default-deny policy blocks them before they ever reach a UDP socket, with **no error anywhere**. Full root-cause writeup: `dds_zeros_ufw_fix.md`.

## Dock environment

SSH in with `ssh unitree@192.168.123.18` (password `123`). Every new shell prompts:

```
ros:foxy(1) noetic(2) ?
```

Type `1` for ROS2 Foxy (recommended — matches the dock's Cyclone DDS config and the `graph_pid_ws` workspace), `2` for ROS1 Noetic. This is a one-shot `.bashrc` menu, not persistent — re-prompts every new session.

Key facts:
- Only `foxy` (ROS2) and `noetic` (ROS1) exist — **not Humble**.
- Custom ROS2 workspace at `/unitree/module/graph_pid_ws/` (Hesai, Livox, SLAM, nav2, custom Unitree control packages).
- **RealSense D435i**: the dock's native OS only ever had a ROS1/noetic driver (`ros-noetic-realsense2-camera` 2.3.2, `librealsense2` 2.50.0) — no ROS2/Foxy RealSense package exists, since Intel doesn't publish arm64 apt packages. **Resolved**: now runs as ROS2 Humble inside the `go2-realsense-humble` Docker container instead — see "RealSense on ROS2 Humble (resolved)" below.
- **Hesai LiDAR**: ROS2-native driver also built for Foxy (`hesai_lidar_node` under `graph_pid_ws`), not launched by default on the dock's native OS. Also now rebuilt into the same Docker container above (same confirmed topic/output), launched via `docker compose` — see the same section below.
- **Unitree built-in L1 LiDAR**: always-on, publishes standard `sensor_msgs/msg/PointCloud2` on `/utlidar/cloud` (~15 Hz, `frame_id: utlidar_lidar`) and `/utlidar/cloud_deskewed` — no custom message packages needed, works out of the box.

## Workstation PC ROS2 setup (current state)

Already installed:
- `ros-humble-desktop` (full, incl. `rviz2`, `sensor_msgs`, etc.)
- `ros-humble-rmw-cyclonedds-cpp`
- `ros-humble-domain-bridge`

### Quick/direct DDS access (works today, no extra config files needed)

```bash
source /opt/ros/humble/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_DOMAIN_ID=0
unset CYCLONEDDS_URI     # must unset if it points to a nonexistent file — see gotchas below
ros2 topic list
```

Run these one-per-line or joined with `;` — **never with commas** (bash treats a comma-joined line as one malformed command and silently skips everything after the first token).

### Isolated (domain 0 → 42) method via `domain_bridge`

Recommended for regular/permanent use so the PC's own ROS2 tools (RViz, rqt, shell experiments) don't pollute the robot's DDS domain 0 discovery. This is what `tools/launch_all_sensors_docker.sh` automates — see README.md Section 9 for the full walkthrough, and `tools/bridge_docker.yaml` / `tools/cyclone_domain0_enp3s0.xml` / `tools/cyclone_domain42_lo.xml` for the actual config.

### Common shell pitfalls hit in this project (don't repeat)

- `ROS_DOMAIN_ID is not an integral number` → an `export` never actually ran (usually the comma-joined-command mistake above). Verify with `echo $ROS_DOMAIN_ID`.
- `rmw_create_node: failed to create domain` → `CYCLONEDDS_URI` points at a Cyclone XML file that doesn't exist on this machine. `unset CYCLONEDDS_URI` or point it at a real file.
- Running `rviz` (ROS1, if present) instead of `rviz2` (ROS2) — always use `rviz2` for this project.
- `sudo apt-get install` failing with `Could not get lock /var/lib/dpkg/lock-frontend... held by unattended-upgr` → the automatic `apt.systemd.daily` upgrade is legitimately running (check `ps -p <pid>`); wait for it to finish naturally rather than killing it, especially if it's mid-upgrade of `dpkg`/`apt`/`libc-bin` themselves.

## Repo layout (`~/go2_guide_docs/`)

```
README.md                                — main setup guide, current (Docker/Humble) approach
AGENTS.md                                — this file
previous_approaches_and_build_history.md — deprecated ROS1/ros1_bridge approach + full go2-realsense-humble build debugging history
realsense_depth_stream_fix.md            — root-cause writeup for the OLD ROS1 driver's depth-stream USB failure (historical)
go2_realsense_hesai_setup.pdf            — external reference doc
realsense_humble_docker/                 — local mirror of ~/realsense_humble_docker/ on the dock, for version control (image must still be built ON the dock, arm64)
  Dockerfile, docker-compose.yml, start.sh, record_sensors_bag.sh, hesai_lidar_src/
tools/
  dds_probe.c / dds_probe             — standalone DDS participant/topic enumerator (no SDK dependency)
  raw_mcast_rx.c / raw_mcast_rx       — bare UDP multicast receiver (bypasses DDS entirely, for diagnosing netfilter issues)
  probe_cyclonedds.xml                — Cyclone config for the probes above (domain-any, binds to Ethernet iface)
  probe_cyclonedds_trace.xml          — same + discovery tracing enabled
  go2_network_setup.sh                — scripted PC static-IP setup (nmcli persistent), ping check, UFW check/fix
  cyclone_domain0_enp3s0.xml          — isolated-bridge Cyclone config, dock-facing side, --ethernet default (domain 0 on enp3s0); --wifi/-i generate an equivalent temp config at runtime instead
  cyclone_domain42_lo.xml             — isolated-bridge Cyclone config, RViz-facing side (domain 42 on loopback -- always, regardless of --ethernet/--wifi)
  launch_all_sensors_docker.sh        — docker compose up -d on the dock (go2-realsense-humble, RealSense + Hesai as native ROS2 Humble, domain 0), domain_bridge (0 -> 42) + RViz2. --ethernet (default) or --wifi. L1 LiDAR deliberately not bridged (RealSense + Hesai only).
  bridge_docker.yaml                  — domain_bridge whitelist for launch_all_sensors_docker.sh (RealSense color/depth/camera_info incl. compressed color + /rslidar_points; everything lives on domain 0 via the container's host networking)
  go2_sensors_docker.rviz             — RViz2 layout for launch_all_sensors_docker.sh (Fixed Frame: rslidar; topic names match the container's doubled-namespace RealSense topics: /camera/camera/color/image_raw, /camera/camera/depth/image_rect_raw)
```

Note: the OLD ROS1/`ros1_bridge` approach's files (`tools/launch_all_sensors.sh`, `bridge.yaml`, `go2_sensors.rviz`) were deleted as unused — see `previous_approaches_and_build_history.md` Part 1 for what they did.

## RealSense on ROS2 Humble (resolved)

Decision: built `realsense-ros` + `librealsense2` from source inside a Docker container, rather than natively on the dock (which only has Foxy/Noetic) or via `ros1_bridge`.

- Image: `go2-realsense-humble`, base `dustynv/ros:humble-desktop-l4t-r35.3.1`, built in `~/realsense_humble_docker/Dockerfile` on the dock.
- `librealsense2` v2.58.4 built from source (`-DFORCE_RSUSB_BACKEND=true -DBUILD_WITH_CUDA=false`) — must be ≥2.58.0 to satisfy `realsense-ros`'s `ros2-master` branch version check.
- `realsense-ros` (`ros2-master` branch), plus two extra from-source deps genuinely missing from this minimal-desktop base image: `diagnostic_updater` (`ros/diagnostics`, `ros2-humble` branch) and `xacro` (`ros/xacro`, `ros2` branch).
- Key gotcha: this base image is Ubuntu 20.04 (focal), but official ROS2 Humble binaries only target 22.04 (jammy) — so **no `ros-humble-*` apt package exists for focal at all**, regardless of the (also expired) ROS apt signing key. The Dockerfile deletes the `packages.ros.org` apt source entirely rather than fixing/re-adding it, and treats `rosdep install` failures as non-fatal, relying on `colcon build` to surface genuinely missing dependencies.
- Another gotcha: this base image's ROS underlay is at `/opt/ros/humble/install/setup.bash`, not `/opt/ros/humble/setup.bash` — sourcing the wrong path fails silently if chained after `rosdep init || true` (operator precedence swallows the error), leaving `colcon build` running with no ROS environment and confusing "package not found" CMake errors.
- The Hesai driver (`hesai_lidar`) was later added to the same image, rebuilt from its vendored source (`realsense_humble_docker/hesai_lidar_src/`, not a git repo upstream) against Humble — required patching several undeclared dependencies (`tf2_ros`, `image_transport`, `pcl_conversions`, `rclcpp_components`) plus a missing `#include <tf2_ros/buffer.h>`. Confirmed topic: `/rslidar_points` (`sensor_msgs/msg/PointCloud2`, `frame_id: rslidar`, `publish_type:=both`) — same as the old native Foxy driver, so no config changes were needed elsewhere. Full chronological build log: `previous_approaches_and_build_history.md` Part 2.
- `tools/launch_all_sensors_docker.sh` + `tools/bridge_docker.yaml` + `tools/go2_sensors_docker.rviz` (the isolated-bridge config for this approach) are done and confirmed working end-to-end.

## Outstanding / next steps

1. **RealSense depth-stream USB hardware error** — intermittent
   `control_transfer returned error ... Resource temporarily unavailable` +
   `Depth stream start failure, Hardware Error` right after the node comes
   up. Likely `FORCE_RSUSB_BACKEND=true` + an underpowered USB hub/marginal
   cable. Not yet root-caused.
2. **`ros-humble-image-transport-plugins` now installed** on the workstation
   PC (resolved) — RViz's `RealSenseColor` display was switched to subscribe
   via compressed transport (`/camera/camera/color/image_raw/compressed`,
   now also bridged in `tools/bridge_docker.yaml`) because raw uncompressed
   720p over the bridged link made the display appear stuck on the first
   frame, even though `ros2 topic hz` confirmed data kept flowing fine at
   the DDS level the whole time — an RViz-side rendering bottleneck, not a
   bridging bug. Depth is still raw (untouched, no reported issue there).
3. **`/rslidar_points` "not arriving" — resolved, was never actually a data
   problem.** `ros2 topic hz` on domain 42 confirmed data was flowing the
   whole time (~9-10 Hz); the real issue was `go2_sensors_docker.rviz`'s
   `Hide Left Dock: true` hiding the Displays panel entirely, so there was no
   way to see its (harmless) status. Fixed by setting `Hide Left Dock: false`.
4. Re-run `go2_network_setup.sh` on any new workstation PC to replicate the
   static-IP + ping + UFW check quickly.
5. **Repo cleanup: deprecated Part 1 files deleted.** `tools/launch_all_sensors.sh`,
   `bridge.yaml`, `go2_sensors.rviz` removed — see `previous_approaches_and_build_history.md`
   Part 1 for what they did; the knowledge is preserved there in writing.
6. **`--ethernet`/`--wifi` flags added to `launch_all_sensors_docker.sh`.**
   `--wifi` resolves the dock via mDNS (`unitree@ubuntu.local`) since its
   WiFi IP is DHCP-assigned and changes between sessions; auto-detects this
   PC's active WiFi interface too. Fixed a real pre-existing bug found along
   the way: `tools/cyclone_domain42_lo.xml` (meant to isolate domain 42 to
   loopback, used only locally between `domain_bridge` and `rviz2`) was
   actually bound to `enp3s0` — harmless in practice (same-host traffic works
   regardless of bound interface) but wrong; fixed to bind to `lo`.
7. **`--wifi` mode's live RViz data doesn't work on the current WiFi network**
   (SSH/`docker compose`/recording all work fine over it though) — confirmed
   via `tools/dds_probe` that DDS multicast discovery doesn't reach across
   this WiFi network at all (0 participants found over WiFi vs. instant over
   Ethernet). Almost certainly the router's AP/client isolation setting,
   not a script bug. User is checking router admin settings rather than
   pursuing a unicast-peers CycloneDDS workaround (rejected as too fragile,
   given both the container's and PC's WiFi IPs are independently
   DHCP-assigned).
