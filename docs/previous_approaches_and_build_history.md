# Previous Approaches & Build History

This doc exists so the reasoning behind the current setup (README.md,
`go2_sensors_docker/`, `tools/launch_all_sensors_docker.sh`) isn't lost.
It covers two things, in order:

1. **The approach used before this one** — native ROS1 RealSense driver +
   `ros1_bridge` + native ROS2/Foxy Hesai. Fully superseded, kept here for
   context only. Do not follow these steps for new setups.
2. **The build history of the current Docker/Humble approach** — every real
   bug hit getting `go2-sensors-humble` working, in the order they were
   found, so a future session doesn't have to rediscover any of them.

---

## Part 1: The previous approach (deprecated) — ROS1 RealSense + `ros1_bridge`

**Why it existed:** the dock's native OS only ships ROS2 Foxy and ROS1
Noetic. RealSense never had a ROS2 build for this arm64/focal image, so the
only way to get camera data onto ROS2 was: run the camera on its native
ROS1 driver, then bridge ROS1 → ROS2 with `ros1_bridge`.

**Architecture that resulted:**

```
DOCK (192.168.123.18)                         PC
├── roscore                                   ├── domain_bridge
├── realsense2_camera (ROS1/noetic)           │   domain 0 -> 42
├── ros1_bridge dynamic_bridge                │   (LiDAR topics only)
│     --bridge-all-topics, ROS_DOMAIN_ID=42   ├── static_transform_publisher
└── hesai_lidar_node (ROS2/foxy, native)      └── rviz2 (domain 42 only)
```

**Working RealSense launch config** (after root-causing a depth-stream USB
probe/commit failure, see `realsense_depth_stream_fix.md`):

```bash
source /opt/ros/noetic/setup.bash
roscore &
roslaunch realsense2_camera rs_camera.launch \
  initial_reset:=true enable_infra1:=false enable_infra2:=false
```
Color + depth only — depth + both IR streams together reliably failed on
this hardware even with `initial_reset:=true`.

**Why the ROS2 side of `ros1_bridge` ran on an isolated `ROS_DOMAIN_ID=42`,
not the robot's own domain 0:** running it directly on domain 0 — where the
robot's main computer (`.161`) constantly broadcasts ~90 topics — reproducibly
crashed CycloneDDS (segfault in its own discovery-packet parser; FastRTPS
spammed `bad_alloc` instead) and left the *whole dock's ROS2 stack* corrupted
afterward — even unrelated `ros2 topic list` calls then failed, requiring a
dock reboot. Isolating on domain 42 avoided this entirely; a pure DDS
*subscriber* (the PC-side `domain_bridge`) onto domain 0 never crashed it.

**Why `dynamic_bridge`, not `parameter_bridge`:** this `ros1_bridge 0.9.7`
arm64 build couldn't take a YAML config path as a CLI arg — it validated the
string as a ROS1 graph resource name and threw `ros::InvalidNameException` on
the dots in `.yaml`. `--bridge-all-topics` needed no config file at all.

**Installing `ros1_bridge` on the dock** was itself blocked by the same class
of issue documented in Part 2 below (expired ROS apt signing key / stale
mirror index) — fixed at the time by refreshing the keyring and switching the
mirror to `packages.ros.org` directly.

**Hesai's memory-leak hazard (found and fixed under this approach too):**
`hesai_lidar_node` got OOM-killed (~14.7 GB RSS within seconds) whenever
launched non-interactively via `ssh host "cmd"`, but worked fine typed
interactively over SSH with the exact same command. Root cause: the dock's
`~/.bashrc` only sources its custom-built CycloneDDS workspace
(`~/cyclonedds_ws/`) for **interactive** shells — a non-interactive
`ssh host "cmd"` invocation skips `.bashrc` entirely (the standard
`case $- in *i*) ;; *) return;; esac` guard), so the node ran against the
wrong CycloneDDS build. Fix: explicitly source
`~/cyclonedds_ws/install/setup.bash` + `CYCLONEDDS_URI` +
`LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH` before launching it
non-interactively.

