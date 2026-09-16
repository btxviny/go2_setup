#!/usr/bin/env bash
#
# record_sensors_bag.sh
#
# Runs ON THE DOCK. Records the three core sensor topics from the running
# go2-sensors-humble container to a rosbag2 bag, saved on the dock's own
# filesystem at ~/rosbags/<name> (via the /rosbags bind mount added to
# docker-compose.yml -- NOT lost when the container stops/is recreated).
#
# Topics recorded:
#   /camera/camera/color/image_raw/compressed   sensor_msgs/msg/CompressedImage
#   /camera/camera/depth/image_rect_raw         sensor_msgs/msg/Image
#   /rslidar_points                             sensor_msgs/msg/PointCloud2
#
# Color is recorded via compressed transport (much smaller, same ~30Hz rate as
# raw -- cheap to encode). Depth stays RAW, deliberately -- its compressed
# transport (compressedDepth) was tried and confirmed to make things WORSE,
# not better: subscribing to it drags the RAW depth topic down too, from its
# normal ~24-28Hz to the same ~0.7Hz as compressedDepth itself (PNG-encoding
# 16-bit depth data is apparently too CPU-expensive on this hardware, and
# throttles the driver's whole depth pipeline, not just the compressed
# subscriber). There is no way to get full-rate raw depth AND compressedDepth
# simultaneously on this hardware -- don't re-add compressedDepth without
# expecting that tradeoff.
#
# Usage (on the dock):
#   cd ~/go2_sensors_docker
#   ./record_sensors_bag.sh [bag_name]
#
#   bag_name   Optional. Defaults to a UTC timestamp, e.g. sensors_20260911_142530.
#              Saved to ~/rosbags/<bag_name>/ (standard ros2 bag directory: a
#              metadata.yaml + one or more .db3/.mcap files).
#
# Ctrl+C stops the recording cleanly (ros2 bag record finalizes the bag on
# SIGINT) -- don't kill -9 it, that can leave the bag's metadata.yaml missing
# or corrupt.
#
# To pull the finished bag back to the controller PC, see the scp command
# printed at the end of this script, or the standalone commands in README.md.
#
set -euo pipefail

CONTAINER="go2-sensors-humble"
TOPICS=(
  /camera/camera/color/image_raw/compressed
  /camera/camera/depth/image_rect_raw
  /rslidar_points
)
BAG_NAME="${1:-sensors_$(date -u +%Y%m%d_%H%M%S)}"
HOST_BAG_DIR="$HOME/rosbags/$BAG_NAME"

if ! docker ps --filter "name=^${CONTAINER}\$" --filter status=running -q | grep -q .; then
  echo "ERROR: container '$CONTAINER' is not running. Start it first:" >&2
  echo "  cd ~/go2_sensors_docker && docker compose up -d" >&2
  exit 1
fi

mkdir -p "$HOME/rosbags"

echo "=== Recording rosbag: $BAG_NAME ==="
echo "Topics: ${TOPICS[*]}"
echo "Saving to (on the dock): $HOST_BAG_DIR"
echo "Press Ctrl+C to stop recording."
echo

docker exec -it "$CONTAINER" bash -c \
  "source /opt/ros/humble/install/setup.bash && source /opt/realsense_ws/install/setup.bash && \
   ros2 bag record -o /rosbags/$BAG_NAME ${TOPICS[*]}"

# The container runs as root, so files it writes to the /rosbags bind mount are
# root-owned on the dock's real filesystem too -- the unitree user can't manage
# or delete them without sudo (which isn't set up passwordlessly here). Fix
# ownership from inside the container, where chown doesn't need sudo.
docker exec "$CONTAINER" chown -R "$(id -u):$(id -g)" "/rosbags/$BAG_NAME"

echo
echo "=== Recording finished ==="
echo "Bag saved on the dock at: $HOST_BAG_DIR"
echo
echo "To copy it back to the controller PC, run there:"
echo "  scp -i ~/.ssh/id_ed25519 -r unitree@192.168.123.18:$HOST_BAG_DIR ."
