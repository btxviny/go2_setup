# Go2 EDU — RealSense D435i Depth Stream Fails to Start (USB Probe-Commit Error, Fixed by `initial_reset:=true`)

## Symptom

Running the stock ROS1 RealSense driver on the dock:

```bash
source /opt/ros/noetic/setup.bash
roscore &
roslaunch realsense2_camera rs_camera.launch
```

produces a clean-looking startup log — `RealSense Node Is Up!`, all four
streams (`color`, `depth`, `infra1`, `infra2`) report as "enabled" — and
**`/camera/color/image_raw`, `/camera/infra1/image_rect_raw`, and
`/camera/infra2/image_rect_raw` all publish real data at their expected
rates** (color ~30 Hz, infra1/infra2 ~90 Hz). But
**`/camera/depth/image_rect_raw` never publishes anything** —
`rostopic hz` just prints `no new messages` indefinitely. No fatal error
is surfaced anywhere in `rosout` — the node reports as fully up and
running.

## Root Cause

Two distinct, compounding issues:

### 1. Stuck device firmware state (the primary blocker)

The camera's depth-stream USB endpoint was left in a bad internal state
from a previous session (most likely an earlier ungraceful shutdown — an
SSH disconnect, a `kill -9`, or a crash that didn't let the SDK release
the device cleanly). This causes the depth stream's USB probe-commit to
fail **every time**, regardless of resolution:

```
02/01 15:29:18,088 ERROR (uvc-device.cpp:862) Probe-commit control transfer failed with error: RS2_USB_STATUS_PIPE
[ERROR] An exception has been thrown: Failed to resolve the request:
    Format: Z16, width: 848, height: 480
[ WARN] Hardware Notification: Depth stream start failure, ..., Error, Hardware Error
```

Confirmed **not** a resolution/profile problem: the exact same
`RS2_USB_STATUS_PIPE` error occurs at both the default `848x480` and an
explicitly-forced standard `640x480` depth profile. Confirmed **not** a
USB bandwidth problem in isolation: depth alone (Z16, 640x480@30fps ≈
18.4 MB/s) fails even with `infra1`, `infra2`, and `color` all disabled —
while infra1+infra2 alone (Y8, 640x480@90fps ×2 ≈ 55.3 MB/s — nearly 3×
more raw bandwidth) stream perfectly fine. Only the depth stream's
specific endpoint negotiation fails.

**The `hwmon command 0x80(...) failed (response -7 = HW not ready)`**
warnings seen on every launch (4 repeats, then resolves) are a separate,
apparently benign, known transient warning on this platform — they occur
on every launch, including fully successful ones, and are not the cause
of the depth failure.

### 2. Genuine USB resource contention across all 4 streams (secondary, still present after the fix)

Even after fixing issue #1, running **all four streams simultaneously**
(`color` + `depth` + `infra1` + `infra2`, the `rs_camera.launch` default)
still causes depth to fail while the other three succeed. Depth only
streams reliably when `infra1`/`infra2` are disabled, freeing up
whatever shared resource (likely USB isochronous bandwidth reservation
slots or a Jetson USB-controller limitation, not raw throughput per se)
the depth endpoint needs to successfully commit alongside the others.

## The Fix

**Step 1 — clear the stuck firmware state** by forcing a hardware reset
at launch:

```bash
roslaunch realsense2_camera rs_camera.launch initial_reset:=true
```

This alone gets depth streaming again *if* `infra1`/`infra2` are
disabled. Confirmed via `rostopic hz`:

```
$ rostopic hz /camera/depth/image_rect_raw
average rate: 29.987
    min: 0.032s max: 0.035s std dev: 0.00026s window: 210
```

**Step 2 — disable the IR streams** to avoid the resource-contention
issue, since most use cases (obstacle detection, mapping, RGB-D SLAM)
only need color + depth anyway:

```bash
roslaunch realsense2_camera rs_camera.launch \
  initial_reset:=true \
  enable_infra1:=false \
  enable_infra2:=false
```

**Confirmed working simultaneously** with this exact combination:

| Topic | Rate |
|---|---|
| `/camera/color/image_raw` | 29.96 Hz |
| `/camera/depth/image_rect_raw` | 29.98 Hz |

Both rock-solid, low-jitter (std dev < 0.001s).

## Known Follow-up Issue: Point Cloud Filter Doesn't Publish

Adding `filters:=pointcloud` to the working color+depth launch:

```bash
roslaunch realsense2_camera rs_camera.launch \
  initial_reset:=true enable_infra1:=false enable_infra2:=false \
  filters:=pointcloud
```

causes two new problems:

1. **Depth rate drops from ~30 Hz to ~10.5 Hz** — likely CPU/processing
   backpressure from point cloud generation running on the Jetson's CPU,
   not another hardware fault.
2. **`/camera/depth/color/points` never publishes.** The log shows:
   ```
   [ WARN] No stream match for pointcloud chosen texture Process - Color
   ```
   This is the pointcloud filter failing to synchronize/match depth and
   color frames for texturing — likely needs `enable_sync:=true` to fix,
   which hasn't been tested yet. **Not yet resolved** — see Next Steps in
   the main `README.md`.

## Verification Commands Used

```bash
source /opt/ros/noetic/setup.bash
roslaunch realsense2_camera rs_camera.launch initial_reset:=true enable_infra1:=false enable_infra2:=false
```
In a second session:
```bash
source /opt/ros/noetic/setup.bash
rostopic hz /camera/color/image_raw
rostopic hz /camera/depth/image_rect_raw
```

## Diagnostic Tips for Future Sessions

- **`ros-noetic-realsense2-camera`'s `output="screen"` launch config means
  console-only messages (librealsense's own internal logger — the
  `WARNING`/`ERROR` lines with a raw timestamp prefix like
  `02/01 15:29:18,088`) are never written to any log file.** They only
  exist in the live terminal. To capture them for later analysis, launch
  with explicit redirection instead of relying on ROS's log directory:
  ```bash
  nohup roslaunch realsense2_camera rs_camera.launch ... > /tmp/rs_debug.log 2>&1 &
  ```
- **The dock's system clock is unreliable** (no internet → no NTP sync,
  apparent default/reset date around `2023-11-07`). Do **not** use
  `ls -t`/`ls -dt` on `~/.ros/log/` to find "the most recent" run — sort
  order will be wrong. Instead, match the log directory to the actual
  running process:
  ```bash
  ps aux | grep realsense2_camera   # shows __log:=/home/unitree/.ros/log/<uuid>/... in the command line
  ```
  or use ROS's own convenience symlink: `~/.ros/log/latest`.
- **`rosout.log` only captures messages sent via ROS's own logging macros
  (`ROS_INFO`/`ROS_WARN`/`ROS_ERROR`)** — it will show high-level driver
  messages (`depth stream is enabled`, `RealSense Node Is Up!`,
  `Hardware Notification: ...`) but **not** librealsense's own internal
  USB/hardware logger output (the `control_transfer`/`hwmon` lines).