**Known unresolved issues at the time this approach was retired:**
- `/camera/depth/color/points` (pointcloud filter) never worked; depth rate
  dropped to ~10.5 Hz when the filter was enabled. Likely needed
  `enable_sync:=true` — never tested further.
- `ros2 topic echo`/`hz` intermittently threw
  `ValueError: Expected the full name of a message, got '...'` on this dock's
  Foxy `ros2cli` (~1-in-3 to 1-in-5 invocations) — confirmed harmless CLI
  flakiness, not broken data. `ros2 topic info /TOPIC -v` (check
  `Publisher count`) was the reliable alternative.
- A native ROS2 `realsense-ros` build (`ros2-legacy` branch) was investigated
  once and abandoned as an unmaintained/EOL branch, with a `colcon build`
  failure on a missing `realsense2Config.cmake` path never chased down. This
  is effectively what Part 2 below finally did properly, on the *current*
  `ros2-master` branch, in a container instead of natively.

**Why this approach was dropped:** it required three moving parts on ROS1
(`roscore`, ROS1 driver, `dynamic_bridge`) that don't exist at all in the
Docker/Humble approach, an isolated-domain workaround for a DDS crash bug,
and per-session manual re-sourcing of a custom CycloneDDS build to avoid an
OOM. The Docker approach (Part 2) needs none of this — RealSense and Hesai
are both native ROS2 Humble nodes in one container from the start.

---

## Part 2: Building `go2-sensors-humble` — full debugging history

Base image: `dustynv/ros:humble-desktop-l4t-r35.3.1` (Jetson/L4T, Ubuntu 20.04
focal, ROS2 Humble built from source since Humble was never released for
focal). Goal: RealSense D435i + Hesai PandarXT-16, both native ROS2 Humble, in
one container, launched via `docker compose up -d`.

Each of the following was a real failure, hit in this order, each requiring a
full rebuild cycle to find:

### 1. Expired ROS apt signing key
`apt update` failed with `EXPKEYSIG F42ED6FBAB17C654` — the Open Robotics ROS
apt signing key had expired (a global issue as of when this was hit, not
specific to this Dockerfile). An initial `trusted=yes` sed-based workaround
did **not** actually work (the very next `apt update` hit the identical
error).

**Real fix, and the deeper realization:** no `ros-humble-*` apt package
exists for `focal` at all — official ROS2 Humble binaries only ever targeted
Ubuntu 22.04 (jammy); this base image builds Humble entirely from source
*because of that*. The fix was to delete the `packages.ros.org` apt source
entirely (`sed -i '/packages\.ros\.org/d' ...`) rather than re-key it — there
was nothing on it that this build actually needed
(`ros-humble-rmw-cyclonedds-cpp`, originally in the apt-install list, turned
out to already be present under `/opt/ros/humble` from the base image's own
source build).

