#!/bin/bash
source /opt/ros/humble/install/setup.bash
source /opt/realsense_ws/install/setup.bash

ros2 launch realsense2_camera rs_launch.py &

ros2 run hesai_lidar hesai_lidar_node --ros-args \
  -p "pcap_file:=''" \
  -p server_ip:=192.168.123.20 \
  -p lidar_recv_port:=2368 \
  -p gps_port:=10110 \
  -p start_angle:=0.0 \
  -p lidar_type:=PandarXT-16 \
  -p frame_id:=rslidar \
  -p pcldata_type:=0 \
  -p publish_type:=both \
  -p timestamp_type:=realtime \
  -p "data_type:=''" \
  -p lidar_correction_file:=/opt/realsense_ws/src/hesai_lidar/config/PandarXT-16.csv \
  -p "multicast_ip:=''" \
  -p coordinate_correction_flag:=false &

wait -n
