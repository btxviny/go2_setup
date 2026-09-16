# Unitree Go2 EDU ROS 2 Topic Reference Guide

This document provides a categorized breakdown of the ROS 2 topics available on the Unitree Go2 EDU quadruped robot. The topics are organized by subsystem to help developer integration, mapping, state monitoring, and custom application development.

---

## 1. High-Level API Request/Response Interfaces (`/api/*`)

Unitree utilizes a request/response topic pattern (`/api/<service>/request` and `/api/<service>/response`) to send RPC-style JSON payload commands and receive responses to high-level system services.

| Topic Name | Expected Role | Description & Typical Usage |
| :--- | :--- | :--- |
| `/api/arm/request`<br>`/api/arm/response` | Service API | Interface for requesting robotic arm actions or movement sequences (if equipped with a robotic arm like Z1). |
| `/api/assistant_recorder/request`<br>`/api/assistant_recorder/response` | Service API | Handles commands for triggering audio recording sequences for voice assistant features. |
| `/api/audiohub/request`<br>`/api/audiohub/response` | Service API | High-level API to command the audio system (e.g., play preset sound effects, text-to-speech requests, volume control). |
| `/api/bashrunner/request`<br>`/api/bashrunner/response` | Service API | Internal RPC interface to trigger system scripts or low-level diagnostic command scripts. |
| `/api/config/request`<br>`/api/config/response` | Service API | Query and modify robot system configurations, network parameters, and software settings. |
| `/api/fourg_agent/request`<br>`/api/fourg_agent/response` | Service API | Handles configuration and telemetry requests for cellular (4G/LTE) module management. |
| `/api/gas_sensor/request`<br>`/api/gas_sensor/response` | Service API | API to start, stop, or configure peripheral gas detection sensors. |
| `/api/gesture/request` | Service API | Sends requests to activate or calibrate camera-based human gesture recognition modes. |
| `/api/gpt/request`<br>`/api/gpt/response` | Service API | Request/response bus interacting with Unitree's onboard LLM/GPT integration for voice/AI queries. |
| `/api/motion_switcher/request`<br>`/api/motion_switcher/response` | Service API | Used to request transitions between control modes (e.g., switching between manual remote control, autonomous navigation, or SDK control). |
| `/api/obstacles_avoid/request`<br>`/api/obstacles_avoid/response` | Service API | Enable/disable or configure parameters for high-level real-time visual/LiDAR obstacle avoidance routines. |
| `/api/pet/request`<br>`/api/pet/response` | Service API | Controls interactive "companion" behaviors (e.g., tail wags, playful movements, stretching actions). |
| `/api/programming_actuator/request`<br>`/api/programming_actuator/response` | Service API | Endpoint for execution requests from graphical block programming environments or custom routine scripts. |
| `/api/rm_con/request` | Service API | Interface for handling remote control management and handshake protocols. |
| `/api/robot_state/request`<br>`/api/robot_state/response` | Service API | High-level query interface to fetch detailed robot hardware health, thermal status, and runtime metrics. |
| `/api/slam_operate/request`<br>`/api/slam_operate/response` | Service API | Control interface for SLAM mapping execution (start/stop mapping, save map, reset origin, switch to localization mode). |
| `/api/sport/request`<br>`/api/sport/response` | Service API | High-level gait and sport mode controller interface. Accepts movement commands (dance, jump, lie down, stand up, pace, run). |
| `/api/sport_lease/request`<br>`/api/sport_lease/response` | Service API | Controls rights/ownership lease of the sport module to prevent conflicting control sources (e.g., app vs. ROS node). |
| `/api/uwbswitch/request`<br>`/api/uwbswitch/response` | Service API | Toggles Ultra-Wideband (UWB) tracking features (e.g., companion follow mode using remote tag). |
| `/api/videohub/request`<br>`/api/videohub/response` | Service API | Configures camera video streams, resolution, framerates, and encoding formats. |
| `/api/voice/request`<br>`/api/voice/response` | Service API | Accepts voice synthesis strings or controls voice command parser settings. |
| `/api/vui/request`<br>`/api/vui/response` | Service API | Visual User Interface / LED indicator control API (managing light ring colors, flash patterns, indicator states). |

---

## 2. Robot Motion, Low-Level Control & Hardware State

Topics handling low-level motor states, IMU data, high-level motion feedback, battery status, and wireless controllers.