### 2. `gpg --dearmor` needing `--batch --yes`
A dead end from an earlier attempt at re-fetching a fresh key (before
realizing #1's real fix made this unnecessary): `gpg --dearmor` failed with
`cannot open '/dev/tty': No such device or address` in the non-interactive
`docker build` shell. Fix would have been `--batch --yes`, but moot once the
ROS apt source was dropped entirely.

### 3. `rosdep`'s apt-based resolution is fundamentally broken here
Same root cause as #1: rosdep's key→apt-package mapping has no `focal` entry
for *any* ROS-Humble key (`ament_cmake`, `rclcpp_components`, etc.) since
those debs only exist for jammy. Whack-a-mole `--skip-keys`-ing individual
keys wasn't sustainable. Fixed by making the whole `rosdep install` (and
later `rosdep update` — see #7) non-fatal (`|| true`), and letting
`colcon build` surface any dependency that's *actually* missing instead.

### 4. The real root cause of `ament_cmake` "not found" in CMake
Even after #3, `colcon build` failed with a CMake `find_package(ament_cmake)`
error. Root cause: the Dockerfile sourced `/opt/ros/humble/setup.bash`, which
**does not exist** — the real path in this image is
`/opt/ros/humble/install/setup.bash`. The bad `source` command failed
silently because it was chained as `source ... && (rosdep init || true) && ...`
— bash operator precedence meant the `|| true` on `rosdep init` also absorbed
the `source` command's own failure, so `colcon build` ran with **no ROS
environment sourced at all**. Fixed the path everywhere it appeared, and
parenthesized `(rosdep init || true)` so it can't mask an unrelated failure
like this again.

### 5. `diagnostic_updater` and `xacro` missing from the base image
Both genuinely absent (not just a rosdep-mapping issue) — this base image is
a minimal from-source Humble build, not the full desktop apt package set.
Built both from source alongside `realsense-ros`: `ros/diagnostics`
(`ros2-humble` branch) and `ros/xacro` (`ros2` branch).

### 6. librealsense version mismatch
`realsense-ros`'s `ros2-master` branch requires librealsense **≥2.58.0**; the
Dockerfile was pinned to `v2.55.1`. Bumped to `v2.58.4` (the latest release at
the time) — this forces a full librealsense2 recompile (the single most
expensive step in the whole build, ~30-60 min on the dock's 4 cores), so
version mismatches like this are costly to get wrong.

### 7. Dock reboot mid-build → transient network loss
Mid-session the dock (or its upstream router) was rebooted, leaving it with
no route to its gateway/internet for a while. `rosdep update` failed hard
(not just non-fatally resolved keys — the actual sources-list *download*
failed), and since it wasn't wrapped in `|| true`, it aborted the entire
build before ever reaching `colcon build`. Fixed by wrapping
`rosdep update` in `|| true` too — nothing in this build actually depends on
rosdep succeeding, so a flaky network shouldn't be able to waste a full
rebuild cycle.

### 8. Adding the Hesai driver to the same image
The Hesai driver already ran natively on the dock's ROS2 Foxy install
(`/unitree/module/graph_pid_ws/src/HesaiLidar_General_ROS-ROS2`, not a git
repo — vendored straight from that path into the Docker build context,
excluding its stale Foxy-era CMake `build/` artifacts). Rebuilding it against
Humble surfaced a chain of real, previously-undeclared dependencies — its
`CMakeLists.txt`/`package.xml` only listed `tf2`/`tf2_msgs`/
`tf2_geometry_msgs`, but the source actually needed:
- `tf2_ros` (used directly in `pandarGeneral_internal.h`)
- `image_transport` (used in `main_ros2.cc`)
- `pcl_conversions` (used in `main_ros2.cc`, and was explicitly commented out
  in the original `package.xml`)
- `rclcpp_components` (used in `main_ros2.cc`)

Plus one missing header even after declaring `tf2_ros`:
`tf2_ros::Buffer` isn't pulled in by `<tf2_ros/transform_listener.h>` alone
on this ROS2 version — needed an explicit `#include <tf2_ros/buffer.h>`.

Also needed non-ROS system libs the driver's own README documents but weren't
yet installed: `libpcl-dev`, `libpcap-dev`, `libboost-thread-dev`,
`libboost-system-dev`.

One self-inflicted detour: a `sed` command meant to append a new
`<depend>rclcpp_components</depend>` line accidentally matched inside an
already-commented-out line in `package.xml`, producing a **duplicate**
`<depend>` entry that broke `package_xml_2_cmake.py` parsing entirely
(`CMake Error ... ament_package_xml.cmake`). Fixed by rewriting the file
cleanly rather than patching further.

### 9. `docker-compose.yml` YAML folding bug
The first version of `docker-compose.yml`'s multi-line `command: >` block put
the `hesai_lidar_node`'s `-p key:=value` arguments at a **deeper indentation**
than the surrounding lines. YAML's folded-scalar (`>`) rules only fold lines
at the *same* indentation into one space-joined string — a more-indented
sub-block is treated as literal, newlines preserved. Bash then executed each
`-p key:=value` as its own separate (invalid) command
(`bash: line N: -p: command not found`), and the container crash-looped
(`Restarting (127)`). Fixed by moving the whole launch sequence into a real
shell script (`start.sh`, mounted read-only into the container) instead of
fighting YAML indentation rules.

### 10. ROS2 empty-string parameter syntax
Even after #9, `hesai_lidar_node` still crashed:
`Couldn't parse parameter override rule: '-p pcap_file:='. Error: error not set`.
Passing `-p pcap_file:=""` in bash strips the quotes before the argument ever
reaches the program, leaving a bare `pcap_file:=` with no value at all, which
ROS2's parameter-override YAML parser rejects outright. Fixed by passing a
*literal* empty-string YAML value that survives bash's own quoting:
`-p "pcap_file:=''"` (the single quotes are part of the string bash passes
through, not bash's own quoting).

### 11. RViz showing nothing / stuck on the first frame (client-side, not the container)
Once the image built and ran cleanly, the RViz config's `RealSenseColor`/
`RealSenseDepth` displays pointed at `/camera/color/image_raw` and
`/camera/depth/image_rect_raw` — the old `ros1_bridge`-era topic names from
Part 1. The container actually publishes under a **doubled** namespace,
`/camera/camera/color/image_raw` and `/camera/camera/depth/image_rect_raw`
(a `realsense-ros` `ros2-master`-branch default of
`camera_name = camera_namespace = "camera"`). RViz was simply subscribed to
topics that don't exist. Fixed by creating a dedicated
`go2_sensors_docker.rviz` with the corrected topic names. (The old
`tools/go2_sensors.rviz` this was cloned from, along with the rest of Part
1's files, was later deleted entirely as unused — see item 14 below.)

Separately, "nothing arrives on the controller at all" (not just a stale
frame) turned out to be a **duplicate `domain_bridge` process** left running
locally from an earlier diagnostic session, competing with the one
`launch_all_sensors_docker.sh` started — two DDS participants both
republishing the same domain-0 topics onto domain 42. Killing the leftover
process fixed it immediately. Lesson: always confirm with
`pgrep -af domain_bridge` before assuming a bridging/config bug when nothing
arrives.

Also found in passing: `kill "$PID"` where `$PID` was captured from
`ros2 run <pkg> <exe> &` only kills the Python `ros2 run` wrapper, not the
actual compiled binary it execs as a child — leaving `domain_bridge` (and, in
the now-deleted native script, `static_transform_publisher`) running as
orphans after "cleanup". Fixed in `launch_all_sensors_docker.sh` with an
additional `pkill -f "lib/domain_bridge/domain_bridge"` by binary path.

### 12. Known open item: RealSense depth-stream USB hardware error
Independent of all of the above — with the camera physically attached, the
depth sensor sometimes logs `control_transfer returned error ... Resource
temporarily unavailable` and a `Depth stream start failure, Hardware Error`
right after `"RealSense Node Is Up!"`. This is a USB-level issue, likely tied
to the Jetson's `FORCE_RSUSB_BACKEND=true` build flag (required since this
kernel lacks the UVC metadata patches for the native driver) combined with an
underpowered/passive USB hub or a marginal cable in the path. Not yet
root-caused or fixed.

### 13. Compressed image transport for RViz (resolved)
The `compressed_image_transport` plugin (`ros-humble-image-transport-plugins`)
wasn't installed on the PC — only base `image_transport` was. RViz2's Image
display has no separate "transport hint" property; it infers transport
directly from the topic name typed into the display (stripping a `/compressed`
suffix), so pointing a display at `/camera/camera/color/image_raw/compressed`
without the plugin installed threw `image_transport::TransportLoadException`
rather than fixing anything. This turned out to be exactly what was needed:
raw uncompressed 720p color over the bridged link (`domain_bridge`,
double-serialized) made the `RealSenseColor` display appear stuck on the
first frame, even though `ros2 topic hz` confirmed data kept flowing fine at
the DDS level the whole time — an RViz-side rendering bottleneck, not a
bridging bug. Fixed once the user installed the plugin (`sudo apt-get
install -y ros-humble-image-transport-plugins`) and both
`tools/bridge_docker.yaml` and `tools/go2_sensors_docker.rviz` were updated
to bridge/subscribe to the compressed topic instead of raw. Depth is still
raw (untouched, no reported issue there).

A separate "now the LiDAR doesn't arrive" report right after this fix turned
out to be nothing new — `/rslidar_points` was confirmed flowing correctly at
both the source and on domain 42 the whole time; the actual problem was that
the RViz config's `Hide Left Dock: true` setting hid the Displays panel
entirely, so there was no way to see the (harmless) status icon that would
have shown the point cloud was fine. Fixed by setting `Hide Left Dock:
false`.

### 14. Repo cleanup: deprecated Part 1 files deleted
`tools/launch_all_sensors.sh`, `tools/bridge.yaml`, and `tools/go2_sensors.rviz`
(the native ROS1/`ros1_bridge` approach described in Part 1) were deleted
outright once this history doc existed to preserve the knowledge in writing
— the runnable scripts themselves were genuinely unused by that point. Any
"see `tools/launch_all_sensors.sh`" references elsewhere in this doc predate
that deletion and describe a file that no longer exists.

### 15. Ethernet vs WiFi support, and a real domain-42 config bug found along the way
The dock gained a second network path — a USB WiFi adapter (TP-Link
TL-WN823N, `RTL8192EU`, driver works out of the box) joined to the same WiFi
network the PC is on, in addition to the existing Ethernet link to the robot
subnet. `launch_all_sensors_docker.sh` was extended with `--ethernet`
(default) / `--wifi` flags to pick which link to SSH over — WiFi resolves
the dock via mDNS (`unitree@ubuntu.local`) rather than a hardcoded IP, since
the WiFi IP is DHCP-assigned and observed to actually change between
sessions. Each mode auto-detects the right local PC interface for the
`domain_bridge` to bind to.

While wiring this up, a real pre-existing bug was found and fixed:
`tools/cyclone_domain42_lo.xml` — meant to isolate domain 42 (used only
locally between `domain_bridge` and `rviz2`, both on the PC) to loopback —
was actually bound to `enp3s0`, not `lo`. It "worked" anyway before this was
noticed because domain 42 traffic between two processes on the same machine
succeeds regardless of which interface it's nominally bound to; the bug just
meant domain 42 traffic was also leaking onto the physical network
unnecessarily. Fixed to bind to `lo` properly — this is correct for both
`--ethernet` and `--wifi` modes, since domain 42 never actually needs to
leave the PC.

**Known limitation found, not fixed:** `--wifi` mode's SSH/`docker compose`
control and `record_sensors_bag.sh` (which never leaves the dock) work fine,
but the `domain_bridge`/RViz visualization step doesn't receive any data
over WiFi on this project's network. Confirmed with `tools/dds_probe`: 0
external DDS participants discovered over the PC's WiFi interface in 10s of
listening, vs. instant discovery over Ethernet. ROS2/DDS discovery relies on
multicast by default, and consumer WiFi routers commonly block or don't
forward multicast between wireless clients ("AP/client isolation" or
similar). This is a router-configuration issue, not a script bug — the user
opted to investigate the router's admin settings rather than have a more
fragile unicast-peers CycloneDDS workaround attempted (which would need
tracking two independently-DHCP-assigned IPs on both the container and PC
sides). `--ethernet` is unaffected.

### 16. Investigated: recording from the dock's native ROS2 instead of the container
Since the container's topics are visible to the dock's native ROS2 Foxy
install too (via `network_mode: host`), it was worth checking whether
`ros2 bag record` could run natively on the dock instead of via
`docker exec` into the Humble container -- would have simplified
`record_sensors_bag.sh` and sidestepped the root-ownership `chown` step
entirely (native recording runs as the `unitree` user directly, no
container root involved).

Confirmed via direct testing: `ros2 topic list` from native Foxy does see
the container's topics fine, but actually recording them crashes --
`ros2 bag record` segfaults (`Segmentation fault`, exit 139) as soon as
messages start arriving, even for standard `sensor_msgs` types. This is a
cross-ROS-distro incompatibility between Foxy (2020) and Humble's
type-support/introspection metadata, not a QoS or topic-name issue.
Recording has to use the matching distro's tooling, so `record_sensors_bag.sh`
correctly stays as-is: `docker exec` into the container, `chown` the result
back to `unitree` afterward.

### 17. Rosbag playback showing live data instead of the recording
The first version of the playback instructions (Section 10) didn't set
`ROS_DOMAIN_ID` for either `ros2 bag play` or `rviz2`, leaving both on the
default domain 0 -- the same domain the `go2-sensors-humble` container
broadcasts on network-wide (via `network_mode: host`) whenever it's running.
Result: RViz subscribed to both the live container's publishers and the bag
player's publishers on the same topic names at once, with no error or
warning -- it just silently showed the live feed instead of (or mixed with)
the recording. Fixed by isolating playback onto its own dedicated
`ROS_DOMAIN_ID` (`99`, an arbitrary value not used anywhere else in this
project -- 0 is the robot/live domain, 42 is the live-viewing bridge's
domain) on both the player and RViz.

### 18. Recording switched to compressed color; compressedDepth found unusable
Following item 17's fix, the recording pipeline itself was changed to record
`/camera/camera/color/image_raw/compressed` instead of raw color -- same
~30Hz rate (JPEG encoding is cheap), much smaller bag, and it sidesteps the
"laggy in RViz" symptom during playback entirely (same root cause as the
live-viewing fix in item 13: raw 1280x720 at ~30Hz is a lot of data for
RViz/rosbag2 to push through, regardless of whether the source is live or a
local file).

Depth was also tested with its compressed transport (`compressedDepth`)
before deciding against it: confirmed via `ros2 topic hz` that it only
publishes at **~0.7Hz** on this hardware, vs. ~24-28Hz for raw depth --
PNG-encoding 16-bit depth data is apparently too CPU-expensive on this
Jetson to keep up. Recording depth via `compressedDepth` would silently
lose ~97% of depth frames. Depth stays raw in the recording; only color
uses compressed transport. `record_sensors_bag.sh`, its standalone
commands, and `tools/go2_sensors_playback.rviz` were all updated to match
(and pushed to the dock).

Verified the whole pipeline end-to-end after the change: recorded a fresh
test bag with the new topic list, confirmed message counts/rates via
`ros2 bag info` and `ros2 topic hz` during playback, and confirmed
`go2_sensors_playback.rviz` loads without error against it.

### 19. `play_and_visualize_bag.sh` created; a real RViz2 shutdown-hang bug found and fixed along the way
`tools/play_and_visualize_bag.sh` was added to combine bag playback +
auto-launched RViz2 into one command, defaulting to half-speed playback
(`-r 0.5`) to ease the lidar/RViz render load (no point-cloud
voxel-downsampling tool is installed on this PC -- `ros-humble-pcl-ros`
would add one, but needs `sudo`), and always isolating onto its own
`ROS_DOMAIN_ID` (default `99`) per item 17's fix.

First version ran RViz2 as a blocking foreground command with the bag player
backgrounded behind it. Testing found this was fragile: RViz2 was observed
to sometimes hang indefinitely after receiving SIGINT rather than exiting
(no crash, just stuck in state `Sl`), and separately, on another run, to
abort with `rviz2: tpp.c:83: __pthread_tpp_change_priority: Assertion ...
failed` (an internal Qt/pthread issue, unrelated to this script). In the
hang case specifically, a foreground `rviz2 ...` as the script's last
command meant bash was blocked inside that exec and could never reach the
cleanup trap -- the bag player would be orphaned. Fixed by backgrounding
*both* processes and using `wait -n "$PLAYER_PID" "$RVIZ_PID"`, matching the
pattern already used in `go2_sensors_docker/start.sh` on the dock --
either process exiting (cleanly, hung-then-killed, or crashed) now reliably
reaches the cleanup trap, which kills both (with a `kill` then `kill -9`
grace-period fallback). Verified after the fix: intentionally triggered the
same abort-on-shutdown case again and confirmed cleanup still left no
orphaned processes.

### 20. Adding compressedDepth to the recording regressed raw depth too
After a later request to also record `compressedDepth` (in addition to raw
depth, not instead of it), testing revealed this isn't a free additional
stream: subscribing to `compressedDepth` drags the **raw** depth topic down
to the same **~0.7Hz** as `compressedDepth` itself, from its normal
~24-28Hz. Confirmed via a real recording and `ros2 bag info`: both
`/camera/camera/depth/image_rect_raw` and its `/compressedDepth` sibling
showed exactly 10 messages in the same 14.27s window, vs. 421 for color and
143 for lidar in that same window. Subscribing anything to the
`compressedDepth` transport appears to throttle the driver's entire depth
publish pipeline on this hardware, not just the compressed subscriber's own
rate.

Presented this finding and asked how to proceed; the user chose to accept
the tradeoff and keep `compressedDepth` in the recording anyway, understanding
that means **both** depth streams end up sparse (~0.7Hz) rather than getting
a full-rate raw stream plus a bonus low-rate compressed one.
`record_sensors_bag.sh`'s header comment and README.md's Recording & Playing Back Rosbags section were
corrected to state this plainly (the first version, written before this was
discovered, incorrectly claimed raw depth would stay at full rate).

### 21. Reverted item 20 -- compressedDepth removed from the recording
After actually using the `compressedDepth`-included recording, both lidar
and depth looked bad in RViz -- reverted back to the confirmed-working
3-topic version (compressed color + raw depth + lidar) from before item 20.
`record_sensors_bag.sh` (local and dock, confirmed identical via `diff`
after pushing), README.md's Recording & Playing Back Rosbags section, and the standalone recording command
were all reverted to match.

### 22. Real root cause found: unscoped `<Domain>` block silently broke domain_bridge's domain-42 side entirely
Days after item 21 (Sept 14, vs. Sept 11), the pipeline stopped working
consistently -- `launch_all_sensors_docker.sh` would run clean through all
4 steps with no errors, but RViz showed nothing at all, every time.

**Investigation path** (each step ruled something out):
- Confirmed only one `domain_bridge` instance running (not the item-11 duplicate-process bug).
- Confirmed the container was up and genuinely publishing (`ros2 topic hz` on
  the dock showed real data).
- `ros2 topic info /rslidar_points -v` on domain 0 showed the bridge's
  subscriber correctly matched to the container's publisher (Publisher
  count 1, Subscription count 1) -- domain-0 side was completely healthy.
- The same check on domain 42 showed **Publisher count: 0** -- the bridge
  never created anything there at all, despite `ros2 node list` on domain 0
  showing its `go2_bridge_docker_0` node existed and was receiving.
- A stray `ros2-daemon` running `rmw_fastrtps_cpp` on domain 0 (leftover
  from some earlier command that didn't set `RMW_IMPLEMENTATION`/
  `ROS_DOMAIN_ID`) was found and killed as a plausible culprit -- CycloneDDS
  and FastRTPS sharing UDP port 7400 for domain-0 discovery seemed like it
  could plausibly corrupt things. Didn't fix it; a completely fresh
  `domain_bridge` instance after removing the daemon still failed the same
  way.
- Checked `/proc/<pid>/task/` thread states: domain_bridge genuinely had two
  full sets of CycloneDDS worker threads (one per domain), both sleeping
  normally, not hung/spinning.
- `dds_probe` (the repo's own raw-DDS diagnostic) turned out to hardcode
  domain 0 internally regardless of `ROS_DOMAIN_ID` -- a red herring; it
  can't actually test domain 42 at all. Worth remembering for next time.
- Confirmed with plain `ros2 topic pub`/`ros2 topic echo` that basic domain-42
  loopback discovery works fine on this machine -- ruling out a general
  domain-42/loopback problem and narrowing it specifically to
  `domain_bridge`'s cross-domain behavior.
- Reproduced with a **minimal single-topic** bridge config (not the full
  6-topic `bridge_docker.yaml`) -- ruled out anything topic/type-specific.
- Checked for RouDi (Iceoryx's shared-memory daemon, auto-installed as a
  CycloneDDS dependency) -- not running. Plausible lead, but never
  conclusively tested in isolation before the real fix was found.

**Actual root cause**: `tools/cyclone_domain0_enp3s0.xml` had a single
`<Domain>` block with no `id` attribute. CycloneDDS applies an unscoped
`<Domain>` block to **every** domain a process opens. `domain_bridge` is
the *only* process in this entire setup that opens two different
`ROS_DOMAIN_ID`s (0 and 42) in one process -- every other process (rviz2,
the container, every `ros2` CLI diagnostic used above) only ever opens one
domain, so the bug was invisible everywhere except inside `domain_bridge`
itself. The unscoped block forced domain_bridge's domain-42 participant to
also try binding `enp3s0` (meant for domain 0) instead of `lo` -- since
rviz2 correctly binds only `lo` via `cyclone_domain42_lo.xml`, the two
could never find each other. Basic participant-level discovery machinery
still started fine (hence the healthy-looking threads and bound ports),
but no topic-level match ever completed.

Genuinely unclear why this didn't surface in any of the many earlier
successful sessions using the exact same (buggy) config -- possibly a
CycloneDDS version nuance in how it resolves an ambiguous same-host
same-interface-name bind between two domains, possibly something
environment-specific that changed between Sept 11 and Sept 14. Not fully
explained, but the fix itself was verified conclusively: reproduced the
failure with a minimal repro, fixed it by adding explicit `<Domain id="0">`
/ `<Domain id="42">` scoping, and confirmed all three topics (lidar, color,
depth) flowing again at their normal rates through the real, unmodified
`launch_all_sensors_docker.sh` script.

**Fix**: both `tools/cyclone_domain0_enp3s0.xml` (the static default-Ethernet
config) and the temp config `launch_all_sensors_docker.sh` generates for
`--wifi`/custom `-i` now use explicit `<Domain id="0">`/`<Domain id="42">`
blocks instead of one unscoped block. `tools/cyclone_domain42_lo.xml` needed
no change -- it's only ever used by single-domain processes (rviz2, `ros2`
CLI checks), where an unscoped block is perfectly correct.

**Unrelated bug fixed in the same debugging session**: the script's cleanup
trap unconditionally `rm -f`'d `$DOMAIN0_CONFIG` on every exit -- in the
`--ethernet` default case, that variable points directly at the permanent,
git-tracked `cyclone_domain0_enp3s0.xml` rather than a generated temp file,
so *every run of the script deleted its own config file on exit*. This had
been silently happening for days (the file kept mysteriously vanishing
between sessions) before being traced to this line. Fixed by tracking
whether the config is actually a generated temp file
(`DOMAIN0_CONFIG_IS_TEMP`) and only deleting it in that case.
