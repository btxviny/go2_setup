#!/usr/bin/env bash
#
# launch_all_sensors_docker.sh
#
# Launches RealSense D435i (color + depth) + the Hesai PandarXT-16 LiDAR and
# brings them into a single isolated ROS2 domain (42) on this PC for
# visualization in RViz2, via the go2-realsense-humble Docker container
# (~/realsense_humble_docker on the dock, see AGENTS.md).
#
# Only cares about RealSense + Hesai -- the robot's built-in L1 LiDAR
# (/utlidar/cloud) is deliberately not bridged. Fixed Frame is set directly to
# Hesai's own frame (rslidar, set via frame_id:=rslidar in start.sh), so no
# static TF is needed either.
#
# ============================ ARCHITECTURE ============================
#
#   DOCK                                          PC (this machine)
#   └── docker compose (go2-realsense-humble)     ├── domain_bridge
#         ├── realsense2_camera  (ROS2/humble)     │   domain 0 -> 42 (lo)
#         └── hesai_lidar_node   (ROS2/humble)     │   (RealSense + Hesai topics,
#             network_mode: host, ROS_DOMAIN_ID=0  │    see bridge_docker.yaml)
#                                                   └── rviz2 (domain 42 only)
#
# The container's network_mode: host + ROS_DOMAIN_ID=0 means BOTH RealSense
# and Hesai are native ROS2 nodes sitting directly on the robot's own domain
# 0. There's no ROS1 anywhere in this pipeline. The only PC-side job is a
# domain_bridge (0 -> 42) -- see tools/bridge_docker.yaml.
#
# --- Ethernet vs WiFi ---
# The dock is dual-homed (see README.md Section 2 / AGENTS.md): eth0 on the
# Go2 robot subnet (192.168.123.0/24, always available when the RJ45 cable is
# plugged in), and wlan0 on whatever WiFi network this PC is also on (DHCP
# IP -- resolved via mDNS as ubuntu.local rather than a hardcoded IP, since
# DHCP leases can change). Pick which link to use with --ethernet (default)
# or --wifi. This selects both which address this script SSHes to AND which
# of this PC's own network interfaces the local domain_bridge binds to for
# talking to the dock (auto-detected per mode, or overridden with -i IFACE).
#
# Confirmed topic names/types actually published by the container (verified via
# `docker exec go2-realsense-humble ros2 topic list -t`):
#   /rslidar_points                       [sensor_msgs/msg/PointCloud2]   (Hesai, publish_type=both)
#   /camera/camera/color/image_raw        [sensor_msgs/msg/Image]
#   /camera/camera/depth/image_rect_raw   [sensor_msgs/msg/Image]
# (the doubled "camera/camera" namespace is realsense-ros's default
# camera_name=camera_namespace=camera behavior on this ros2-master branch.)
#
# Prerequisites (one-time, not handled by this script):
#   1. SSH key-based auth to the dock:
#        ssh-copy-id unitree@192.168.123.18
#   2. The go2-realsense-humble image built and ~/realsense_humble_docker/
#      (Dockerfile, docker-compose.yml, start.sh) present on the dock -- see
#      AGENTS.md "RealSense on ROS2 Humble (resolved)".
#   3. tools/cyclone_domain0_enp3s0.xml, tools/cyclone_domain42_lo.xml,
#      tools/bridge_docker.yaml, go2_sensors_docker.rviz all present (created
#      alongside this script).
#   4. ros-humble-image-transport-plugins installed on this PC (RViz's color
#      display uses compressed transport -- see README.md Section 9).
#
# Usage:
#   ./launch_all_sensors_docker.sh [--ethernet | --wifi] [-i IFACE]
#
#   --ethernet   Use the dock's Ethernet link (192.168.123.18). Default.
#   --wifi       Use the dock's WiFi link (unitree@ubuntu.local, via mDNS --
#                robust to the WiFi IP changing over DHCP).
#   -i IFACE     Override this PC's own network interface for the DDS bridge
#                (default: enp3s0 for --ethernet, auto-detected active WiFi
#                device for --wifi).
#
# Ctrl+C (or normal exit) runs `docker compose down` on the dock and cleans up
# the local domain_bridge. rviz2 exiting normally also triggers cleanup.
#
set -uo pipefail

