# Go2 EDU — RealSense + Hesai on ROS2 Humble (Docker), Setup Guide

Consolidated reference for the Go2 EDU robot workstation setup: Ethernet
bring-up, SSH access to the expansion dock, and running RealSense D435i +
Hesai PandarXT-16 as native ROS2 Humble nodes inside a Docker container on
the dock, visualized in RViz2 on this PC.

**This is the current approach.** An earlier approach (native ROS1 RealSense
driver + `ros1_bridge`) was used before this and is fully superseded — see
[`previous_approaches_and_build_history.md`](previous_approaches_and_build_history.md)
if you need that history, or are debugging something that looks like one of
the many issues already hit and fixed while building the current setup.

> Official Unitree developer docs (SDK, API message definitions, service
> descriptions): https://support.unitree.com/home/en/developer

---

## Table of Contents

1. [Overview](#1-overview)
2. [Hardware & Network Topology](#2-hardware--network-topology)
3. [Credentials](#3-credentials)
4. [PC Network Setup](#4-pc-network-setup)
5. [Connecting to the Dock](#5-connecting-to-the-dock)
6. [The `go2-realsense-humble` Docker Image](#6-the-go2-realsense-humble-docker-image)
7. [Building the Image](#7-building-the-image)
8. [Running It](#8-running-it)
9. [One-Shot Script: Full Visualization in RViz2](#9-one-shot-script-full-visualization-in-rviz2)
10. [Recording a Rosbag](#10-recording-a-rosbag)
11. [Verifying Data on the PC Side](#11-verifying-data-on-the-pc-side)
12. [Known Issues / Next Steps](#12-known-issues--next-steps)
13. [Repo Layout](#13-repo-layout)
14. [References](#14-references)

---

## 1. Overview

The Go2 EDU exposes its internal state over **DDS** (ROS2 on the dock). The
dock's native OS only ships ROS2 Foxy and ROS1 Noetic — there's no ROS2
Humble, and no RealSense ROS2 apt package for this arm64/focal image at all
(official ROS2 Humble binaries only ever targeted Ubuntu 22.04/jammy).

The current setup solves this with a Docker container,
**`go2-realsense-humble`**, built from source on top of
`dustynv/ros:humble-desktop-l4t-r35.3.1`, that runs **both** the RealSense
D435i driver and the Hesai PandarXT-16 driver as native ROS2 Humble nodes —
no ROS1, no bridge process. The container uses `network_mode: host` and
`ROS_DOMAIN_ID=0`, so both sensors publish directly on the robot's own DDS
domain, exactly like the robot's built-in sensors do.

On the PC side, a `domain_bridge` pulls the relevant topics onto an isolated
ROS2 domain (42) for RViz2 visualization, keeping RViz/rqt/shell experiments
off the robot's own busy domain 0 discovery.

## 2. Hardware & Network Topology

```
Workstation PC ("viny-GP72-6QF")
   Ethernet iface: enp3s0 (or enp7s0 depending on machine)
   Static IP:      192.168.123.222/24
        |
        | RJ45 cable → dock's user-expansion Ethernet port
        v
Go2 expansion dock            192.168.123.18   (Jetson/Tegra arm64, Ubuntu 20.04 focal)
Go2 robot main computer       192.168.123.161  (do NOT assign this IP to anything else)
```

- Subnet: `192.168.123.0/24` for everything Go2-related.
- Never assign `192.168.123.161` to the PC or dock — it belongs to the robot.
- Persist the PC's static IP with `nmcli` (connection profile, bound to the
  Ethernet interface) rather than a transient `ip addr add`, so it survives
  reboot. `tools/go2_network_setup.sh` automates this (see Section 4).
- The dock is also **dual-homed onto WiFi**, in addition to (not instead of)
  the Ethernet link above — on the `192.168.10.0/24` subnet (the `Cudy-17B9`
  network this PC is also on; DHCP-assigned, last observed as
  `192.168.10.89` but don't hardcode it — see Section 5 for full setup,
  connection, and the mDNS-based lookup that's robust to it changing).

## 3. Credentials

| Target | User | Password |
|---|---|---|
| Go2 expansion dock (`192.168.123.18`), SSH + `sudo` | `unitree` | `123` |

SSH key auth is also set up (`~/.ssh/id_ed25519`, comment `go2-dock-access`)
and preferred over the password for anything scripted. `sudo` on the dock
uses the same password as SSH — needed for network config changes (e.g.
`nmcli device wifi connect`), since the account has no passwordless `sudo`.

## 4. PC Network Setup

Before anything else in this guide works, this PC needs an IP on the
`192.168.123.0/24` subnet — a fresh machine's Ethernet adapter has none by
default.

(PC)
```bash
cd ~/go2_guide_docs/tools
./go2_network_setup.sh
```

What it does, in order:

1. **Auto-detects the Ethernet interface** (first `en*` device that isn't
   `lo`), or pass one explicitly with `-i enp3s0`.
2. **Assigns `192.168.123.222/24`** to that interface as a **persistent
   NetworkManager connection profile** — not a transient `ip addr add` that
   disappears on reboot or replug. Refuses to let you set the PC's IP to
   `192.168.123.161` (the robot's own address).
3. **Pings the robot** (`192.168.123.161` by default) to confirm the link is
   up end-to-end.
4. **Checks UFW** and, if active with no rule for the interface, offers to
   fix it interactively — a default-DROP UFW policy silently drops all DDS
   traffic before it reaches a UDP socket (no error printed anywhere), so
   this is worth catching before assuming a sensor problem is upstream.

Useful flags:

| Flag | Meaning | Default |
|---|---|---|
| `-i IFACE` | Ethernet interface connected to the robot/dock | auto-detected |
| `-a PC_IP` | IP to assign to this PC on the 123 subnet | `192.168.123.222` |
| `-r ROBOT_IP` | Robot main-computer IP to ping-check against | `192.168.123.161` |
| `-t` | Temporary mode: `ip addr add` instead of a persistent profile | off |

## 5. Connecting to the Dock

There are two independent ways to reach the dock: **Ethernet** (the primary
link — required for the initial setup, and the only one that reliably
carries live sensor data to RViz2) and **WiFi** (optional, out-of-band —
great for SSH/file transfer/`docker` control without the cable, but *not*
for RViz visualization — see the caveat at the end of this section).

### Option A: Ethernet (primary)

Requires Section 4 (PC Network Setup) already done, and the RJ45 cable
plugged into the dock's user-expansion Ethernet port.

(PC)
```bash
ssh -i ~/.ssh/id_ed25519 unitree@192.168.123.18
```

On login, the dock's `.bashrc` prompts every session:

```
ros:foxy(1) noetic(2) ?
```

This is irrelevant to the Docker workflow in this guide (the container has
its own self-contained ROS2 Humble install) — answer either way, or just
`Ctrl+C` past it if running a one-off command.

Dock facts: Ubuntu 20.04.5 (focal), kernel `5.10.104-tegra`, arm64
(Jetson/Tegra), Docker 24.0.5, `docker compose` v2 plugin installed at
`~/.docker/cli-plugins/docker-compose`.

### Option B: WiFi (optional, out-of-band)

**What it's for:** SSH, `docker`/`docker compose` commands, `scp`, and
rosbag recording (Section 10) — all of these work identically over WiFi.
**What it's *not* reliably for:** live RViz2 visualization (Section 9) — see
the caveat at the end of this subsection before relying on it for that.

#### One-time setup (skip if already done on this dock)

1. **Plug a USB WiFi adapter into the dock.** Confirmed working out of the
   box, no driver install needed: TP-Link TL-WN823N (`RTL8192EU` chipset) —
   the kernel driver was already present and the adapter showed up as
   `wlan0` immediately. Verify, over the Ethernet link:
   (PC)
   ```bash
   ssh -i ~/.ssh/id_ed25519 unitree@192.168.123.18 'lsusb; nmcli device status'
   ```
   Look for the adapter in `lsusb` and a `wifi` row (`wlan0`) in
   `nmcli device status`. If it's missing, a different chipset may need a
   driver installed first — not covered here.

2. **Join the dock to the same WiFi network this PC is on.** You need that
   network's SSID and password. If this PC is already connected to it, you
   can read the password back out locally (only works for networks *this*
   PC has already joined and saved):
   (PC)
   ```bash
   nmcli device wifi show-password
   ```
   Then, on the dock (needs `sudo` — see Section 3 for the password):
   (dock)
   ```bash
   sudo nmcli device wifi connect '<SSID>' password '<password>' ifname wlan0
   ```

3. **Verify it connected and has internet/LAN access:**
   (dock)
   ```bash
   nmcli device status                 # wlan0 should show "connected"
   ip -br addr show wlan0              # note the assigned IP
   ping -c2 8.8.8.8                    # confirm it actually routes out
   ```

4. **Confirm it'll reconnect automatically after a reboot** (should be the
   default, but worth checking once):
   (dock)
   ```bash
   nmcli -f connection.autoconnect connection show '<SSID>'   # expect: yes
   ```

This is additive, not a replacement — `eth0` (`192.168.123.18`, the Go2
robot subnet) is completely untouched by any of this, so robot/DDS traffic
is unaffected either way. The dock ends up dual-homed: Ethernet for the
robot, WiFi for everything else.

#### Connecting, day to day

The WiFi IP is on the `192.168.10.0/24` subnet (`Cudy-17B9`), **DHCP-assigned
and can change** between sessions — last observed as `192.168.10.89`, but
don't hardcode it. Instead, use mDNS, which resolves automatically regardless
of the current IP (the dock's `avahi-daemon` broadcasts its hostname,
`ubuntu`, as `ubuntu.local`; nothing had to be configured for this — it
worked out of the box on both sides):

(PC)
```bash
ssh -i ~/.ssh/id_ed25519 unitree@ubuntu.local
```

If you ever need the actual current IP (e.g. for `nmap` or a router admin
page lookup), get it via the Ethernet link, or directly if you already know
a recent WiFi IP:

(PC)
```bash
ssh -i ~/.ssh/id_ed25519 unitree@192.168.123.18 "ip -br addr show wlan0"   # via Ethernet
ssh -i ~/.ssh/id_ed25519 unitree@192.168.10.89 "ip -br addr show wlan0"    # or directly, if still current
```

#### Troubleshooting

- **`ssh: connect to host ... port 22: Connection timed out`** — most often
  the Ethernet cable is unplugged (check with
  `ip -br link show enp3s0` — look for `NO-CARRIER`) if you're using the
  Ethernet address, or the dock/its WiFi adapter is off/disconnected if
  using WiFi. Occasionally just a transient hiccup — retry once before
  digging further.
- **`Host key verification failed`** — SSH found a *different* key already
  saved for that hostname/IP than what the dock is presenting now. This is
  expected the first time you connect to a new IP (e.g. right after the WiFi
  adapter gets a fresh DHCP lease), or if another device on the network
  previously used the same IP. Fix:
  ```bash
  ssh -o StrictHostKeyChecking=accept-new -i ~/.ssh/id_ed25519 unitree@<host>
  ```
- **`ubuntu.local` doesn't resolve** — confirm `avahi-daemon` is active on
  the dock (`ssh unitree@192.168.123.18 systemctl is-active avahi-daemon`,
  via Ethernet) and that this PC supports mDNS resolution
  (`getent hosts ubuntu.local` — Ubuntu has this built in via `nss-mdns` by
  default). Fall back to the Ethernet-based IP lookup above if it's broken.
- **Live RViz data doesn't arrive over WiFi, but SSH/`docker` work fine** —
  this is a known limitation, not a bug: ROS2/DDS discovery needs multicast,
  which many consumer WiFi routers block between wireless clients ("AP/client
  isolation"). See Section 9's WiFi caveat for the full explanation and what
  to check in your router's settings.

## 6. The `go2-realsense-humble` Docker Image

Base: `dustynv/ros:humble-desktop-l4t-r35.3.1` (ROS2 Humble built from
source, since Humble was never released for Ubuntu 20.04/focal). On top of
that, built from source in the image:

- **librealsense2 v2.58.4** (`-DFORCE_RSUSB_BACKEND=true
  -DBUILD_WITH_CUDA=false` — the Jetson kernel here lacks the UVC metadata
  patches needed for the native driver, so librealsense falls back to a
  userspace USB backend).
- **`realsense-ros`** (`ros2-master` branch) — needs librealsense ≥2.58.0,
  which is why that specific version is pinned above.
- **`diagnostic_updater`** (`ros/diagnostics`, `ros2-humble` branch) and
  **`xacro`** (`ros/xacro`, `ros2` branch) — both genuine `realsense-ros`
  dependencies missing from this minimal-desktop base image.
- **`hesai_lidar`** — the same Hesai PandarXT-16 driver already used
  natively on the dock's ROS2 Foxy install, rebuilt from vendored source
  (it isn't a git repo on the dock) against Humble. Needed several
  dependency fixes to build — see
  [`previous_approaches_and_build_history.md`](previous_approaches_and_build_history.md)
  Part 2 if you're debugging a similar build failure.

The image and its full build context (`Dockerfile`, `docker-compose.yml`,
`start.sh`, vendored `hesai_lidar_src/`) live on the dock at
`~/realsense_humble_docker/`, and are mirrored in this repo under
[`realsense_humble_docker/`](realsense_humble_docker/) for version control —
**that local copy is for reference/editing only; the image itself must be
built on the dock** (it's an arm64/Jetson-specific image; this PC can't
build or run it).

**Runtime topics** (confirmed via `docker exec go2-realsense-humble ros2 topic list -t`):

| Topic | Type | Notes |
|---|---|---|
| `/camera/camera/color/image_raw` | `sensor_msgs/msg/Image` | Doubled `camera/camera` namespace is `realsense-ros`'s default `camera_name = camera_namespace = "camera"` on this branch. |
| `/camera/camera/color/image_raw/compressed` | `sensor_msgs/msg/CompressedImage` | Used by RViz for live viewing (Section 9) and recorded by `record_sensors_bag.sh` (Section 10) instead of raw color — same ~30Hz rate, much smaller. |
| `/camera/camera/depth/image_rect_raw` | `sensor_msgs/msg/Image` | |
| `/camera/camera/color/camera_info`, `/camera/camera/depth/camera_info` | `sensor_msgs/msg/CameraInfo` | |
| `/rslidar_points` | `sensor_msgs/msg/PointCloud2` | Hesai, decoded cloud, `frame_id: rslidar` (`publish_type:=both`). |
| `/pandar_packets` | `hesai_lidar/msg/PandarScan` | Hesai, raw packets, custom message type — not bridged to the PC. |

## 7. Building the Image

Done on the dock (arm64). From a shell there:

(dock)
```bash
cd ~/realsense_humble_docker
docker build -t go2-realsense-humble .
```

Expect **30-90 minutes** the first time — the librealsense2 source compile
is the long pole on the dock's 4 cores. Subsequent builds reuse Docker's
layer cache and are much faster unless you change something early in the
`Dockerfile` (anything before the librealsense2 step forces a full
recompile).

If you change anything in `realsense_humble_docker/` in this repo, copy it
back to the dock before rebuilding (works over Ethernet or WiFi — plain file
transfer, no DDS involved):

(PC)
```bash
scp -i ~/.ssh/id_ed25519 -r realsense_humble_docker/* unitree@192.168.123.18:~/realsense_humble_docker/
# or, over WiFi:
scp -i ~/.ssh/id_ed25519 -r realsense_humble_docker/* unitree@ubuntu.local:~/realsense_humble_docker/
```

## 8. Running It

Manually, via `docker compose` on the dock:

(dock)
```bash
cd ~/realsense_humble_docker
docker compose up -d      # starts both drivers together, detached
docker logs -f go2-realsense-humble   # watch it come up
docker compose down       # stop and remove the container
```

`docker-compose.yml` sets `network_mode: host` (required for ROS2/DDS
discovery to reach the rest of the Go2 network), `privileged: true` +
`/dev:/dev` (USB access to the D435i), a `~/rosbags:/rosbags` mount (so
recordings — see Section 10 — persist on the dock's real filesystem, not
just inside the container), and `restart: unless-stopped`.
`start.sh` (mounted read-only into the container) sources the ROS2
underlay + `realsense_ws` overlay and launches both
`ros2 launch realsense2_camera rs_launch.py` and
`ros2 run hesai_lidar hesai_lidar_node --ros-args ...` together, backgrounded
with `wait -n` — if either driver dies, the whole container exits (and
restarts, per the restart policy).

To confirm both drivers are actually publishing:

(dock)
```bash
docker exec go2-realsense-humble bash -c \
  "source /opt/ros/humble/install/setup.bash && source /opt/realsense_ws/install/setup.bash && ros2 topic list"
```

## 9. One-Shot Script: Full Visualization in RViz2

**[`tools/launch_all_sensors_docker.sh`](tools/launch_all_sensors_docker.sh)**
does everything above plus brings the data into RViz2 on this PC, in one
command:

(PC)
```bash
cd ~/go2_guide_docs/tools
./launch_all_sensors_docker.sh              # Ethernet (default)
./launch_all_sensors_docker.sh --wifi       # WiFi
./launch_all_sensors_docker.sh --ethernet   # explicit, same as default
```

### Ethernet vs WiFi

The dock is dual-homed (see Section 2): `eth0` on the Go2 robot subnet
(`192.168.123.18`, needs the RJ45 cable), and `wlan0` on whatever WiFi
network this PC is also on. `--ethernet` (default) and `--wifi` pick which
link to SSH over — WiFi resolves the dock via mDNS as `unitree@ubuntu.local`
rather than a hardcoded IP, since the WiFi IP is DHCP-assigned and can
change. Each mode also auto-detects the right *local* network interface for
this PC's own `domain_bridge` to bind to (override either with `-i IFACE`).

**Known limitation: `--wifi` may not carry live RViz data, even though SSH
and `docker compose` control work fine over it.** ROS2/DDS discovery relies
on multicast by default, and consumer WiFi routers commonly block or don't
forward multicast between wireless clients ("AP/client isolation"). This was
confirmed on this project's own WiFi network using the repo's `tools/dds_probe`
diagnostic (0 external participants found over WiFi in 10s, vs. instant over
Ethernet) — check your router's wireless settings for an "AP Isolation" /
"Client Isolation" toggle if you hit this. `--ethernet` is unaffected and
always works. Recording (Section 10) and manual `docker`/`ssh` commands work
over either link regardless, since they don't depend on DDS discovery.

### What it does

```
DOCK                                          PC (this machine)
└── docker compose (go2-realsense-humble)     ├── domain_bridge
      ├── realsense2_camera  (ROS2/humble)     │   domain 0 -> 42 (lo)
      └── hesai_lidar_node   (ROS2/humble)     │   (RealSense + Hesai topics,
          network_mode: host, ROS_DOMAIN_ID=0  │    see bridge_docker.yaml)
                                                └── rviz2 (domain 42 only)
```

1. **`(re)starts the container`** on the dock (`docker compose down` then
   `up -d`, for a clean slate every run).
2. **Waits for both drivers to actually publish** (`/rslidar_points` and
   `/camera/camera/color/image_raw` both present), polling for up to 40s
   rather than a blind sleep.
3. **Starts a local `domain_bridge`** (domain 0 → 42), whitelisted via
   [`tools/bridge_docker.yaml`](tools/bridge_docker.yaml) — RealSense
   color (both raw and compressed) + depth + camera_info, and
   `/rslidar_points`. (The built-in L1 LiDAR is deliberately *not* bridged
   by this script — this setup only cares about RealSense + Hesai.)
4. **Launches RViz2** with
   [`tools/go2_sensors_docker.rviz`](tools/go2_sensors_docker.rviz) — Fixed
   Frame is set directly to `rslidar` (Hesai's own frame), so no static TF
   is needed.

Ctrl+C (or closing the RViz2 window) triggers cleanup: stops the
local `domain_bridge` and runs `docker compose down` on the dock.

### Prerequisites (one-time, not handled by the script)

1. SSH key-based auth to the dock (the script refuses to run without it):
   (PC)
   ```bash
   ssh-copy-id unitree@192.168.123.18
   # or, if only reachable over WiFi right now:
   ssh-copy-id unitree@ubuntu.local
   ```
2. The image already built on the dock — see Section 7.
3. **`ros-humble-image-transport-plugins`** installed on this PC — RViz2's
   Image display for RealSense color subscribes via compressed transport
   (`/camera/camera/color/image_raw/compressed`) rather than raw, since raw
   uncompressed 720p over the bridged link made the display appear stuck on
   the first frame (data kept flowing fine at the DDS level — confirmed via
   `ros2 topic hz` — RViz just couldn't keep up rendering it):
   (PC)
   ```bash
   sudo apt-get install -y ros-humble-image-transport-plugins
   ```
   Without this, RViz throws `image_transport::TransportLoadException`
   instead of showing the color stream.

## 10. Recording a Rosbag

**[`realsense_humble_docker/record_sensors_bag.sh`](realsense_humble_docker/record_sensors_bag.sh)**
records the three core sensor topics to a rosbag2 bag, saved on the **dock's**
own filesystem (not lost when the container restarts). Runs on the dock, not
the PC.

Topics recorded: `/camera/camera/color/image_raw/compressed`,
`/camera/camera/depth/image_rect_raw`, `/rslidar_points`.

**Color is recorded compressed** (JPEG via `image_transport`) — same ~30Hz
rate as raw, much smaller bag, no downside. **Depth is recorded raw,
deliberately** — its compressed transport (`compressedDepth`) was tried and
confirmed to make things *worse*, not better: subscribing to it drags the
**raw** depth topic down too, from its normal ~24-28Hz to the same **~0.7Hz**
as `compressedDepth` itself (PNG-encoding 16-bit depth data is apparently too
CPU-expensive on this hardware, and throttles the driver's whole depth
pipeline, not just the compressed subscriber). There's no way to get
full-rate raw depth *and* `compressedDepth` simultaneously on this hardware
— don't re-add `compressedDepth` without expecting that tradeoff.

### Why record from inside the container, not the dock's native ROS2?

The container's topics *are* visible to the dock's native ROS2 Foxy install
too, via `network_mode: host` — `ros2 topic list` from a native Foxy shell
sees them fine. But actually recording them from there doesn't work: it
**segfaults** (confirmed by testing — `ros2 bag record` from native Foxy
crashes with `Segmentation fault`, exit 139, as soon as messages start
arriving, even though the topics use standard `sensor_msgs` types). This is
a cross-ROS-distro incompatibility between Foxy (2020) and Humble's
type-support/introspection metadata, not something fixable by adjusting
topic names or QoS. Recording has to happen with the *matching* distro's
tooling — i.e. inside the container, via `docker exec`, which is what both
the script and the standalone commands below do.

### Using the script

(dock)
```bash
ssh -i ~/.ssh/id_ed25519 unitree@192.168.123.18
cd ~/realsense_humble_docker
./record_sensors_bag.sh                  # names the bag sensors_<UTC timestamp>
./record_sensors_bag.sh my_test_run       # or give it an explicit name
```
`Ctrl+C` stops the recording cleanly (rosbag2 finalizes the bag on `SIGINT` —
don't `kill -9` it, that can leave `metadata.yaml` missing/corrupt). The
script prints the resulting bag path on the dock and a ready-to-use `scp`
command to pull it back to this PC.

The bag is written via a bind mount added to `docker-compose.yml`
(`~/rosbags:/rosbags` on the dock ↔ `/rosbags` in the container), so it
survives `docker compose down`/`up` and container recreation. Since the
container runs as root, the script also `chown`s the finished bag back to
the `unitree` user (via `docker exec`, which doesn't need `sudo`) — without
this the bag would be root-owned and undeletable by the `unitree` user.

### Standalone commands (without the script)

(dock)
```bash
# Record (Ctrl+C to stop):
docker exec -it go2-realsense-humble bash -c \
  "source /opt/ros/humble/install/setup.bash && source /opt/realsense_ws/install/setup.bash && \
   ros2 bag record -o /rosbags/my_bag \
     /camera/camera/color/image_raw/compressed /camera/camera/depth/image_rect_raw /rslidar_points"

# Fix ownership so the unitree user can manage/delete it without sudo:
docker exec go2-realsense-humble chown -R $(id -u):$(id -g) /rosbags/my_bag
```

### Copying the bag back to the controller PC

Works equally well over Ethernet or WiFi — plain SCP/SSH file transfer
doesn't depend on DDS/multicast discovery the way live RViz visualization
does (see Section 9's WiFi caveat).

(PC)
```bash
# Over Ethernet:
scp -i ~/.ssh/id_ed25519 -r unitree@192.168.123.18:~/rosbags/my_bag .

# Over WiFi (mDNS -- robust to the dock's WiFi IP changing over DHCP):
scp -i ~/.ssh/id_ed25519 -r unitree@ubuntu.local:~/rosbags/my_bag .
```

Replace `my_bag` with whatever name you recorded under (default names are
timestamped, e.g. `sensors_20260911_142530`).

### Playing back a rosbag in RViz2

Unlike recording (which must happen inside the container — see above),
**playback runs entirely on this PC**, no dock or container involved at all:
the bag only contains standard `sensor_msgs` topics, which this PC's own
`ros-humble-desktop` install already has everything needed for.

**[`tools/play_and_visualize_bag.sh`](tools/play_and_visualize_bag.sh)**
does it all in one command:

(PC)
```bash
cd ~/go2_guide_docs/tools
./play_and_visualize_bag.sh /path/to/my_bag              # 0.5x speed (default)
./play_and_visualize_bag.sh /path/to/my_bag -r 1.0        # real-time
```

What it does:
- Plays the bag on an **isolated `ROS_DOMAIN_ID` (default `99`, override with
  `-d`)** — this matters, not just tidiness: if the `go2-realsense-humble`
  container happens to be running at the same time (it broadcasts on domain
  0 network-wide via `network_mode: host`), playing back on the default
  domain means RViz sees the **live** container's data *and* the bag
  player's data on the same topic names simultaneously — you'd end up
  watching a live feed instead of your recording, with no error or warning
  that it happened. `99` is just a convention — any domain ID not already
  used elsewhere in this project works (0 is the robot/live domain, 42 is
  the live-viewing bridge's domain — Section 9).
- **Plays at half speed by default** (`-r 0.5`, override with `-r`) — the
  lidar point cloud (tens of thousands of points/message) and raw depth are
  genuinely heavy for RViz to render; there's no cheap point-cloud
  downsampling tool installed on this PC (`ros-humble-pcl-ros` would add
  proper voxel-grid downsampling, but needs `sudo`, not installed), so
  slower-than-real-time playback is the practical way to ease the load
  instead. Use `-r 1.0` if your machine keeps up fine at full speed.
- Auto-launches RViz2 with
  [`tools/go2_sensors_playback.rviz`](tools/go2_sensors_playback.rviz).
- Cleans up both processes reliably on exit (Ctrl+C, or closing the RViz2
  window) — backgrounds both the player and RViz2 and waits on either one
  exiting, rather than blocking on RViz2 in the foreground, specifically
  because RViz2 has been observed to occasionally hang or crash on shutdown
  in testing; a foreground wait would leave the bag player orphaned in that
  case.

### Manually (without the script)

Same effect, two terminals, both on the PC — useful if you want a different
`ROS_DOMAIN_ID`/rate combination than the script's flags allow, or just to
see each piece separately:

(PC, terminal 1 — play the bag)
```bash
source /opt/ros/humble/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_DOMAIN_ID=99
ros2 bag play --rate 0.5 /path/to/my_bag     # add --loop to repeat continuously
```

(PC, terminal 2 — visualize it)
```bash
source /opt/ros/humble/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_DOMAIN_ID=99
rviz2 -d ~/go2_guide_docs/tools/go2_sensors_playback.rviz
```

Both terminals must use the **same** `ROS_DOMAIN_ID` as each other, or RViz
won't see the playback data either.

`go2_sensors_playback.rviz` is a **separate** config from
`go2_sensors_docker.rviz` (Section 9's live-viewing one) — both point
`RealSenseColor` at the compressed topic and `RealSenseDepth` at raw depth
(matching what's actually recorded), the real difference being which
`ROS_DOMAIN_ID` each is meant for (playback's isolated `99` vs. the live
bridge's `42`).

## 11. Verifying Data on the PC Side

While the script (or a manually-started `domain_bridge`) is running, open a
new terminal on this PC:

(PC)
```bash
source /opt/ros/humble/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_DOMAIN_ID=42
export CYCLONEDDS_URI="file://$(pwd)/tools/cyclone_domain42_lo.xml"

ros2 topic list
ros2 topic hz /camera/camera/color/image_raw
ros2 topic hz /rslidar_points
```

If a topic is missing or shows 0 Hz, check (in order):
1. Is the container actually up? `ssh unitree@192.168.123.18 docker ps`
2. Is there more than one `domain_bridge` running locally?
   `pgrep -af domain_bridge` — a leftover instance from an earlier session
   competing with the current one is a real failure mode that's been hit
   before (see `previous_approaches_and_build_history.md` Part 2, item 11).
3. `docker logs --tail 50 go2-realsense-humble` on the dock for driver-level
   errors.

## 12. Known Issues / Next Steps

- **RealSense depth-stream USB hardware error.** Sometimes, right after
  `"RealSense Node Is Up!"`, the log shows
  `control_transfer returned error ... Resource temporarily unavailable` and
  `Depth stream start failure, Hardware Error`. Likely tied to the
  `FORCE_RSUSB_BACKEND=true` build flag combined with an underpowered USB
  hub or marginal cable. Not yet root-caused.
- **Raw-image bandwidth over the bridged link can make RViz's Image displays
  appear stuck** (data keeps flowing at the DDS level — confirmed via
  `ros2 topic hz` — but the GUI doesn't render new frames). The color stream
  now uses compressed transport to work around this (see Section 9's
  prerequisites); if depth ever shows the same symptom, the same fix applies
  there too.
- **No shared TF between `rslidar` and the RealSense's own frame**
  (`camera_link`/`camera_color_optical_frame`) — each renders correctly only
  when its own frame is the RViz Fixed Frame. Not an issue for the current
  RViz config (Image displays don't need TF; only the Hesai PointCloud2 does,
  and Fixed Frame is already set to its frame).
- **`launch_all_sensors_docker.sh`'s Hesai launch params are hardcoded** to
  match the known-working native config (`server_ip:=192.168.123.20`,
  `lidar_type:=PandarXT-16`, etc., in `start.sh`) — update there if the
  sensor's network config ever changes.
- **`--wifi` mode's live RViz visualization doesn't work on this project's
  WiFi network** — SSH/`docker compose` control and rosbag recording work
  fine over WiFi, but DDS discovery (multicast) doesn't reach across it,
  confirmed with `tools/dds_probe`. Likely the router's AP/client isolation
  setting; see Section 9. Not something this script can fix in software.

## 13. Repo Layout

```
README.md                                — this file
AGENTS.md                                — agent/session context notes (network topology, credentials, gotchas)
previous_approaches_and_build_history.md — deprecated ROS1/ros1_bridge approach + full go2-realsense-humble build debugging history
realsense_depth_stream_fix.md            — root-cause writeup for the OLD ROS1 driver's depth-stream USB failure (historical)
go2_realsense_hesai_setup.pdf            — external reference doc
realsense_humble_docker/
  Dockerfile                             — builds go2-realsense-humble (mirrors ~/realsense_humble_docker/Dockerfile on the dock)
  docker-compose.yml                     — launches both drivers together (network_mode: host, privileged, /dev + ~/rosbags mounts)
  start.sh                               — mounted into the container; sources ROS2 env, launches both drivers
  record_sensors_bag.sh                  — runs on the dock; records RealSense + Hesai to a rosbag2 bag under ~/rosbags (Section 10)
  hesai_lidar_src/                       — vendored Hesai driver source (not a git repo upstream), patched to build against Humble
tools/
  go2_network_setup.sh                — scripted PC static-IP setup (nmcli persistent), ping check, UFW check/fix
  cyclone_domain0_enp3s0.xml          — isolated-bridge Cyclone config, dock-facing side, --ethernet default (domain 0 on enp3s0); --wifi/-i generate an equivalent temp config at runtime instead
  cyclone_domain42_lo.xml             — isolated-bridge Cyclone config, RViz-facing side (domain 42 on loopback -- always, regardless of --ethernet/--wifi, since it's PC-local only)
  launch_all_sensors_docker.sh        — one-shot script: docker compose up -d + domain_bridge + RViz2, --ethernet (default) or --wifi (Section 9)
  bridge_docker.yaml                  — domain_bridge whitelist for the script above (RealSense + Hesai topics)
  go2_sensors_docker.rviz             — RViz2 layout for the script above (Fixed Frame: rslidar)
  go2_sensors_playback.rviz           — RViz2 layout for local rosbag playback (Section 10), for isolated ROS_DOMAIN_ID 99 (vs. 42 for the live config above)
  play_and_visualize_bag.sh           — one-shot script: ros2 bag play (isolated domain, half-speed default) + auto-launch RViz2 (Section 10)
  dds_probe.c / dds_probe             — standalone DDS participant/topic enumerator (no SDK dependency); used to confirm the --wifi multicast limitation (Section 9)
  raw_mcast_rx.c / raw_mcast_rx       — bare UDP multicast receiver (bypasses DDS entirely, for diagnosing netfilter issues)
  probe_cyclonedds.xml                — Cyclone config for the probes above (domain-any, binds to Ethernet iface)
  probe_cyclonedds_trace.xml          — same + discovery tracing enabled
```

## 14. References

- Unitree developer documentation (SDK reference, message/API definitions):
  https://support.unitree.com/home/en/developer
- [`previous_approaches_and_build_history.md`](previous_approaches_and_build_history.md) — deprecated approach + full build debugging history
- [`AGENTS.md`](AGENTS.md) — condensed session context for future agent work in this repo
- [`realsense_humble_docker/`](realsense_humble_docker/) — the Docker build context (Dockerfile, compose file, start script, vendored Hesai source)
- [`tools/launch_all_sensors_docker.sh`](tools/launch_all_sensors_docker.sh) — one-shot script: RealSense + Hesai → RViz2 (Section 9)
- [`realsense_humble_docker/record_sensors_bag.sh`](realsense_humble_docker/record_sensors_bag.sh) — records RealSense + Hesai to a rosbag2 bag on the dock (Section 10)
- [`tools/go2_sensors_playback.rviz`](tools/go2_sensors_playback.rviz) — RViz2 layout for local rosbag playback (Section 10)
- [`tools/play_and_visualize_bag.sh`](tools/play_and_visualize_bag.sh) — one-shot script: play a bag + auto-launch RViz2 (Section 10)