| Topic Name | Expected Role | Description & Typical Usage |
| :--- | :--- | :--- |
| `/lowcmd` | Command | Low-level motor command topic (joint angles, velocities, torque feedforward gains $K_p$, $K_d$). **Use with caution.** |
| `/lowstate` | Feedback | High-frequency low-level motor feedback (joint positions, joint velocities, joint temperatures, IMU raw data). |
| `/sportmodestate` | Telemetry | Published by the high-level motion controller detailing current velocity, body pose (pitch, roll, yaw), foot contact forces, and movement state. |
| `/lf/lowstate`<br>`/lf/sportmodestate` | Telemetry | Low-frequency aggregated mirrors of lowstate and sportmodestate used for lightweight monitoring or logging. |
| `/lf/battery_alarm` | Warning | Battery safety topic indicating low battery, overvoltage, overcurrent, or temperature alarms. |
| `/multiplestate` | Telemetry | Combined telemetry state aggregating multiple subsystem indicators (power, temperature, connectivity). |
| `/wirelesscontroller`<br>`/wirelesscontroller_unprocessed` | Input | Transmits controller joystick inputs and key combinations from the physical handheld Unitree remote controller. |
| `/gnss` | Telemetry | Global Navigation Satellite System (GPS) raw or parsed data (if external module installed). |
| `/uwbstate` | Telemetry | Status and range measurements from the UWB positioning module used for target tracking. |
| `/uwbswitch` | State | Current active status of the UWB hardware subsystem. |

---

## 3. Unitree LiDAR Subsystem (`/utlidar/*`)

Topics generated by the onboard Unitree 3D LiDAR (4D LiDAR L1) sensor driver, delivering point clouds, internal state, and localized odometry.

| Topic Name | Expected Role | Description & Typical Usage |
| :--- | :--- | :--- |
| `/utlidar/cloud` | Sensor Data | Raw or calibrated 3D point cloud output from the 3D LiDAR (`sensor_msgs/msg/PointCloud2`). |
| `/utlidar/cloud_base` | Sensor Data | Point cloud transformed into the robot's base frame (`base_link`). |
| `/utlidar/cloud_deskewed` | Sensor Data | Motion-compensated (deskewed) point cloud using IMU data to eliminate distortion during movement. |
| `/utlidar/grid_map` | Map Data | 2D occupancy grid map generated directly on-sensor for fast local obstacle avoidance. |
| `/utlidar/height_map`<br>`/utlidar/height_map_array` | Map Data | 2.5D height-field terrain map showing ground elevation steps, obstacles, and drop-offs. |
| `/utlidar/imu` | Sensor Data | Raw or filtered IMU data directly from the integrated LiDAR IMU package (`sensor_msgs/msg/Imu`). |
| `/utlidar/lidar_state` | Telemetry | Health status, internal temperature, RPM, and diagnostics of the Unitree LiDAR hardware. |
| `/utlidar/robot_odom` | Odometry | High-rate local wheel/motion odometry computed by combining LiDAR feature tracking and motor encoders. |
| `/utlidar/robot_pose` | Pose | Estimated 3D spatial pose ($x, y, z, \text{orientation}$) of the robot relative to the local map origin. |
| `/utlidar/voxel_map`<br>`/utlidar/voxel_map_compressed` | Map Data | 3D Voxel representation of the immediate surrounding space used for 3D path planning. |
| `/utlidar/client_command`<br>`/utlidar/mapping_cmd`<br>`/utlidar/switch` | Control | Control channels to toggle LiDAR power, start internal mapping routines, or switch sensor operating modes. |
| `/utlidar/range_info`<br>`/utlidar/range_map` | Sensor Data | Time-of-Flight / range intensity arrays derived from LiDAR returns. |
| `/utlidar/server_log` | Logging | Internal logging topic outputting diagnostic messages from the LiDAR driver daemon. |

---

## 4. SLAM, Mapping & Autonomous Navigation (`/uslam/*` & `lio_sam_ros2`)

Topics dedicated to map generation, localization, global navigation paths, and point cloud registration.

| Topic Name | Expected Role | Description & Typical Usage |
| :--- | :--- | :--- |
| `/lio_sam_ros2/mapping/odometry` | Odometry | Odometry stream provided by the embedded LIO-SAM (Tightly-coupled Lidar Inertial Odometry) framework. |
| `/slam_info`<br>`/slam_key_info` | Telemetry | Status indicators of the active SLAM pipeline (e.g., loop closures detected, keyframe counts, tracking health). |
| `/uslam/cloud_map` | Map Data | Accumulated global 3D point cloud map generated during mapping sessions. |
| `/uslam/frontend/cloud_world_ds` | Map Data | Downsampled point cloud used by the SLAM front-end for quick scan-matching. |
| `/uslam/frontend/odom` | Odometry | High-frequency front-end pose estimation output from scan-matching. |
| `/uslam/localization/cloud_world` | Map Data | World reference point cloud utilized during localization-only mode. |
| `/uslam/localization/odom` | Odometry | Global localization pose output relative to a pre-built static map. |
| `/uslam/map_file_pub`<br>`/uslam/map_file_sub` | File Transfer | Data streams for transmitting or receiving serialized map files (`.pcd` or `.octomap`). |
| `/uslam/navigation/global_path` | Navigation | Calculated global trajectory/path waypoints generated for autonomous navigation. |
| `/uslam/client_command`<br>`/uslam/server_log` | Control/Logging | Commands sent to the USLAM engine and resulting system log diagnostics. |
| `/qt_add_node`<br>`/qt_add_edge`<br>`/qt_command`<br>`/qt_notice`<br>`/query_result_node`<br>`/query_result_edge` | Graph SLAM | Internal topological map graph construction topics (nodes, edges, topological route queries) used by Unitree's mobile app mapping framework. |

