#!/bin/bash
# Source this (do NOT execute) before running any manual `ros2` CLI command
# (topic list/echo/hz, etc.) against the Go2 setup over Ethernet:
#
#   source tools/ros2_env.sh
#
# Sets the three env vars this project needs so DDS discovery + data flow
# actually work (see AGENTS.md's "Common shell pitfalls" for what happens if
# any of these are missing/wrong). launch_all_sensors_docker.sh also sources
# this same script itself (single source of truth), then overrides
# CYCLONEDDS_URI afterward for --wifi/custom -i runs that need a generated
# temp config instead of the checked-in cyclone_ethernet.xml.
#
# For --wifi manual CLI use, don't rely on this script's CYCLONEDDS_URI:
# point it at the temp config launch_all_sensors_docker.sh --wifi prints on
# startup instead (the static cyclone_ethernet.xml here won't discover
# anything over WiFi).
#
# Also forces QT_QPA_PLATFORM=xcb (X11/XWayland) for any Qt-based GUI
# launched in this shell (rviz2, rqt, etc.) on native Wayland GNOME sessions.
# Confirmed root cause (Sept 2026) of RViz2 rendering a genuinely frozen
# point cloud despite fresh, verifiably-unique data continuously arriving
# over DDS (confirmed via packet capture + per-message data hashing while
# RViz2 was actively subscribed) -- RViz2's OpenGL rendering under native
# Wayland can get stuck showing a stale frame even though the underlying
# ROS2 subscription callbacks keep firing normally. Forcing XWayland (xcb)
# instead of native Wayland avoids this class of GL swap-buffer/compositor
# bug. Only applied if a Wayland session is actually detected, so this is a
# no-op on X11-native machines.

# Guard against being run instead of sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: this script must be sourced, not executed:" >&2
    echo "  source ${BASH_SOURCE[0]}" >&2
    exit 1
fi

source /opt/ros/humble/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_DOMAIN_ID=0
unset CYCLONEDDS_URI
export CYCLONEDDS_URI="file://$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cyclone_ethernet.xml"

if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    export QT_QPA_PLATFORM=xcb
fi

echo "ros2_env.sh: RMW_IMPLEMENTATION=$RMW_IMPLEMENTATION ROS_DOMAIN_ID=$ROS_DOMAIN_ID CYCLONEDDS_URI=$CYCLONEDDS_URI QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-<unset>}"
