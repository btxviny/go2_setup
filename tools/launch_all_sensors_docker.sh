#!/usr/bin/env bash
#
# launch_all_sensors_docker.sh
#
# Launches RealSense D435i (color + depth) + the Hesai PandarXT-16 LiDAR via
# the go2-sensors-humble Docker container (~/go2_sensors_docker on the dock,
# see AGENTS.md) and opens RViz2 directly on the robot's own ROS2 domain (0)
# -- no domain_bridge, no isolated domain, no bridge whitelist. Simpler, at
# the cost of RViz2's own DDS participant now sitting on the same domain as
# the robot's other traffic (see AGENTS.md for the tradeoff).
#
# Only cares about RealSense + Hesai -- the robot's built-in L1 LiDAR
# (/utlidar/cloud) is not otherwise affected either way. Fixed Frame is set
# directly to Hesai's own frame (rslidar, set via frame_id:=rslidar in
# start.sh), so no static TF is needed.
#
# ============================ ARCHITECTURE ============================
#
#   DOCK                                          PC (this machine)
#   └── docker compose (go2-sensors-humble)     ├── rviz2 (ROS_DOMAIN_ID=0)
#         ├── realsense2_camera  (ROS2/humble)     │   subscribes directly
#         └── hesai_lidar_node   (ROS2/humble)     │
#             network_mode: host, ROS_DOMAIN_ID=0
#
# The container's network_mode: host + ROS_DOMAIN_ID=0 means both RealSense
# and Hesai are native ROS2 nodes sitting directly on the robot's own domain
# 0. RViz2 on the PC now joins that same domain 0 directly instead of going
# through a bridge.
#
# --- Ethernet vs WiFi ---
# The dock is dual-homed (see README.md Section 2 / AGENTS.md): eth0 on the
# Go2 robot subnet (192.168.123.0/24, always available when the RJ45 cable is
# plugged in), and wlan0 on whatever WiFi network this PC is also on (DHCP
# IP -- resolved via mDNS as ubuntu.local rather than a hardcoded IP, since
# DHCP leases can change). Pick which link to use with --ethernet (default)
# or --wifi. This selects both which address this script SSHes to AND which
# of this PC's own network interfaces RViz2's CycloneDDS binds to for
# talking to the dock (auto-detected per mode, or overridden with -i IFACE).
#
# Both modes now use a plain, static, checked-in CycloneDDS config on both
# ends (cyclone_ethernet.xml/cyclone_wifi.xml here, and the matching
# go2_sensors_docker/config/cyclonedds_{ethernet,wifi}.xml on the dock) --
# no per-run temp files, no IP resolution/generation. This used to generate
# a unicast <Peer>/<ParticipantIndex> config for --wifi, working around an
# assumed multicast block on this WiFi network -- a live bidirectional
# multicast probe (Sept 2026) proved that assumption wrong (multicast SPDP
# works fine both ways here), so that generation step was removed entirely.
# See docs/networking.md for the full writeup, including why WiFi *data
# throughput* for large messages is still a separate, unsolved problem even
# though discovery was never actually broken.
#
# A custom -i IFACE (an interface name that doesn't match either static
# file) still falls back to generating a minimal temp config -- just the
# interface name, no peers/participant index needed anymore either.
#
# Confirmed topic names/types actually published by the container (verified via
# `docker exec go2-sensors-humble ros2 topic list -t`):
#   /rslidar_points                       [sensor_msgs/msg/PointCloud2]   (Hesai, publish_type=both)
#   /camera/camera/color/image_raw        [sensor_msgs/msg/Image]
#   /camera/camera/depth/image_rect_raw   [sensor_msgs/msg/Image]
# (the doubled "camera/camera" namespace is realsense-ros's default
# camera_name=camera_namespace=camera behavior on this ros2-master branch.)
#
# Note: without domain_bridge there's no per-topic QoS override anymore --
# RViz subscribes with whatever QoS each publisher actually uses. The
# HesaiRslidarCloud display in go2_sensors_docker.rviz is explicitly set to
# Reliable QoS (matching the Hesai driver's own publisher) -- large
# messages like /rslidar_points get fragmented into ~200 UDP packets sent
# in a few-millisecond burst, and a Best Effort reader silently drops the
# *entire* sample if even one fragment is lost in that burst (no retry
# mechanism). Reliable lets the reader NACK and recover the missing
# fragment(s) instead. See docs/networking.md's "Known issue" section for
# the full root-cause writeup. This helps a lot over Ethernet; over WiFi,
# throughput for large messages is still poor even with Reliable QoS
# recovering some of them (see AGENTS.md item 7 / wifi_dds_data_loss_findings.md).
#
# Prerequisites (one-time, not handled by this script):
#   1. SSH key-based auth to the dock:
#        ssh-copy-id unitree@192.168.123.18
#   2. The go2-sensors-humble image built and ~/go2_sensors_docker/
#      (Dockerfile, docker-compose.yml, start.sh) present on the dock -- see
#      AGENTS.md "RealSense on ROS2 Humble (resolved)".
#   3. tools/cyclone_ethernet.xml, tools/cyclone_wifi.xml, and
#      go2_sensors_docker.rviz present (created alongside this script).
#   4. ros-humble-image-transport-plugins installed on this PC (RViz's color
#      display uses compressed transport -- see README.md Section 9).
#
# Usage:
#   ./launch_all_sensors_docker.sh [--ethernet | --wifi] [-i IFACE]
#
#   --ethernet   Use the dock's Ethernet link (192.168.123.18). Default.
#   --wifi       Use the dock's WiFi link (unitree@ubuntu.local, via mDNS --
#                robust to the WiFi IP changing over DHCP).
#   -i IFACE     Override this PC's own network interface for DDS discovery
#                (default: enp3s0 for --ethernet, auto-detected active WiFi
#                device for --wifi).
#
# Ctrl+C (or normal exit) runs `docker compose down` on the dock. rviz2
# exiting normally also triggers cleanup.
#
set -uo pipefail

