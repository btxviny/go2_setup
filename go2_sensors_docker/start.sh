#!/bin/bash
source /opt/ros/humble/install/setup.bash
source /opt/realsense_ws/install/setup.bash
# source /opt/kiss_icp_ws/install/setup.bash  # KISS-ICP disabled, see below

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

# KISS-ICP LiDAR odometry -- DISABLED. Was running egocentric odometry on
# the Hesai's raw scan (base_frame empty -> estimation directly in rslidar's
# own frame), publishing the odom_lidar<->rslidar TF plus kiss/odometry,
# kiss/frame, kiss/keypoints, kiss/local_map. Turned off; see
# tools/go2_sensors_docker.rviz (displays removed, Fixed Frame reverted to
# rslidar since nothing publishes odom_lidar anymore).
# ros2 run kiss_icp kiss_icp_node --ros-args \
#   -r pointcloud_topic:=/rslidar_points \
#   -p use_sim_time:=false \
#   -p lidar_odom_frame:=odom_lidar \
#   -p publish_odom_tf:=true \
#   -p invert_odom_tf:=true \
#   -p publish_debug_clouds:=true &

wait -n