---

## 5. Vision, WebRTC & Audio Streaming

Topics handling multimedia streams, web interface communication, speaker/microphone audio, and optical perception.

| Topic Name | Expected Role | Description & Typical Usage |
| :--- | :--- | :--- |
| `/frontvideostream` | Video Stream | Compressed or raw frame stream from the primary front-facing camera. |
| `/videohub/inner` | Video Stream | Internal video bus route feeding local perception nodes or remote streaming services. |
| `/pctoimage_local` | Image Data | Projection conversion output turning 3D point clouds into 2D depth/range images. |
| `/audioreceiver`<br>`/audiosender` | Audio Stream | PCM or encoded audio data streams representing onboard microphone input and speaker output streams. |
| `/audio_msg` | Audio Stream | Broadcast channel for structured audio feedback or audio clip playback events. |
| `/audiohub/player/state` | Telemetry | Status of the audio playback engine (e.g., IDLE, PLAYING, STOPPED, current track). |
| `/webrtcreq`<br>`/webrtcres`<br>`/xfk_webrtcreq`<br>`/xfk_webrtcres` | WebRTC Bridge | Real-time WebRTC signaling channels (Session Description Protocol / ICE candidate exchange) powering low-latency video and control feeds to mobile apps/web dashboards. |
| `/rtc/state`<br>`/rtc_status` | Telemetry | Status and connection state of the Real-Time Communication (RTC) daemon. |

---

## 6. Robotic Arm & Programming Extensions

Topics dedicated to controlling accessory attachments, block programming execution, and external tool interfaces.

| Topic Name | Expected Role | Description & Typical Usage |
| :--- | :--- | :--- |
| `/arm_Command` | Command | Direct joint/cartesian command input for an attached robotic arm module. |
| `/arm_Feedback` | Feedback | Real-time joint angles, Cartesian poses, and error codes from the robotic arm controller. |
| `/arm/action/state` | Action State | High-level status for robotic arm action execution (e.g., executing trajectory, succeeded, aborted). |
| `/programming_actuator/command`<br>`/programming_actuator/feedback` | Control/Feedback | Commands and state feedback executed during block-based visual programming scripts. |

---

## 7. AI, Gesture & Companion Mode Topics

Topics dedicated to high-level smart capabilities including LLM integrations, gesture recognition, and interactive behavior.

| Topic Name | Expected Role | Description & Typical Usage |
| :--- | :--- | :--- |
| `/gesture/result` | Perception | Output results from optical vision gesture detection (e.g., hand raised, follow signal, stop signal). |
| `/gpt_cmd`<br>`/gpt_state`<br>`/gptflowfeedback` | Interactive AI | Execution feedback, state engine output, and formatted command triggers coming from the onboard LLM/GPT execution system. |
| `/pet/flowfeedback` | State | Sequence state updates for active companion "pet" animations or interactive behavior routines. |

---

## 8. System Diagnostics & Peripheral Topics

Topics providing underlying Linux/network state monitoring, internal messaging, and core ROS 2 framework channels.

| Topic Name | Expected Role | Description & Typical Usage |
| :--- | :--- | :--- |
| `/gas_sensor` | Sensor Data | Data readings from external environmental/gas sensors connected to expansion ports. |
| `/public_network_status` | Network | Connection status, IP address information, and signal strength for external WAN/WiFi networks. |
| `/config_change_status` | System Event | Published when system configurations or operating modes are updated dynamically. |
| `/servicestate`<br>`/servicestateactivate` | System State | Monitors active daemon services and allows toggling internal system software daemons. |
| `/selftest` | Diagnostics | Built-In Self-Test (BIST) results reporting motor, sensor, battery, and compute node health. |
| `/parameter_events` | ROS 2 Core | Standard ROS 2 topic publishing parameter updates across all active nodes (`rcl_interfaces/msg/ParameterEvent`). |
| `/rosout` | ROS 2 Core | Centralized logging output topic collecting log messages from all ROS 2 nodes (`rcl_interfaces/msg/Log`). |