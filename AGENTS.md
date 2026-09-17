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
Full setup/troubleshooting walkthrough: networking.md.

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
- **RealSense D435i**: the dock's native OS only ever had a ROS1/noetic driver (`ros-noetic-realsense2-camera` 2.3.2, `librealsense2` 2.50.0) — no ROS2/Foxy RealSense package exists, since Intel doesn't publish arm64 apt packages. **Resolved**: now runs as ROS2 Humble inside the `go2-sensors-humble` Docker container instead — see "RealSense on ROS2 Humble (resolved)" below.
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

### Isolated (domain 0 → 42) method — REMOVED, everything now runs on domain 0

`launch_all_sensors_docker.sh` used to relay RealSense/Hesai topics from the
robot's domain 0 onto an isolated domain 42 (via `domain_bridge`) so RViz2/PC
tooling wouldn't share a DDS domain with the robot's own traffic. This was
removed for simplicity: RViz2 now joins domain 0 directly (see
`tools/launch_all_sensors_docker.sh`), same as the "Quick/direct DDS access"
method above. `tools/bridge_docker.yaml` and `tools/cyclone_domain42_lo.xml`
are gone; `tools/cyclone_domain0_enp3s0.xml` was replaced by
`tools/cyclone_ethernet.xml` (single unscoped `<Domain id="0">` block, no
dual-domain scoping needed anymore).

### Common shell pitfalls hit in this project (don't repeat)