COMPOSE_DIR="go2_sensors_docker"
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

for f in cyclone_ethernet.xml cyclone_wifi.xml go2_sensors_docker.rviz; do
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

echo "=== Go2 sensor launch (Docker variant: RealSense + Hesai only, domain 0) ==="
echo "Mode       : $MODE"
echo "Dock       : $DOCK_HOST"
echo "PC iface   : $IFACE"
echo "Sensors    : RealSense (color+depth) + Hesai PandarXT-16"
echo "Container  : go2-sensors-humble (~/$COMPOSE_DIR)"
echo

# --- Cleanup (dock-side container + generated temp config, if any) ---
DOMAIN0_CONFIG=""
DOMAIN0_CONFIG_IS_TEMP=""

cleanup() {
  echo
  echo "=== Cleaning up ==="
  # Only remove DOMAIN0_CONFIG if WE generated it as a temp file (a custom
  # -i override not matching either static file). In the normal case it
  # points at the permanent, git-tracked cyclone_ethernet.xml/cyclone_wifi.xml.
  if [[ -n "$DOMAIN0_CONFIG_IS_TEMP" && -f "$DOMAIN0_CONFIG" ]]; then
    rm -f "$DOMAIN0_CONFIG"
  fi
  echo "Stopping the dock-side container (docker compose down)..."
  ssh -o ConnectTimeout=5 "$DOCK_HOST" "cd ~/$COMPOSE_DIR && docker compose down" 2>/dev/null
  echo "Done."
}
trap cleanup EXIT INT TERM

