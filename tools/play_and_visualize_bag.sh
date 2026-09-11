#!/usr/bin/env bash
#
# play_and_visualize_bag.sh
#
# Runs ON THE PC. Plays back a recorded rosbag (see README.md Section 10)
# and auto-launches RViz2 to visualize it, in one command -- no dock/container
# involved, since the bag only contains standard sensor_msgs topics.
#
# "Downsampling": color is already recorded compressed (see
# record_sensors_bag.sh) so it's light by default. The lidar point cloud
# (~61k points/message) and raw depth are the remaining heavy topics --
# there's no cheap point-cloud voxel-downsampling tool installed on this PC
# (would need ros-humble-pcl-ros, not installed, needs sudo), so this script
# instead plays the bag back at a REDUCED RATE by default (-r flag, default
# 0.5x) to ease the per-second data volume RViz has to render. This is a
# real trade-off -- slower-than-real-time playback -- not a free win; use
# -r 1.0 for real-time if your machine keeps up fine.
#
# Isolates onto ROS_DOMAIN_ID=99 automatically (same as the manual
# instructions in README.md Section 10) -- this is NOT optional: leaving it
# at the default (0) means RViz will show the LIVE container's data instead
# of (or mixed with) the bag's, if the container happens to be running at
# the same time. See README.md Section 10 for the full explanation.
#
# Usage:
#   ./play_and_visualize_bag.sh <bag_path> [-r RATE] [-d DOMAIN_ID]
#
#   <bag_path>    Path to the bag directory (from `scp`, see README.md Section 10).
#   -r RATE       Playback rate multiplier. Default: 0.5 (half speed, eases
#                 lidar/RViz render load). Use 1.0 for real-time.
#   -d DOMAIN_ID  ROS domain to isolate onto. Default: 99.
#
# Ctrl+C, or closing the RViz2 window, stops both the player and RViz.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RATE="0.5"
DOMAIN_ID="99"

if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  sed -n '3,32p' "$0"
  exit 1
fi
BAG_PATH="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r) RATE="$2"; shift 2 ;;
    -d) DOMAIN_ID="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -d "$BAG_PATH" ]]; then
  echo "ERROR: bag directory not found: $BAG_PATH" >&2
  exit 1
fi

echo "=== Playing back: $BAG_PATH ==="
echo "Rate       : ${RATE}x $( [[ "$RATE" != "1.0" && "$RATE" != "1" ]] && echo "(slower than real-time -- eases lidar/RViz render load)" )"
echo "ROS_DOMAIN_ID: $DOMAIN_ID (isolated -- see script header for why this matters)"
echo

set +u
source /opt/ros/humble/setup.bash
set -u
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_DOMAIN_ID="$DOMAIN_ID"

PLAYER_PID=""
RVIZ_PID=""

cleanup() {
  echo
  echo "=== Cleaning up ==="
  # Both processes are backgrounded (not exec'd in the foreground) specifically
  # so this trap can always run, even if rviz2 hangs on shutdown instead of
  # exiting promptly on SIGINT/SIGTERM (observed intermittently) -- a foreground
  # `rviz2 ...` as the script's last command would block bash inside that exec
  # forever in that case, and this trap would never get a chance to fire.
  for pid in "$PLAYER_PID" "$RVIZ_PID"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
  done
  sleep 1
  # Force-kill anything still alive after the grace period above.
  for pid in "$PLAYER_PID" "$RVIZ_PID"; do
    [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null
  done
  # `ros2 bag play` is its own binary (not a `ros2 run` Python-wrapper child
  # like domain_bridge/image_transport elsewhere in this repo), but kill by
  # pattern too as a safety net in case that ever changes.
  pkill -9 -f "ros2 bag play.*$BAG_PATH" 2>/dev/null
  echo "Done."
}
trap cleanup EXIT INT TERM

ros2 bag play --loop --rate "$RATE" "$BAG_PATH" &
PLAYER_PID=$!
sleep 2

rviz2 -d "$SCRIPT_DIR/go2_sensors_playback.rviz" &
RVIZ_PID=$!

wait -n "$PLAYER_PID" "$RVIZ_PID"
# Either process exiting (rviz2 window closed, bag player crashed, etc.)
# triggers cleanup of both via the EXIT trap above.
