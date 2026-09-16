#!/usr/bin/env bash
#
# record_sensors_bag_pc.sh
#
# Runs ON THIS PC (not the dock). Records the same three core sensor topics
# as go2_sensors_docker/record_sensors_bag.sh, but directly from the
# robot's own domain 0 -- i.e. whatever launch_all_sensors_docker.sh has
# RViz2 (and this PC) currently subscribed to, not a bridged copy.
#
# Requires launch_all_sensors_docker.sh already running (the dock's
# go2-sensors-humble container up, and this PC's DDS participant already
# discovering it on domain 0) -- this script does NOT start that for you,
# and does NOT touch the dock at all.
#
# Topics recorded (same three as the dock-side script, see its header for
# the color-compressed / depth-raw rationale -- unchanged here):
#   /camera/camera/color/image_raw/compressed   sensor_msgs/msg/CompressedImage
#   /camera/camera/depth/image_rect_raw         sensor_msgs/msg/Image
#   /rslidar_points                             sensor_msgs/msg/PointCloud2
#
# Usage:
#   cd ~/go2_guide_docs/tools
#   ./record_sensors_bag_pc.sh [bag_name]
#
#   bag_name   Optional. Defaults to a UTC timestamp, e.g. sensors_20260911_142530.
#              Saved to ~/rosbags/<bag_name>/ on THIS PC (a different ~/rosbags
#              than the dock's -- no scp needed, it's already local).
#
# Ctrl+C stops the recording cleanly (ros2 bag record finalizes the bag on
# SIGINT) -- don't kill -9 it, that can leave the bag's metadata.yaml missing
# or corrupt.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPICS=(
  /camera/camera/color/image_raw/compressed
  /camera/camera/depth/image_rect_raw
  /rslidar_points
)
BAG_NAME="${1:-sensors_$(date -u +%Y%m%d_%H%M%S)}"
BAG_DIR="$HOME/rosbags/$BAG_NAME"

mkdir -p "$HOME/rosbags"

echo "=== Recording rosbag (from domain 0): $BAG_NAME ==="
echo "Topics: ${TOPICS[*]}"
echo "Saving to: $BAG_DIR"
echo "Press Ctrl+C to stop recording."
echo

set +u
source /opt/ros/humble/setup.bash
set -u
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export CYCLONEDDS_URI="file://$SCRIPT_DIR/cyclone_ethernet.xml"
export ROS_DOMAIN_ID=0

ros2 bag record -o "$BAG_DIR" "${TOPICS[@]}"

echo
echo "=== Recording finished ==="
echo "Bag saved at: $BAG_DIR"
