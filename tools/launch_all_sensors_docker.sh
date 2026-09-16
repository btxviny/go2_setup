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
# Confirmed topic names/types actually published by the container (verified via
# `docker exec go2-sensors-humble ros2 topic list -t`):
#   /rslidar_points                       [sensor_msgs/msg/PointCloud2]   (Hesai, publish_type=both)
#   /camera/camera/color/image_raw        [sensor_msgs/msg/Image]
#   /camera/camera/depth/image_rect_raw   [sensor_msgs/msg/Image]
# (the doubled "camera/camera" namespace is realsense-ros's default
# camera_name=camera_namespace=camera behavior on this ros2-master branch.)
#
# Note: without domain_bridge there's no per-topic QoS override anymore --
# RViz subscribes with whatever QoS each publisher actually uses (Reliable
# by default). On --wifi this reintroduces the large-message stall risk that
# forcing best_effort used to work around (see AGENTS.md item 7 /
# wifi_dds_data_loss_findings.md) -- --wifi live visualization is not
# expected to be reliable.
#
# Prerequisites (one-time, not handled by this script):
#   1. SSH key-based auth to the dock:
#        ssh-copy-id unitree@192.168.123.18
#   2. The go2-sensors-humble image built and ~/go2_sensors_docker/
#      (Dockerfile, docker-compose.yml, start.sh) present on the dock -- see
#      AGENTS.md "RealSense on ROS2 Humble (resolved)".
#   3. tools/cyclone_ethernet.xml and go2_sensors_docker.rviz present
#      (created alongside this script).
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

for f in cyclone_ethernet.xml go2_sensors_docker.rviz; do
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

# --- Cleanup (dock-side container + generated temp config) ---
DOMAIN0_CONFIG=""
DOMAIN0_CONFIG_IS_TEMP=""

cleanup() {
  echo
  echo "=== Cleaning up ==="
  # Only remove DOMAIN0_CONFIG if WE generated it as a temp file (--wifi or a
  # custom -i). In the --ethernet default case it points at the permanent,
  # git-tracked tools/cyclone_ethernet.xml.
  if [[ -n "$DOMAIN0_CONFIG_IS_TEMP" && -f "$DOMAIN0_CONFIG" ]]; then
    rm -f "$DOMAIN0_CONFIG"
  fi
  echo "Stopping the dock-side container (docker compose down)..."
  ssh -o ConnectTimeout=5 "$DOCK_HOST" "cd ~/$COMPOSE_DIR && docker compose down" 2>/dev/null
  echo "Done."
}
trap cleanup EXIT INT TERM

# --- 1. (Re)start the container fresh on the dock ---
# --wifi: the container's CycloneDDS also needs a unicast peer pointed at
# this PC, since multicast SPDP discovery doesn't work on this WiFi network
# (AP/client isolation) -- otherwise its two DDS participants (RealSense +
# Hesai) never see RViz2's participant on the PC. Generated fresh per run
# since both IPs can change over DHCP.
CONTAINER_CYCLONEDDS_URI_ENV=""
if [[ "$MODE" == "wifi" ]]; then
  PC_WIFI_IP="$(ip -4 -br addr show "$IFACE" 2>/dev/null | awk '{print $3}' | cut -d/ -f1)"
  if [[ -n "$PC_WIFI_IP" ]]; then
    echo "  This PC's WiFi IP ($IFACE): $PC_WIFI_IP -- writing it as a unicast discovery peer for the container"
    ssh -o ConnectTimeout=5 "$DOCK_HOST" "mkdir -p ~/$COMPOSE_DIR/config && cat > ~/$COMPOSE_DIR/config/cyclonedds_wifi_discovery.xml" <<EOF
<?xml version="1.0" encoding="UTF-8" ?>
<CycloneDDS xmlns="https://cdds.io/config">
  <Domain id="0">
    <General>
      <Interfaces>
        <NetworkInterface name="wlan0" />
      </Interfaces>
    </General>
    <Discovery>
      <Peers>
        <Peer address="$PC_WIFI_IP" />
      </Peers>
      <ParticipantIndex>auto</ParticipantIndex>
    </Discovery>
  </Domain>
</CycloneDDS>
EOF
    CONTAINER_CYCLONEDDS_URI_ENV="CONTAINER_CYCLONEDDS_URI=file:///config/cyclonedds_wifi_discovery.xml "
  else
    echo "  WARNING: couldn't determine this PC's IP on $IFACE -- container will fall back to multicast-only discovery, which is known not to work on this WiFi network." >&2
  fi
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
# The checked-in tools/cyclone_ethernet.xml only works for the default
# --ethernet interface. For --wifi (or a custom -i override), generate a
# temp config with the actual interface name, plus (for --wifi) a unicast
# <Peers> entry pointing at the dock's WiFi IP and an explicit
# <ParticipantIndex>0</ParticipantIndex> -- needed because this WiFi network
# blocks multicast SPDP discovery between wireless clients (see AGENTS.md
# item 7 / wifi_dds_data_loss_findings.md for the full story, including why
# live data flow over --wifi is still unreliable even with discovery
# working).
echo "[3/3] Launching RViz2 (ROS_DOMAIN_ID=0, $IFACE, RealSense + Hesai topics)..."
if [[ "$MODE" == "ethernet" && "$IFACE" == "enp3s0" ]]; then
  DOMAIN0_CONFIG="$SCRIPT_DIR/cyclone_ethernet.xml"
else
  DOMAIN0_CONFIG="$(mktemp /tmp/cyclone_domain0_XXXXXX.xml)"
  DOMAIN0_CONFIG_IS_TEMP=1

  PEERS_BLOCK=""
  if [[ "$MODE" == "wifi" ]]; then
    DOCK_WIFI_IP="$(ssh -o ConnectTimeout=5 "$DOCK_HOST" "ip -4 -br addr show wlan0 | awk '{print \$3}' | cut -d/ -f1" 2>/dev/null)"
    if [[ -n "$DOCK_WIFI_IP" ]]; then
      echo "  Dock WiFi IP (resolved fresh via SSH): $DOCK_WIFI_IP -- adding as a unicast discovery peer"
      PEERS_BLOCK="    <Discovery>
      <Peers>
        <Peer address=\"$DOCK_WIFI_IP\" />
      </Peers>
      <ParticipantIndex>0</ParticipantIndex>
    </Discovery>
"
    else
      echo "  WARNING: couldn't resolve the dock's WiFi IP via SSH -- falling back to multicast-only discovery, which is known not to work on this WiFi network." >&2
    fi
  fi

  cat > "$DOMAIN0_CONFIG" <<EOF
<?xml version="1.0" encoding="UTF-8" ?>
<CycloneDDS xmlns="https://cdds.io/config">
  <Domain id="0">
    <General>
      <Interfaces>
        <NetworkInterface name="$IFACE" />
      </Interfaces>
    </General>
${PEERS_BLOCK}  </Domain>
</CycloneDDS>
EOF
fi

set +u
source /opt/ros/humble/setup.bash
set -u
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
CYCLONEDDS_URI="file://$DOMAIN0_CONFIG" \
  ROS_DOMAIN_ID=0 \
  rviz2 -d "$SCRIPT_DIR/go2_sensors_docker.rviz"

# When rviz2 exits (window closed), the trap fires automatically and cleans up.
