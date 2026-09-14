#!/usr/bin/env python3
"""
py_domain_relay.py

Custom domain-0 -> domain-42 relay, written to replace domain_bridge for the
--wifi launch path. domain_bridge (a single process opening two DDS domain
participants) was confirmed, live, to NOT relay any data at all over this
project's WiFi link (unicast Peers + ParticipantIndex=none) -- not even a
single tiny actively-published test topic -- while a bare `ros2 topic hz`
CLI participant on the exact same link, same config, received data fine.
Root cause not identified; this script sidesteps it by reimplementing the
same subscribe-domain-0/publish-domain-42 relay in plain rclpy, giving full
control over QoS and participant setup to debug or simply work around it.

Reads the same YAML format as bridge_docker.yaml (topics: <name>: {type,
qos: {reliability: best_effort}} -- from_domain/to_domain are accepted but
ignored, always 0 -> 42, since that's the only direction this project uses).

Usage:
  ros2 run ... not applicable -- run directly:
  CYCLONEDDS_URI=... python3 py_domain_relay.py <bridge_config.yaml>
"""
import sys
import threading

import yaml
import rclpy
from rclpy.context import Context
from rclpy.executors import SingleThreadedExecutor
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy, DurabilityPolicy
from rosidl_runtime_py.utilities import get_message


def make_qos(topic_cfg):
    reliability_str = (topic_cfg.get('qos') or {}).get('reliability', 'reliable')
    reliability = (
        ReliabilityPolicy.BEST_EFFORT if reliability_str == 'best_effort'
        else ReliabilityPolicy.RELIABLE
    )
    return QoSProfile(
        reliability=reliability,
        history=HistoryPolicy.KEEP_LAST,
        depth=5,
        durability=DurabilityPolicy.VOLATILE,
    )


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <bridge_config.yaml>", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f)
    topics = cfg['topics']

    ctx0 = Context()
    rclpy.init(args=None, context=ctx0, domain_id=0)
    node0 = Node('py_relay_domain0', context=ctx0)

    ctx42 = Context()
    rclpy.init(args=None, context=ctx42, domain_id=42)
    node42 = Node('py_relay_domain42', context=ctx42)

    publishers = {}
    counts = {name: 0 for name in topics}

    for name, topic_cfg in topics.items():
        msg_type = get_message(topic_cfg['type'])
        qos = make_qos(topic_cfg)
        pub = node42.create_publisher(msg_type, name, qos)
        publishers[name] = pub

        def make_cb(topic_name, publisher):
            def cb(msg):
                counts[topic_name] += 1
                publisher.publish(msg)
            return cb

        node0.create_subscription(msg_type, name, make_cb(name, pub), qos)
        print(f"relaying {name} ({topic_cfg['type']}, "
              f"reliability={(topic_cfg.get('qos') or {}).get('reliability', 'reliable')})",
              flush=True)

    def status_loop():
        import time
        while rclpy.ok(context=ctx0):
            time.sleep(5)
            print(f"[status] counts so far: {counts}", flush=True)

    exec0 = SingleThreadedExecutor(context=ctx0)
    exec0.add_node(node0)
    exec42 = SingleThreadedExecutor(context=ctx42)
    exec42.add_node(node42)

    threading.Thread(target=status_loop, daemon=True).start()
    t42 = threading.Thread(target=exec42.spin, daemon=True)
    t42.start()

    try:
        exec0.spin()
    except KeyboardInterrupt:
        pass
    finally:
        node0.destroy_node()
        node42.destroy_node()
        rclpy.shutdown(context=ctx0)
        rclpy.shutdown(context=ctx42)


if __name__ == '__main__':
    main()