# --- 1. (Re)start the container fresh on the dock ---
# Selects the matching static container-side CycloneDDS config
# (go2_sensors_docker/config/cyclonedds_ethernet.xml or cyclonedds_wifi.xml)
# via CONTAINER_CYCLONEDDS_URI -- both are plain, single-interface, no
# unicast peers needed (see the architecture comment above for why).
if [[ "$MODE" == "wifi" ]]; then
  CONTAINER_CYCLONEDDS_URI_ENV="CONTAINER_CYCLONEDDS_URI=file:///config/cyclonedds_wifi.xml "
else
  CONTAINER_CYCLONEDDS_URI_ENV=""
fi

echo "[1/3] Starting go2-sensors-humble via docker compose on the dock..."
ssh "$DOCK_HOST" "cd ~/$COMPOSE_DIR && docker compose down 2>/dev/null; ${CONTAINER_CYCLONEDDS_URI_ENV}docker compose up -d"

# --- 2. Wait for both drivers to actually be publishing ---
echo "[2/3] Waiting for RealSense + Hesai topics to appear..."
ready=0
for attempt in $(seq 1 20); do
  topics=$(ssh -o ConnectTimeout=5 "$DOCK_HOST" \
    "docker exec go2-sensors-humble bash -c 'source /opt/ros/humble/install/setup.bash && source /opt/realsense_ws/install/setup.bash && ros2 topic list' 2>/dev/null")
  if grep -q "^/rslidar_points$" <<<"$topics" && grep -q "^/camera/camera/color/image_raw$" <<<"$topics"; then
    ready=1
    break
  fi
  sleep 2
done
if [[ "$ready" -ne 1 ]]; then
  echo "  WARNING: didn't confirm both drivers publishing after 40s -- continuing anyway." >&2
  echo "  Check with: ssh $DOCK_HOST 'docker logs --tail 50 go2-sensors-humble'" >&2
else
  echo "  Both drivers are publishing."
fi

# --- 3. RViz2 directly on domain 0 (no bridge) ---
# Picks the matching static PC-side config for the selected mode/interface.
# A custom -i IFACE that doesn't match either default interface name falls
# back to a minimal generated temp config (just the interface name -- no
# peers/participant index needed).
echo "[3/3] Launching RViz2 (ROS_DOMAIN_ID=0, $IFACE, RealSense + Hesai topics)..."
if [[ "$MODE" == "ethernet" && "$IFACE" == "enp3s0" ]]; then
  DOMAIN0_CONFIG="$SCRIPT_DIR/cyclone_ethernet.xml"
elif [[ "$MODE" == "wifi" && "$IFACE" == "wlp2s0" ]]; then
  DOMAIN0_CONFIG="$SCRIPT_DIR/cyclone_wifi.xml"
else
  DOMAIN0_CONFIG="$(mktemp /tmp/cyclone_domain0_XXXXXX.xml)"
  DOMAIN0_CONFIG_IS_TEMP=1
  echo "  Custom interface ($IFACE) -- generating a minimal temp config for it"
  cat > "$DOMAIN0_CONFIG" <<EOF
<?xml version="1.0" encoding="UTF-8" ?>
<CycloneDDS xmlns="https://cdds.io/config">
  <Domain id="0">
    <General>
      <Interfaces>
        <NetworkInterface name="$IFACE" />
      </Interfaces>
      <MaxMessageSize>1400B</MaxMessageSize>
      <FragmentSize>1300B</FragmentSize>
    </General>
  </Domain>
</CycloneDDS>
EOF
fi

# Source the same env vars ros2_env.sh sets (single source of truth for
# RMW_IMPLEMENTATION/ROS_DOMAIN_ID/CYCLONEDDS_URI), then override
# CYCLONEDDS_URI to whichever static/generated config this run picked.
set +u
source "$SCRIPT_DIR/ros2_env.sh"
set -u
export CYCLONEDDS_URI="file://$DOMAIN0_CONFIG"

rviz2 -d "$SCRIPT_DIR/go2_sensors_docker.rviz"

# When rviz2 exits (window closed), the trap fires automatically and cleans up.
