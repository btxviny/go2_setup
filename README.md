# Go2 EDU — RealSense + Hesai on ROS2 Humble (Docker)

High-level guide to the current Go2 EDU sensor setup. For detailed
networking/connectivity (topology, credentials, WiFi setup,
troubleshooting), see **[`networking.md`](networking.md)** — this file
stays focused on what's actually running and how to use it.

**This is the current approach.** An earlier approach (native ROS1
RealSense driver + `ros1_bridge`) was used before this and is fully
superseded — see
[`previous_approaches_and_build_history.md`](previous_approaches_and_build_history.md)
for that history and the full chronological debugging log behind every
decision below.

> Official Unitree developer docs (SDK, API message definitions, service
> descriptions): https://support.unitree.com/home/en/developer

---

## What's been done

- **RealSense D435i + Hesai PandarXT-16 run as native ROS2 Humble nodes**
  inside a Docker container (`go2-sensors-humble`) on the Go2 expansion
  dock — see [Why a Docker container](#why-a-docker-container) below.
- **KISS-ICP LiDAR odometry is built into the same container, but not
  launched by default** (commented out in `start.sh`) — see [LiDAR Odometry
  (KISS-ICP)](#lidar-odometry-kiss-icp) below for status and what's blocking
  it from being turned on.
- **The dock is reachable two ways**: Ethernet (primary, required for live
  sensor visualization) and WiFi (out-of-band, added later, for SSH/`docker`
  control and file transfer without the cable). Full setup in
  [`networking.md`](networking.md).
- **One-shot scripts** bring the sensor data into RViz2 on the controller
  PC, and record/play back rosbags — see below.

## Why a Docker container

The dock's native OS only ships ROS2 Foxy and ROS1 Noetic — there's no
ROS2 Humble, and no RealSense ROS2 apt package for this arm64/focal image
at all, because official ROS2 Humble binaries only ever targeted Ubuntu
22.04 (jammy), not the dock's 20.04 (focal). A from-source native install
would fight the same missing-package problem the whole way.

Instead, **`go2-sensors-humble`** (built from source on
`dustynv/ros:humble-desktop-l4t-r35.3.1`) runs both drivers as native ROS2
Humble nodes in one container, with `network_mode: host` and
`ROS_DOMAIN_ID=0` — so they publish directly on the robot's own DDS domain,
same as the robot's built-in sensors, no ROS1 or bridge process involved.
Getting there took real work (expired apt keys, missing dependencies, a
librealsense/realsense-ros version mismatch, patching the Hesai driver to
build against Humble) — full details in
[`previous_approaches_and_build_history.md`](previous_approaches_and_build_history.md)
Part 2, if you're debugging a similar build failure.

The image's build context (`Dockerfile`, `docker-compose.yml`, `start.sh`,
vendored Hesai source) lives on the dock at `~/go2_sensors_docker/`,
mirrored in this repo under [`go2_sensors_docker/`](go2_sensors_docker/)
for version control — **that local copy is for reference/editing only; the
image itself must be built on the dock** (arm64/Jetson-specific, this PC
can't build or run it):

Push the local copy to the dock (overwrites the dock's copy with this one):

(PC)
```bash
scp -r go2_sensors_docker unitree@192.168.123.18:~/
```

(dock)
```bash
cd ~/go2_sensors_docker
docker build -t go2-sensors-humble .    # 30-90 min first time (librealsense2 compile)
docker compose up -d                       # start both drivers, detached
```

## Connecting to the Dock

(PC)
```bash
ssh unitree@192.168.123.18       # Ethernet
ssh unitree@ubuntu.local          # WiFi (mDNS, robust to DHCP IP changes)
```

Full setup (including the one-time WiFi adapter configuration) and
troubleshooting: **[`networking.md`](networking.md)**.

## Launching: Live Visualization in RViz2

**[`tools/launch_all_sensors_docker.sh`](tools/launch_all_sensors_docker.sh)**
starts the container and launches RViz2 directly on the robot's own ROS2
domain (0) — no bridge, no isolated domain — one command:

(PC)
```bash
cd ~/go2_guide_docs/tools
./launch_all_sensors_docker.sh              # Ethernet (default)
./launch_all_sensors_docker.sh --wifi       # WiFi
```

Ctrl+C (or closing the RViz2 window) stops everything cleanly
(`docker compose down` on the dock).

**Known limitation:** `--wifi` doesn't reliably carry live RViz data on
this project's WiFi network (SSH/`docker`/recording all work fine over it
though) — see `networking.md`'s troubleshooting section.

**Prerequisites** (one-time): SSH key auth (`ssh-copy-id unitree@192.168.123.18`),
the image already built (above), and
`sudo apt-get install -y ros-humble-image-transport-plugins` on this PC
(RViz's color display needs it for compressed transport — without it RViz
throws `image_transport::TransportLoadException` instead of showing color).

**If nothing shows up in RViz**, check in order: is the container up
(`ssh unitree@192.168.123.18 docker ps`)? Does `ROS_DOMAIN_ID=0 ros2 topic
list` on this PC actually show the RealSense/Hesai topics (confirms DDS
discovery is working end to end)? Anything in
`docker logs --tail 50 go2-sensors-humble` on the dock?

### Running `ros2` CLI commands manually against this setup

`launch_all_sensors_docker.sh` sets the right environment for RViz2
automatically, but a plain new terminal (e.g. for `ros2 topic echo/hz/list`
while debugging) does not. **Source** (not run) `tools/ros2_env.sh` first,
**in that same shell**, or you'll get topics that "discover" but never
actually receive data:

(PC)
```bash
cd ~/go2_guide_docs/tools
source ros2_env.sh   # --ethernet only; must be sourced, not executed
ros2 topic hz /rslidar_points
```

`ros2_env.sh` just wraps the three exports below (`source /opt/ros/humble/setup.bash`,
`RMW_IMPLEMENTATION=rmw_cyclonedds_cpp`, `ROS_DOMAIN_ID=0`,
`CYCLONEDDS_URI` pointed at `cyclone_ethernet.xml`) so you don't have to
retype them every new terminal.

For `--wifi`, point `CYCLONEDDS_URI` at the temp config
`launch_all_sensors_docker.sh --wifi` generates instead (path printed to
the terminal on startup, under `/tmp/cyclone_domain0_*.xml`) — the static
`cyclone_ethernet.xml` won't discover anything over WiFi.

The most common failure mode: `RMW_IMPLEMENTATION` left unset. It silently
falls back to `rmw_fastrtps_cpp`, which can often still discover a
CycloneDDS publisher's topic (shows up fine in `ros2 topic list`) but then
gets zero actual messages — no error, just silence. See `networking.md`'s
architecture section and `AGENTS.md`'s "Common shell pitfalls" for the full
story.

## Recording & Playing Back Rosbags

**Recording must happen inside the container** (not the dock's native
Foxy ROS2, even though it can *see* the container's topics via
`network_mode: host` — actually recording from there **segfaults**, a
confirmed cross-ROS-distro incompatibility between Foxy and Humble's
type-support metadata). **Playback, by contrast, runs entirely on this PC**
— no dock or container involved — since the bag only contains standard
`sensor_msgs` topics.

### Recording

**[`go2_sensors_docker/record_sensors_bag.sh`](go2_sensors_docker/record_sensors_bag.sh)**
records `/camera/camera/color/image_raw/compressed`,
`/camera/camera/depth/image_rect_raw`, and `/rslidar_points` to a rosbag2
bag on the **dock's** filesystem (survives container restarts, via a
`~/rosbags:/rosbags` bind mount):

(dock)
```bash
ssh unitree@192.168.123.18
cd ~/go2_sensors_docker
./record_sensors_bag.sh                  # names the bag sensors_<UTC timestamp>
./record_sensors_bag.sh my_test_run       # or give it an explicit name
```
`Ctrl+C` stops it cleanly (finalizes the bag — don't `kill -9`, that can
corrupt `metadata.yaml`). The script prints the bag's path and an `scp`
command to pull it back.

**Color is recorded compressed** (JPEG, same ~30Hz rate as raw, much
smaller). **Depth is recorded raw, deliberately** — its compressed
transport (`compressedDepth`) was tested and found to make things *worse*:
subscribing to it drags the raw depth topic down too, to the same ~0.7Hz as
`compressedDepth` itself (vs. ~24-28Hz normally). Don't re-add it without
expecting that tradeoff.

Standalone command (without the script):
```bash
docker exec -it go2-sensors-humble bash -c \
  "source /opt/ros/humble/install/setup.bash && source /opt/realsense_ws/install/setup.bash && \
   ros2 bag record -o /rosbags/my_bag \
     /camera/camera/color/image_raw/compressed /camera/camera/depth/image_rect_raw /rslidar_points"
docker exec go2-sensors-humble chown -R $(id -u):$(id -g) /rosbags/my_bag   # fix root-owned files
```

### Copying a bag back to the PC

(PC)
```bash
scp -r unitree@192.168.123.18:~/rosbags/my_bag .   # Ethernet
scp -r unitree@ubuntu.local:~/rosbags/my_bag .     # WiFi
```

### Playback

**[`tools/play_and_visualize_bag.sh`](tools/play_and_visualize_bag.sh)**
plays a bag and auto-launches RViz2, one command:

(PC)
```bash
cd ~/go2_guide_docs/tools
./play_and_visualize_bag.sh /path/to/my_bag           # 0.5x speed (default)
./play_and_visualize_bag.sh /path/to/my_bag -r 1.0     # real-time
```

- Plays at **half speed by default** — the lidar cloud and raw depth are
  heavy for RViz to render, and there's no point-cloud downsampling tool
  installed on this PC; slower-than-real-time is the practical way to ease
  that load. Use `-r 1.0` if your machine keeps up fine.
- Isolates onto its own `ROS_DOMAIN_ID` (default `99`, override with `-d`)
  automatically — **this matters, not just tidiness**: if the container
  happens to be running at the same time, playback on the default domain
  would show you a mix of live and recorded data with no warning.
- Ctrl+C or closing the RViz2 window stops both processes cleanly.

## LiDAR Odometry (KISS-ICP)

A LiDAR odometry option is built into the `go2-sensors-humble` image, but
**not launched by default** — `start.sh` has its invocation commented out —
so the running container today is exactly RealSense + Hesai, nothing more.

### KISS-ICP (built, disabled)

[`kiss_icp_node`](https://github.com/PRBonn/kiss-icp) (from the `ros/`
wrapper in that repo, `v1.3.0`) subscribes to `/rslidar_points` and would
publish, all on domain 0 like everything else in the container (RViz2 also
now joins domain 0 directly, so nothing further would be needed to see
these topics):

- `/kiss/odometry` (`nav_msgs/msg/Odometry`) — estimated pose, egocentric to
  the Hesai's own frame (`rslidar`) since `base_frame` is left unset.
- `/kiss/local_map`, `/kiss/frame`, `/kiss/keypoints`
  (`sensor_msgs/msg/PointCloud2`) — accumulated map, deskewed current scan,
  and ICP keypoints, respectively.
- The `odom_lidar` <-> `rslidar` TF (published inverted — `rslidar` is the
  TF parent, `odom_lidar` the child — this is upstream's own default
  (`invert_odom_tf:=true`) and is what lets RViz use `odom_lidar` as the
  Fixed Frame; it's not a mistake if it looks backwards in `ros2 run tf2_tools view_frames`).

`tools/go2_sensors_docker.rviz`'s KISS-related displays are present but
disabled/removed pending re-enabling; re-enabling them needs no bridge
config now since RViz2 already sits on domain 0 directly.

Building it has one real unknown, not yet hit on the dock: the ROS
wrapper's CMake target requires C++20 (`cxx_std_20`), but this image's
default compiler is GCC 9 (Ubuntu 20.04 focal), which only has
partial/experimental C++20 support. If the build fails on that step
specifically, install `gcc-10`/`g++-10` (present in focal's default repos,
no PPA needed) and set `CC=gcc-10 CXX=g++-10` for just that `RUN` step.

## Known Issues

- **RealSense depth-stream USB hardware error** — intermittent
  `control_transfer returned error ... Resource temporarily unavailable` /
  `Depth stream start failure, Hardware Error` right after the node comes
  up. Likely `FORCE_RSUSB_BACKEND=true` + an underpowered USB hub/marginal
  cable. Not yet root-caused.
- **No shared TF between `rslidar`/`odom_lidar` and the RealSense's own
  frame** — KISS-ICP now links `rslidar` to `odom_lidar` (see [LiDAR
  Odometry](#lidar-odometry-kiss-icp)), but the camera's optical frame is
  still unconnected to either. Not an issue for the current RViz configs
  (Image displays don't need TF).
- **`launch_all_sensors_docker.sh`'s Hesai launch params are hardcoded** to
  the known-working config (`server_ip:=192.168.123.20`,
  `lidar_type:=PandarXT-16`, etc., in `start.sh`) — update there if the
  sensor's network config ever changes.

Full chronological debugging log (every bug found and fixed, including
several with non-obvious root causes worth knowing about before touching
the DDS/bridge config): [`previous_approaches_and_build_history.md`](previous_approaches_and_build_history.md).

## Repo Layout

```
README.md                                — this file (high-level)
networking.md                            — detailed connectivity: topology, credentials, Ethernet + WiFi setup, troubleshooting
AGENTS.md                                — agent/session context notes
previous_approaches_and_build_history.md — deprecated ROS1/ros1_bridge approach + full build debugging history
realsense_depth_stream_fix.md            — root-cause writeup for the OLD ROS1 driver's depth-stream USB failure (historical)
go2_realsense_hesai_setup.pdf            — external reference doc
go2_sensors_docker/
  Dockerfile, docker-compose.yml, start.sh   — builds/runs go2-sensors-humble (mirrors ~/go2_sensors_docker/ on the dock; also builds/launches KISS-ICP, see LiDAR Odometry section)
  config/cyclonedds_ethernet.xml         — container-side CycloneDDS config (default CYCLONEDDS_URI in docker-compose.yml); caps MaxMessageSize/FragmentSize under the Ethernet MTU to avoid IP fragmentation (see AGENTS.md item 11)
  record_sensors_bag.sh                  — runs on the dock; records a rosbag2 bag under ~/rosbags
  hesai_lidar_src/                       — vendored Hesai driver source, patched to build against Humble
tools/
  go2_network_setup.sh                — scripted PC static-IP setup, ping check, UFW check/fix
  cyclone_ethernet.xml                — CycloneDDS config for RViz2 on domain 0 over the default Ethernet interface (enp3s0)
  launch_all_sensors_docker.sh        — docker compose up -d + RViz2 directly on domain 0, --ethernet (default) or --wifi
  go2_sensors_docker.rviz             — RViz2 layout for live viewing (Fixed Frame: rslidar)
  ros2_env.sh                         — source (not run) to set RMW_IMPLEMENTATION/ROS_DOMAIN_ID/CYCLONEDDS_URI for manual ros2 CLI commands (--ethernet only)
  go2_sensors_playback.rviz           — RViz2 layout for rosbag playback (isolated ROS_DOMAIN_ID 99)
  play_and_visualize_bag.sh           — ros2 bag play + auto-launch RViz2
```

## References

- Unitree developer documentation (SDK reference, message/API definitions):
  https://support.unitree.com/home/en/developer
- [`networking.md`](networking.md) — connectivity setup and troubleshooting
- [`previous_approaches_and_build_history.md`](previous_approaches_and_build_history.md) — deprecated approach + full build debugging history
- [`AGENTS.md`](AGENTS.md) — condensed session context for future agent work in this repo
- [`go2_sensors_docker/`](go2_sensors_docker/) — the Docker build context
- [`tools/launch_all_sensors_docker.sh`](tools/launch_all_sensors_docker.sh) — live visualization
- [`go2_sensors_docker/record_sensors_bag.sh`](go2_sensors_docker/record_sensors_bag.sh) — rosbag recording
- [`tools/play_and_visualize_bag.sh`](tools/play_and_visualize_bag.sh) — rosbag playback