- `ROS_DOMAIN_ID is not an integral number` → an `export` never actually ran (usually the comma-joined-command mistake above). Verify with `echo $ROS_DOMAIN_ID`.
- `rmw_create_node: failed to create domain` → `CYCLONEDDS_URI` points at a Cyclone XML file that doesn't exist on this machine. `unset CYCLONEDDS_URI` or point it at a real file.
- Running `rviz` (ROS1, if present) instead of `rviz2` (ROS2) — always use `rviz2` for this project.
- `sudo apt-get install` failing with `Could not get lock /var/lib/dpkg/lock-frontend... held by unattended-upgr` → the automatic `apt.systemd.daily` upgrade is legitimately running (check `ps -p <pid>`); wait for it to finish naturally rather than killing it, especially if it's mid-upgrade of `dpkg`/`apt`/`libc-bin` themselves.
- **Topic shows up in `ros2 topic list`/`topic info` but `ros2 topic hz`/subscribers get zero messages, and UFW is inactive** → check `RMW_IMPLEMENTATION` is actually exported as `rmw_cyclonedds_cpp` in that shell. The container (and this repo's tooling) all use CycloneDDS; a bare terminal with `RMW_IMPLEMENTATION` unset falls back to the default `rmw_fastrtps_cpp`, which can discover a CycloneDDS publisher's topic (cross-vendor RTPS discovery mostly works) but frequently fails to actually receive its data. Confirmed live (Sept 16): identical `ros2 topic hz /rslidar_points` got 0 messages with `RMW_IMPLEMENTATION` unset, ~7 Hz with it set to `rmw_cyclonedds_cpp` (plus `CYCLONEDDS_URI=file://tools/cyclone_ethernet.xml` and `ROS_DOMAIN_ID=0`) — same machine, same network link, only the RMW differed. Always source the same three env vars `launch_all_sensors_docker.sh` uses before running any manual `ros2` CLI command against this setup.

## Repo layout (`~/go2_guide_docs/`)

```
README.md                                — high-level setup guide, current (Docker/Humble) approach
networking.md                            — detailed connectivity: topology, credentials, Ethernet + WiFi setup, troubleshooting
AGENTS.md                                — this file
previous_approaches_and_build_history.md — deprecated ROS1/ros1_bridge approach + full go2-sensors-humble build debugging history
realsense_depth_stream_fix.md            — root-cause writeup for the OLD ROS1 driver's depth-stream USB failure (historical)
wifi_dds_data_loss_findings.md           — experimental findings on --wifi mode's DDS data loss (item 7 below); what was tried, what's ruled out, what's still open
go2_realsense_hesai_setup.pdf            — external reference doc
go2_sensors_docker/                      — local mirror of ~/go2_sensors_docker/ on the dock, for version control (image must still be built ON the dock, arm64)
  Dockerfile, docker-compose.yml, start.sh, record_sensors_bag.sh, hesai_lidar_src/
  config/cyclonedds_ethernet.xml   — container-side CycloneDDS config (default CYCLONEDDS_URI), caps MaxMessageSize/FragmentSize under the Ethernet MTU (see item 11)
tools/
  go2_network_setup.sh                — scripted PC static-IP setup (nmcli persistent), ping check, UFW check/fix
  cyclone_ethernet.xml                — CycloneDDS config for RViz2/ros2 CLI on domain 0 over the default Ethernet interface (enp3s0), incl. a MinimumSocketReceiveBufferSize=10MB tuning; --wifi/-i generate an equivalent temp config with a unicast discovery peer (see item 7)
  ros2_env.sh                         — source (not run) to set RMW_IMPLEMENTATION/ROS_DOMAIN_ID/CYCLONEDDS_URI for manual ros2 CLI commands, wraps the exports so they don't need retyping every terminal (--ethernet only; --wifi still needs the printed temp config path)
  launch_all_sensors_docker.sh        — docker compose up -d on the dock (go2-sensors-humble, RealSense + Hesai as native ROS2 Humble, domain 0) + RViz2 directly on domain 0 (no bridge). --ethernet (default) or --wifi. L1 LiDAR deliberately not otherwise touched (RealSense + Hesai only).
  go2_sensors_docker.rviz             — RViz2 layout for launch_all_sensors_docker.sh (Fixed Frame: rslidar; topic names match the container's doubled-namespace RealSense topics: /camera/camera/color/image_raw, /camera/camera/depth/image_rect_raw)
```

Note: the OLD ROS1/`ros1_bridge` approach's files (`tools/launch_all_sensors.sh`, `bridge.yaml`, `go2_sensors.rviz`) were deleted as unused — see `previous_approaches_and_build_history.md` Part 1 for what they did.

## RealSense on ROS2 Humble (resolved)

Decision: built `realsense-ros` + `librealsense2` from source inside a Docker container, rather than natively on the dock (which only has Foxy/Noetic) or via `ros1_bridge`.

- Image: `go2-sensors-humble`, base `dustynv/ros:humble-desktop-l4t-r35.3.1`, built in `~/go2_sensors_docker/Dockerfile` on the dock.
- `librealsense2` v2.58.4 built from source (`-DFORCE_RSUSB_BACKEND=true -DBUILD_WITH_CUDA=false`) — must be ≥2.58.0 to satisfy `realsense-ros`'s `ros2-master` branch version check.
- `realsense-ros` (`ros2-master` branch), plus two extra from-source deps genuinely missing from this minimal-desktop base image: `diagnostic_updater` (`ros/diagnostics`, `ros2-humble` branch) and `xacro` (`ros/xacro`, `ros2` branch).
- Key gotcha: this base image is Ubuntu 20.04 (focal), but official ROS2 Humble binaries only target 22.04 (jammy) — so **no `ros-humble-*` apt package exists for focal at all**, regardless of the (also expired) ROS apt signing key. The Dockerfile deletes the `packages.ros.org` apt source entirely rather than fixing/re-adding it, and treats `rosdep install` failures as non-fatal, relying on `colcon build` to surface genuinely missing dependencies.
- Another gotcha: this base image's ROS underlay is at `/opt/ros/humble/install/setup.bash`, not `/opt/ros/humble/setup.bash` — sourcing the wrong path fails silently if chained after `rosdep init || true` (operator precedence swallows the error), leaving `colcon build` running with no ROS environment and confusing "package not found" CMake errors.
- The Hesai driver (`hesai_lidar`) was later added to the same image, rebuilt from its vendored source (`go2_sensors_docker/hesai_lidar_src/`, not a git repo upstream) against Humble — required patching several undeclared dependencies (`tf2_ros`, `image_transport`, `pcl_conversions`, `rclcpp_components`) plus a missing `#include <tf2_ros/buffer.h>`. Confirmed topic: `/rslidar_points` (`sensor_msgs/msg/PointCloud2`, `frame_id: rslidar`, `publish_type:=both`) — same as the old native Foxy driver, so no config changes were needed elsewhere. Full chronological build log: `previous_approaches_and_build_history.md` Part 2.
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
7. **`--wifi` mode's live RViz data doesn't work well on the current WiFi
   network** (SSH/`docker compose`/recording all work fine over it though).
   The unicast `<Peer>`/`<ParticipantIndex>` workaround already in
   `launch_all_sensors_docker.sh` does fix *discovery* (multicast SPDP is
   blocked on this WiFi, confirmed instant on Ethernet vs. 0 participants
   over WiFi without it) — but data flow is still bad even with discovery
   working: small messages (`camera_info`) get through at only a fraction of
   their real rate through the full bridge pipeline, and large messages
   (raw depth, `/rslidar_points`, compressed color) are ~100% lost.
   **`AllowMulticast=false` was tried live as a fix and is NOT the answer**
   — setting it on the container side broke the RealSense/Hesai processes'
   own intra-container discovery (they rely on the same local multicast).
   Testing also showed small messages actually work fine (~24 Hz) when
   subscribed to directly, bypassing `domain_bridge` entirely — meaning the
   remaining small-message bottleneck is more likely in the bridge chain
   itself (or was a transient measurement) than in raw multicast/link loss.
   Large-message loss reproduces even fully direct with best-effort QoS
   (ruling out `domain_bridge`/QoS-retry/discovery as the cause) and isn't
   explained by MTU (1500 both sides) or raw large-packet ping loss (0%
   at 200pps, 1400B, DF-set) — genuinely not yet root-caused. Full
   experimental writeup, what was tried, and what's still open:
   `wifi_dds_data_loss_findings.md`. No config changes were kept from this
   investigation — `launch_all_sensors_docker.sh` and the generated
   CycloneDDS configs are unchanged.

   **Update/correction (Sept 2026):** the "multicast SPDP is blocked on
   this WiFi" claim above was re-tested directly and found to be **wrong**
   — a live bidirectional multicast probe (real UDP packets sent/received
   on CycloneDDS's own SPDP group `239.255.0.1:7400` between the PC's and
   dock's WiFi interfaces) confirmed multicast works fine both ways on this
   network. The large-message throughput problem described above (raw
   depth, `/rslidar_points`, compressed color loss) is real and still
   unresolved, but it's not caused by blocked multicast/discovery — it's a
   WiFi link-level bandwidth/loss issue for large messages, separate from
   discovery entirely. Given this, the unicast `<Peer>`/`ParticipantIndex`
   workaround (and its per-run IP-resolution/generation) was removed:
   `--wifi` mode now uses two static, checked-in, plain-multicast configs
   (`tools/cyclone_wifi.xml`, `go2_sensors_docker/config/cyclonedds_wifi.xml`)
   with no per-run generation at all. Also found along the way: a single
   config listing *both* interfaces (`eth0`+`wlan0`) on the container side
   actively breaks data delivery (readers get zero messages, even though
   discovery still works) — so the two static configs stay genuinely
   separate rather than merged into one "works for everything" file. Also
   separately confirmed (same session): the LiDAR/RealSense
   "freezes-after-first-frame" symptom (both over Ethernet and WiFi) was
   root-caused as a `BEST_EFFORT` QoS + large-message-fragmentation-burst
   interaction, fixed by switching `HesaiRslidarCloud`'s RViz display QoS to
   `RELIABLE` — see `docs/networking.md`'s "Known issue" and "WiFi
   CycloneDDS config simplification" sections for the full writeup on both.
8. **RESOLVED (Sept 14): `launch_all_sensors_docker.sh`'s cleanup trap was
   deleting the permanent `tools/cyclone_domain0_enp3s0.xml` on every single
   run** (in `--ethernet` mode, `$DOMAIN0_CONFIG` pointed straight at that
   file rather than a temp copy, and cleanup unconditionally `rm -f`'d it).
   This is why the file kept mysteriously vanishing between sessions for
   days. Fixed by tracking whether the config is actually a generated temp
   file before deleting it.
9. **KISS-ICP LiDAR odometry added, then DISABLED (built but not launched).**
   `go2_sensors_docker/Dockerfile` clones `PRBonn/kiss-icp` v1.3.0 and
   builds its `ros/` wrapper (package `kiss_icp`, executable `kiss_icp_node`)
   via colcon, against the sibling `cpp/kiss_icp` core directly (a
   `COLCON_IGNORE` there stops colcon from also treating it as a separate
   plain-CMake package). `start.sh` has the launch invocation (against
   `/rslidar_points`, `base_frame` unset -> egocentric in the `rslidar`
   frame, `lidar_odom_frame:=odom_lidar`) commented out, along with its
   overlay `source` line. `tools/bridge_docker.yaml`'s `/kiss/odometry`,
   `/kiss/local_map`, `/kiss/frame`, `/kiss/keypoints`, `/tf` entries are
   likewise commented out. **Real risk, not yet verified either way:** the
   wrapper's CMake target requires `cxx_std_20`; this image's default
   compiler is GCC 9 (focal), with only partial C++20 support. If `docker
   build` fails on that step, install `gcc-10`/`g++-10` (in focal's default
   repos already, no PPA) and set `CC`/`CXX` for just that `RUN` line. Also
   needs the dock's WiFi internet uplink during the build (Sophus +
   tsl-robin-map aren't apt-packaged for focal, so CMake `FetchContent`s
   them). Full context in README.md's "LiDAR Odometry (KISS-ICP)" section.
10. **RESOLVED (Sept 14): domain_bridge's domain-42 side was silently
   broken entirely** — an unscoped `<Domain>` block in
   `cyclone_domain0_enp3s0.xml` applied to *both* domains domain_bridge
   opens (it's the only process here that opens two), forcing its domain-42
   participant to also bind `enp3s0` instead of `lo`, so it could never
   discover rviz2. Extensive live debugging (stray FastRTPS daemon on
   domain 0, thread-state inspection, minimal single-topic repro, plain
   pub/sub sanity check) before finding it. Fixed with explicit
   `<Domain id="0">`/`<Domain id="42">` scoping. Full writeup:
   `previous_approaches_and_build_history.md` item 22.
11. **RESOLVED (Sept 17): `/rslidar_points` (and raw RealSense images)
   discovered fine but delivered ~0 messages over Ethernet — root cause was
   CycloneDDS's own `MaxMessageSize` default (14720B, ~10x the real 1500B
   Ethernet MTU).** Any message needing more than one DDSI fragment batched
   up to that default gets sent as a single oversized UDP datagram that the
   kernel then IP-fragments to fit the wire — losing any one of the ~9-10
   resulting IP fragments loses the whole multi-MB sample. Confirmed via
   `/proc/net/snmp` showing a ~50% `ReasmFails` rate under load, and
   `tcpdump` showing genuine ~13-14KB UDP payloads (not a GRO artifact --
   reproduced identically with GRO forced off via `ethtool -K enp3s0 gro
   off`). Small messages (compressed color, small state topics) worked fine
   throughout, since they never need fragmentation in the first place --
   this is what made the symptom look LiDAR-specific at first, but raw
   RealSense color (2.7MB/frame) failed identically once tested, while
   depth raw (795KB/frame, fewer fragments) mostly got through. **Fix:**
   cap `MaxMessageSize` (1400B) and `FragmentSize` (1300B) safely under the
   MTU, on **both** the container/publisher side (new
   `go2_sensors_docker/config/cyclonedds_ethernet.xml`, now the default
   `CYCLONEDDS_URI` in `docker-compose.yml`; also added to the runtime
   `--wifi` container config in `launch_all_sensors_docker.sh`) and the PC
   /reader side (`tools/cyclone_ethernet.xml` and the script's generated
   `--wifi`/custom-`-i` temp config), forcing CycloneDDS to always emit
   single MTU-safe UDP datagrams and eliminating IP fragmentation entirely
   for this traffic. Verified: `/rslidar_points` went from 0 messages
   (indefinitely, discoverable but never received) to a solid ~10Hz, both
   via a raw `rclpy` subscriber and visually in RViz2. Also note along the
   way: `MinimumSocketReceiveBufferSize` and `Internal/FragmentSize` are
   both deprecated/moved element names in the CycloneDDS version installed
   here (0.10.5) -- current names are `Internal/SocketReceiveBufferSize`
   (with a `min` attribute) and `General/FragmentSize` respectively; Cyclone
   only warns (doesn't error) on the old names, so a config can silently not
   do what you think it does. Always check `docker logs`/stderr for `config:
   ... setting moved to ...` warnings after changing CycloneDDS XML.