COMPOSE_DIR="realsense_humble_docker"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="ethernet"
IFACE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ethernet) MODE="ethernet"; shift ;;
    --wifi) MODE="wifi"; shift ;;
    -i) IFACE="$2"; shift 2 ;;
    -h|--help) sed -n '3,66p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ "$MODE" == "ethernet" ]]; then
  DOCK_HOST="unitree@192.168.123.18"
  [[ -z "$IFACE" ]] && IFACE="enp3s0"
else
  DOCK_HOST="unitree@ubuntu.local"
  if [[ -z "$IFACE" ]]; then
    IFACE="$(nmcli -t -f device,type,state device status 2>/dev/null | grep ':wifi:connected$' | head -1 | cut -d: -f1)"
    if [[ -z "$IFACE" ]]; then
      echo "ERROR: --wifi given but couldn't auto-detect this PC's active WiFi interface." >&2
      echo "This PC doesn't appear to be connected to WiFi right now -- connect first, or pass -i IFACE explicitly." >&2
      exit 1
    fi
  fi
fi

# --- Sanity checks ---
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$DOCK_HOST" true 2>/dev/null; then
  echo "ERROR: can't SSH to $DOCK_HOST (mode: $MODE)." >&2
  if [[ "$MODE" == "ethernet" ]]; then
    echo "Is the RJ45 cable plugged in? Try --wifi instead if the dock is on WiFi." >&2
  else
    echo "Is the dock's WiFi adapter connected? Check: ssh unitree@192.168.123.18 'nmcli device status'" >&2
    echo "(requires the Ethernet link to check, if WiFi itself is the problem)" >&2
  fi
  echo "If this is the very first connection, run:  ssh-copy-id ${DOCK_HOST}" >&2
  exit 1
fi

for f in cyclone_domain0_enp3s0.xml cyclone_domain42_lo.xml bridge_docker.yaml go2_sensors_docker.rviz; do
  if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
    echo "ERROR: missing $SCRIPT_DIR/$f" >&2
    exit 1
  fi
done

if ! ssh -o ConnectTimeout=5 "$DOCK_HOST" "test -f ~/$COMPOSE_DIR/docker-compose.yml" 2>/dev/null; then
  echo "ERROR: ~/$COMPOSE_DIR/docker-compose.yml not found on the dock." >&2
  echo "See AGENTS.md 'RealSense on ROS2 Humble (resolved)' for how it's built." >&2
  exit 1
fi

echo "=== Go2 sensor launch (Docker variant: RealSense + Hesai only) ==="
echo "Mode       : $MODE"
echo "Dock       : $DOCK_HOST"
echo "PC iface   : $IFACE"
echo "Sensors    : RealSense (color+depth) + Hesai PandarXT-16"
echo "Container  : go2-realsense-humble (~/$COMPOSE_DIR)"
echo

# --- Cleanup (dock-side container + local domain_bridge + generated temp config) ---
DOMAIN_BRIDGE_PID=""
DOMAIN0_CONFIG=""

cleanup() {
  echo
  echo "=== Cleaning up ==="
  # `ros2 run <pkg> <exe> &` backgrounds the `ros2 run` Python wrapper, not the
  # actual compiled binary it execs as a child process -- killing $! alone
  # leaves domain_bridge running as an orphan. Kill both the wrapper PID and
  # the real binary by pattern to actually stop it.
  if [[ -n "$DOMAIN_BRIDGE_PID" ]]; then
    kill "$DOMAIN_BRIDGE_PID" 2>/dev/null
  fi
  pkill -f "lib/domain_bridge/domain_bridge" 2>/dev/null
  if [[ -n "$DOMAIN0_CONFIG" && -f "$DOMAIN0_CONFIG" ]]; then
    rm -f "$DOMAIN0_CONFIG"
  fi
  echo "Stopping the dock-side container (docker compose down)..."
  ssh -o ConnectTimeout=5 "$DOCK_HOST" "cd ~/$COMPOSE_DIR && docker compose down" 2>/dev/null
  echo "Done."
}
trap cleanup EXIT INT TERM

