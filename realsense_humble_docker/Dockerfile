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

# Source both the ROS underlay and the realsense-ros overlay on shell start
RUN echo "source /opt/ros/humble/install/setup.bash" >> /root/.bashrc && \
    echo "source /opt/realsense_ws/install/setup.bash" >> /root/.bashrc

CMD ["bash"]
