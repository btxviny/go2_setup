FROM dustynv/ros:humble-desktop-l4t-r35.3.1

# --- Drop the broken ROS2 apt source entirely ---
# Its signing key (F42ED6FBAB17C654) is expired, AND no ros-humble-* apt packages
# exist for focal anyway (official ROS2 Humble binaries only target Ubuntu 22.04;
# this Jetson/L4T base image builds Humble from source instead, so everything we'd
# have installed from this repo -- e.g. rmw_cyclonedds_cpp -- is already present
# under /opt/ros/humble). Just delete the stale source so `apt update` succeeds.
RUN sed -i '/packages\.ros\.org/d' /etc/apt/sources.list 2>/dev/null; \
    find /etc/apt/sources.list.d/ -iname '*.list' -exec sed -i '/packages\.ros\.org/d' {} \;

RUN apt update && apt install -y \
    build-essential cmake git \
    libssl-dev libusb-1.0-0-dev libudev-dev pkg-config \
    libgtk-3-dev libglfw3-dev libgl1-mesa-dev libglu1-mesa-dev \
    python3-colcon-common-extensions python3-rosdep \
    && rm -rf /var/lib/apt/lists/*

# --- Build librealsense2 from source (Jetson/arm64 often needs this over apt) ---
RUN mkdir -p /opt/librealsense_ws && cd /opt/librealsense_ws && \
    git clone --depth 1 -b v2.58.4 https://github.com/IntelRealSense/librealsense.git && \
    cd librealsense && \
    mkdir build && cd build && \
    cmake .. -DBUILD_EXAMPLES=false -DBUILD_GRAPHICAL_EXAMPLES=false \
             -DFORCE_RSUSB_BACKEND=true -DBUILD_WITH_CUDA=false \
             -DCMAKE_BUILD_TYPE=Release && \
    make -j$(nproc) && \
    make install && \
    ldconfig

# --- Build realsense-ros (Humble branch) from source ---
# Confirms with the official wrapper: Humble Hawksbill is a supported
# distro (see https://github.com/IntelRealSense/realsense-ros). Building
# from source avoids any apt-package/librealsense version mismatch with
# the camera's firmware.
RUN mkdir -p /opt/realsense_ws/src && cd /opt/realsense_ws/src && \
    git clone -b ros2-master https://github.com/IntelRealSense/realsense-ros.git

# --- realsense-ros needs diagnostic_updater and xacro, neither of which is in this
# base image (it's a minimal from-source Humble build, not the full desktop variant's
# apt package set) and neither is installable via apt on focal. Build them from source too. ---
RUN cd /opt/realsense_ws/src && \
    git clone -b ros2-humble https://github.com/ros/diagnostics.git && \
    git clone -b ros2 https://github.com/ros/xacro.git

# --- Hesai LiDAR driver (PandarXT-16), same package already running natively under
# ROS2 Foxy on the dock (/unitree/module/graph_pid_ws). Not a git repo there, so its
# source is vendored into the build context (hesai_lidar_src/, stale CMake build/
# artifacts excluded) rather than cloned. Non-ROS system deps per its README.
RUN apt update && apt install -y libpcl-dev libpcap-dev libboost-thread-dev libboost-system-dev \
    && rm -rf /var/lib/apt/lists/*
COPY hesai_lidar_src/ /opt/realsense_ws/src/hesai_lidar/

# rosdep's apt-based key resolution is fundamentally broken here: this image builds
# ROS2 Humble from source because no ros-humble-* apt packages exist for focal (Humble
# only ships binaries for jammy/22.04), so EVERY ROS-package rosdep key fails with
# "No definition ... for OS version [focal]" even though the package is already present
# from the base image's source build. Let rosdep fail non-fatally and let colcon build
# surface any dependency that's actually missing, rather than skip-listing keys one at a time.
RUN cd /opt/realsense_ws && \
    /bin/bash -c "source /opt/ros/humble/install/setup.bash && \
    (rosdep init || true) && (rosdep update || true) && \
    (rosdep install -i --from-path src --rosdistro humble -y --skip-keys=librealsense2 || true) && \
    colcon build --symlink-install"

# Force CycloneDDS as the RMW implementation inside the container
ENV RMW_IMPLEMENTATION=rmw_cyclonedds_cpp

# --- KISS-ICP LiDAR odometry (runs against /rslidar_points) ---
# Upstream ships both the ROS 2 wrapper (ros/) and the C++ core (cpp/) in one
# repo; ros/CMakeLists.txt builds directly against the sibling ../cpp/kiss_icp
# sources when present (no re-fetching a release tarball), so we clone the
# whole thing and let colcon discover the "kiss_icp" package at kiss-icp/ros/
# on its own (a COLCON_IGNORE in cpp/ stops colcon from also trying to treat
# the core as a second, separate plain-CMake package).
#
# Eigen3 and TBB come from apt (find_dependencies.cmake prefers system libs);
# Sophus and tsl-robin-map aren't packaged for focal at all, so CMake's
# FetchContent pulls small header-only checkouts of those two during
# `colcon build` -- needs the dock's WiFi internet uplink at build time (see
# AGENTS.md/networking.md), same as librealsense/realsense-ros's git clones
# above.
#
# Gotcha to watch for: ros/CMakeLists.txt's odometry_component target
# requests cxx_std_20. This base image's default compiler is GCC 9 (Ubuntu
# 20.04 focal), which only has partial/experimental C++20 support under
# -std=gnu++2a -- untested whether that's enough here (the wrapper source
# itself doesn't appear to use any C++20-only language features, just C++17).
# If this step fails with a C++20-related compiler error, install a newer
# compiler (`apt install gcc-10 g++-10`, available in focal's default repos)
# and set CC=gcc-10 CXX=g++-10 for just this RUN command rather than the
# whole image.
RUN apt update && apt install -y libeigen3-dev libtbb-dev && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /opt/kiss_icp_ws/src && cd /opt/kiss_icp_ws/src && \
    git clone --depth 1 -b v1.3.0 https://github.com/PRBonn/kiss-icp.git && \
    touch kiss-icp/cpp/COLCON_IGNORE

# This base image's from-source tf2_ros only ships the old-style tf2_ros/*.h
# headers (confirmed: no buffer.hpp/transform_broadcaster.hpp/etc. anywhere
# under /opt/ros/humble) -- kiss-icp's ROS wrapper includes the newer *.hpp
# names (a ROS 2 header-rename migration this from-source build predates).
# Rather than rebuilding tf2_ros from source, drop tiny shim headers into the
# ros package's own include/ dir (already on its include path via
# ros/CMakeLists.txt's target_include_directories(... PRIVATE .../include),
# which takes precedence over tf2_ros's own installed include dir).
RUN mkdir -p /opt/kiss_icp_ws/src/kiss-icp/ros/include/tf2_ros && \
    for h in buffer transform_broadcaster transform_listener static_transform_broadcaster; do \
      printf '#pragma once\n#include "tf2_ros/%s.h"\n' "$h" \
        > /opt/kiss_icp_ws/src/kiss-icp/ros/include/tf2_ros/$h.hpp; \
    done

RUN cd /opt/kiss_icp_ws && \
    /bin/bash -c "source /opt/ros/humble/install/setup.bash && \
    (rosdep install -i --from-path src --rosdistro humble -y || true) && \
    colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release"

# Source the ROS underlay and all overlays on shell start
RUN echo "source /opt/ros/humble/install/setup.bash" >> /root/.bashrc && \
    echo "source /opt/realsense_ws/install/setup.bash" >> /root/.bashrc && \
    echo "source /opt/kiss_icp_ws/install/setup.bash" >> /root/.bashrc

CMD ["bash"]