# --- 1. (Re)start the container fresh on the dock ---
echo "[1/4] Starting go2-realsense-humble via docker compose on the dock..."
ssh "$DOCK_HOST" "cd ~/$COMPOSE_DIR && docker compose down 2>/dev/null; docker compose up -d"

# --- 2. Wait for both drivers to actually be publishing ---
echo "[2/4] Waiting for RealSense + Hesai topics to appear..."
ready=0
for attempt in $(seq 1 20); do
  topics=$(ssh -o ConnectTimeout=5 "$DOCK_HOST" \
    "docker exec go2-realsense-humble bash -c 'source /opt/ros/humble/install/setup.bash && source /opt/realsense_ws/install/setup.bash && ros2 topic list' 2>/dev/null")
  if grep -q "^/rslidar_points$" <<<"$topics" && grep -q "^/camera/camera/color/image_raw$" <<<"$topics"; then
    ready=1
    break
  fi
  sleep 2
done
if [[ "$ready" -ne 1 ]]; then
  echo "  WARNING: didn't confirm both drivers publishing after 40s -- continuing anyway." >&2
  echo "  Check with: ssh $DOCK_HOST 'docker logs --tail 50 go2-realsense-humble'" >&2
else
  echo "  Both drivers are publishing."
fi

# --- 3. Local domain_bridge (domain 0 on $IFACE -> domain 42 on loopback) ---
# Pulls in Hesai (/rslidar_points) and the RealSense color/depth + camera_info
# topics, all of which live on the robot's own domain 0 via the container's
# host networking. See tools/bridge_docker.yaml for the whitelist.
#
# The checked-in tools/cyclone_domain0_enp3s0.xml only works for the default
# --ethernet interface (enp3s0 hardcoded in the file). For --wifi (or a
# custom -i override), generate a temp config with the actual interface name
# instead, rather than requiring a separate static file per possible NIC name.
echo "[3/4] Starting local domain_bridge (domain 0 on $IFACE -> 42, RealSense + Hesai topics)..."
if [[ "$MODE" == "ethernet" && "$IFACE" == "enp3s0" ]]; then
  DOMAIN0_CONFIG="$SCRIPT_DIR/cyclone_domain0_enp3s0.xml"
else
  DOMAIN0_CONFIG="$(mktemp /tmp/cyclone_domain0_XXXXXX.xml)"
  cat > "$DOMAIN0_CONFIG" <<EOF
<?xml version="1.0" encoding="UTF-8" ?>
<CycloneDDS xmlns="https://cdds.io/config">
  <Domain>
    <General>
      <NetworkInterfaceAddress>$IFACE</NetworkInterfaceAddress>
    </General>
  </Domain>
</CycloneDDS>
EOF
fi
set +u
source /opt/ros/humble/setup.bash
set -u
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
CYCLONEDDS_URI="file://$DOMAIN0_CONFIG" \
  ros2 run domain_bridge domain_bridge "$SCRIPT_DIR/bridge_docker.yaml" &
DOMAIN_BRIDGE_PID=$!
sleep 3

# --- 4. RViz2 (domain 42 only) ---
echo "[4/4] Launching RViz2 (domain 42, isolated from the robot's own domain 0)..."
CYCLONEDDS_URI="file://$SCRIPT_DIR/cyclone_domain42_lo.xml" \
  ROS_DOMAIN_ID=42 \
  rviz2 -d "$SCRIPT_DIR/go2_sensors_docker.rviz"

# When rviz2 exits (window closed), the trap fires automatically and cleans up.
