# Go2 EDU — Networking & Dock Connectivity

Detailed reference for reaching the Go2 expansion dock: hardware/network
topology, credentials, PC-side network setup, and both ways to connect
(Ethernet and WiFi), with troubleshooting. See [`README.md`](README.md) for
the high-level overview and what to actually run once you're connected.

---

## Hardware & Network Topology

```
Workstation PC ("viny-GP72-6QF")
   Ethernet iface: enp3s0 (or enp7s0 depending on machine)
   Static IP:      192.168.123.222/24
        |
        | RJ45 cable → dock's user-expansion Ethernet port
        v
Go2 expansion dock            192.168.123.18   (Jetson/Tegra arm64, Ubuntu 20.04 focal)
Go2 robot main computer       192.168.123.161  (do NOT assign this IP to anything else)
```

- Subnet: `192.168.123.0/24` for everything Go2-related.
- Never assign `192.168.123.161` to the PC or dock — it belongs to the robot.
- Persist the PC's static IP with `nmcli` (connection profile, bound to the
  Ethernet interface) rather than a transient `ip addr add`, so it survives
  reboot. `tools/go2_network_setup.sh` automates this (see below).
- The dock is also **dual-homed onto WiFi**, in addition to (not instead of)
  the Ethernet link above — on the `192.168.10.0/24` subnet (the `Cudy-17B9`
  network this PC is also on; DHCP-assigned, last observed as
  `192.168.10.89` but don't hardcode it — see below for the mDNS-based
  lookup that's robust to it changing).

## Credentials

| Target | User | Password |
|---|---|---|
| Go2 expansion dock (`192.168.123.18`), SSH + `sudo` | `unitree` | `123` |

SSH key auth is also set up (`~/.ssh/id_ed25519`, comment `go2-dock-access`)
and preferred over the password for anything scripted. `sudo` on the dock
uses the same password as SSH — needed for network config changes (e.g.
`nmcli device wifi connect`), since the account has no passwordless `sudo`.

## PC Network Setup

Before anything else works, this PC needs an IP on the `192.168.123.0/24`
subnet — a fresh machine's Ethernet adapter has none by default.

(PC)
```bash
cd ~/go2_guide_docs/tools
./go2_network_setup.sh
```

What it does, in order:

1. **Auto-detects the Ethernet interface** (first `en*` device that isn't
   `lo`), or pass one explicitly with `-i enp3s0`.
2. **Assigns `192.168.123.222/24`** to that interface as a **persistent
   NetworkManager connection profile** — not a transient `ip addr add` that
   disappears on reboot or replug. Refuses to let you set the PC's IP to
   `192.168.123.161` (the robot's own address).
3. **Pings the robot** (`192.168.123.161` by default) to confirm the link is
   up end-to-end.
4. **Checks UFW** and, if active with no rule for the interface, offers to
   fix it interactively — a default-DROP UFW policy silently drops all DDS
   traffic before it reaches a UDP socket (no error printed anywhere), so
   this is worth catching before assuming a sensor problem is upstream.

Useful flags:

| Flag | Meaning | Default |
|---|---|---|
| `-i IFACE` | Ethernet interface connected to the robot/dock | auto-detected |
| `-a PC_IP` | IP to assign to this PC on the 123 subnet | `192.168.123.222` |
| `-r ROBOT_IP` | Robot main-computer IP to ping-check against | `192.168.123.161` |
| `-t` | Temporary mode: `ip addr add` instead of a persistent profile | off |

## ROS2 Domain Architecture: How Sensor Topics Reach the Controller PC

Network connectivity (above) gets you a link to the dock, but that alone
doesn't make ROS2 topics show up in RViz on this PC — that's a separate,
DDS-level hop, worth understanding on its own:

- **Domain 0 is the robot's own domain, and everything now joins it
  directly — no bridge, no isolated domain.** The Go2's built-in
  sensors/nodes publish there, and the `go2-sensors-humble` container does
  too (it runs with `network_mode: host` and `ROS_DOMAIN_ID=0`), so
  RealSense + Hesai topics live on domain 0 alongside everything native to
  the robot. This PC's own ROS2 tools (RViz2, `ros2` CLI, rqt) join that
  same domain 0 directly instead of going through a bridge into an isolated
  domain — simpler, at the cost of seeing the robot's own native topics
  (`/api/*`, `/lowstate`, `/uslam/*`, etc.) alongside the sensor topics in
  `ros2 topic list`.
  (An earlier version of this setup used a `domain_bridge` process to relay
  only a whitelisted set of topics onto an isolated domain 42, keeping this
  PC's tools out of the robot's own domain 0 discovery. That was removed
  for simplicity — see `previous_approaches_and_build_history.md` for how it
  worked, if ever resurrected.)
- **Both sides must use the same RMW implementation for data to actually
  flow.** The container runs `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp`
  (CycloneDDS). If this PC's shell doesn't also export that, it silently
  falls back to the default `rmw_fastrtps_cpp` — which can often still
  *discover* a CycloneDDS publisher's topic (`ros2 topic list`/`topic info`
  will show it — cross-vendor RTPS discovery mostly works) but then fails to
  actually receive its data, with `ros2 topic hz`/subscribers getting zero
  messages and no error anywhere. This is one of the most common ways this
  setup silently "half-works" — see the required env vars below and
  `AGENTS.md`'s "Common shell pitfalls" for a live-confirmed repro.
- `tools/cyclone_ethernet.xml` is the CycloneDDS config used for the default
  `--ethernet` mode, binding to this PC's real Ethernet interface
  (`enp3s0`). `--wifi` (or a custom `-i IFACE`) generates an equivalent temp
  config instead, plus a unicast discovery `<Peer>` pointed at the dock's
  WiFi IP and an explicit `<ParticipantIndex>0</ParticipantIndex>` — needed
  because this WiFi network blocks multicast SPDP discovery between
  wireless clients (see the "Known limitation" caveat later in this doc, and
  `wifi_dds_data_loss_findings.md` for the full investigation).
- `tools/launch_all_sensors_docker.sh` automates the whole chain: brings the
  container up on the dock, and launches RViz2 directly on domain 0 with the
  right RMW/env vars already set — see `README.md`'s Launching section. It's
  the recommended way to do this rather than exporting the env vars
  manually every time.

### Manually running `ros2` CLI tools against this setup

If you need a plain `ros2 topic echo`/`hz`/`list` (etc.) outside of
`launch_all_sensors_docker.sh` — e.g. to debug while RViz2 is already
running, or instead of launching RViz2 at all — export these first, in the
**same shell** you run the command in:

(PC)
```bash
source /opt/ros/humble/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export CYCLONEDDS_URI="file:///home/viny/go2_guide_docs/tools/cyclone_ethernet.xml"   # --ethernet
export ROS_DOMAIN_ID=0
ros2 topic hz /rslidar_points
```

For `--wifi`, point `CYCLONEDDS_URI` at the temp config
`launch_all_sensors_docker.sh --wifi` generates (printed to the terminal
when it starts, under `/tmp/cyclone_domain0_*.xml`) instead of
`cyclone_ethernet.xml` — a plain Ethernet-bound config won't discover
anything over WiFi.

Skipping any of these three exports is the most common reason a manual
`ros2` command "sees" a topic but gets no data, or sees nothing at all:

| Symptom | Missing/wrong env var |
|---|---|
| Topic never appears in `ros2 topic list` at all | `ROS_DOMAIN_ID` (still on the default `0`... check it's not accidentally `42` or something else from an old shell) |
| Topic appears, but `topic hz`/subscribers get 0 messages | `RMW_IMPLEMENTATION` not set to `rmw_cyclonedds_cpp` (defaults to `rmw_fastrtps_cpp`) |
| `rmw_create_node: failed to create domain` | `CYCLONEDDS_URI` points at a file that doesn't exist on this machine — `unset CYCLONEDDS_URI` or fix the path |
| Works on Ethernet, nothing over WiFi | `CYCLONEDDS_URI` still pointing at `cyclone_ethernet.xml` instead of the `--wifi`-generated temp config with the discovery peer |



## Connecting to the Dock

There are two independent ways to reach the dock: **Ethernet** (the primary
link — required for the initial setup, and the only one that reliably
carries live sensor data to RViz2) and **WiFi** (optional, out-of-band —
great for SSH/file transfer/`docker` control without the cable, but *not*
for RViz visualization — see the caveat at the end of this section).

### Option A: Ethernet (primary)

Requires the PC network setup above already done, and the RJ45 cable
plugged into the dock's user-expansion Ethernet port.

(PC)
```bash
ssh -i ~/.ssh/id_ed25519 unitree@192.168.123.18
```

On login, the dock's `.bashrc` prompts every session:

```
ros:foxy(1) noetic(2) ?
```

This is irrelevant to the Docker workflow (the container has its own
self-contained ROS2 Humble install) — answer either way, or just `Ctrl+C`
past it if running a one-off command.

Dock facts: Ubuntu 20.04.5 (focal), kernel `5.10.104-tegra`, arm64
(Jetson/Tegra), Docker 24.0.5, `docker compose` v2 plugin installed at
`~/.docker/cli-plugins/docker-compose`.

### Option B: WiFi (optional, out-of-band)

**What it's for:** SSH, `docker`/`docker compose` commands, `scp`, and
rosbag recording — all of these work identically over WiFi.
**What it's *not* reliably for:** live RViz2 visualization — see the caveat
at the end of this subsection before relying on it for that.

#### One-time setup (skip if already done on this dock)

1. **Plug a USB WiFi adapter into the dock.** Confirmed working out of the
   box, no driver install needed: TP-Link TL-WN823N (`RTL8192EU` chipset) —
   the kernel driver was already present and the adapter showed up as
   `wlan0` immediately. Verify, over the Ethernet link:
   (PC)
   ```bash
   ssh -i ~/.ssh/id_ed25519 unitree@192.168.123.18 'lsusb; nmcli device status'
   ```
   Look for the adapter in `lsusb` and a `wifi` row (`wlan0`) in
   `nmcli device status`. If it's missing, a different chipset may need a
   driver installed first — not covered here.

2. **Join the dock to the same WiFi network this PC is on.** You need that
   network's SSID and password. If this PC is already connected to it, you
   can read the password back out locally (only works for networks *this*
   PC has already joined and saved):
   (PC)
   ```bash
   nmcli device wifi show-password
   ```
   Then, on the dock (needs `sudo` — see Credentials above):
   (dock)
   ```bash
   sudo nmcli device wifi connect '<SSID>' password '<password>' ifname wlan0
   ```

3. **Verify it connected and has internet/LAN access:**
   (dock)
   ```bash
   nmcli device status                 # wlan0 should show "connected"
   ip -br addr show wlan0              # note the assigned IP
   ping -c2 8.8.8.8                    # confirm it actually routes out
   ```

4. **Confirm it'll reconnect automatically after a reboot** (should be the
   default, but worth checking once):
   (dock)
   ```bash
   nmcli -f connection.autoconnect connection show '<SSID>'   # expect: yes
   ```

This is additive, not a replacement — `eth0` (`192.168.123.18`, the Go2
robot subnet) is completely untouched by any of this, so robot/DDS traffic
is unaffected either way. The dock ends up dual-homed: Ethernet for the
robot, WiFi for everything else.

#### Connecting, day to day

The WiFi IP is on the `192.168.10.0/24` subnet (`Cudy-17B9`), **DHCP-assigned
and can change** between sessions — last observed as `192.168.10.89`, but
don't hardcode it. Instead, use mDNS, which resolves automatically regardless
of the current IP (the dock's `avahi-daemon` broadcasts its hostname,
`ubuntu`, as `ubuntu.local`; nothing had to be configured for this — it
worked out of the box on both sides):

(PC)
```bash
ssh -i ~/.ssh/id_ed25519 unitree@ubuntu.local
```

If you ever need the actual current IP (e.g. for `nmap` or a router admin
page lookup) **and the Ethernet cable isn't plugged in**, don't try to go via
the Ethernet address — use mDNS to reach the dock first (works fine with no
Ethernet link at all, since `ubuntu.local` resolves over WiFi directly), then
ask the dock itself for its WiFi IP:

(PC)
```bash
ssh -i ~/.ssh/id_ed25519 unitree@ubuntu.local "ip -br addr show wlan0"
```

If Ethernet *is* plugged in, that link works too as an alternative path to
the same information:

(PC)
```bash
ssh -i ~/.ssh/id_ed25519 unitree@192.168.123.18 "ip -br addr show wlan0"   # via Ethernet
```

**Gotcha:** `ubuntu.local` can occasionally resolve to a *stale* cached
address (e.g. an old Ethernet IP, even with the cable unplugged) rather than
the dock's current WiFi IP, if this PC's mDNS cache hasn't refreshed yet —
seen live once. If `ssh unitree@ubuntu.local` times out despite the dock
being up on WiFi, force a fresh resolve before concluding the dock is
unreachable:

(PC)
```bash
avahi-resolve -n ubuntu.local
```
If this returns a `192.168.123.x` address while Ethernet is unplugged, that's
the stale-cache symptom, not a real connectivity problem — it typically
self-corrects within a short wait; retry the SSH/avahi-resolve after a few
seconds.

#### Troubleshooting

- **`ssh: connect to host ... port 22: Connection timed out`** — most often
  the Ethernet cable is unplugged (check with
  `ip -br link show enp3s0` — look for `NO-CARRIER`) if you're using the
  Ethernet address, or the dock/its WiFi adapter is off/disconnected if
  using WiFi. Occasionally just a transient hiccup — retry once before
  digging further.
- **`Host key verification failed`** — SSH found a *different* key already
  saved for that hostname/IP than what the dock is presenting now. This is
  expected the first time you connect to a new IP (e.g. right after the WiFi
  adapter gets a fresh DHCP lease), or if another device on the network
  previously used the same IP. Fix:
  ```bash
  ssh -o StrictHostKeyChecking=accept-new -i ~/.ssh/id_ed25519 unitree@<host>
  ```
- **`ubuntu.local` doesn't resolve** — confirm `avahi-daemon` is active on
  the dock (`ssh unitree@192.168.123.18 systemctl is-active avahi-daemon`,
  via Ethernet) and that this PC supports mDNS resolution
  (`getent hosts ubuntu.local` — Ubuntu has this built in via `nss-mdns` by
  default). Fall back to the Ethernet-based IP lookup above if it's broken.
- **Live RViz data doesn't arrive over WiFi (or arrives very slowly/laggy),
  but SSH/`docker`/discovery all work fine** — **this is not an AP/client
  isolation or multicast problem** (an earlier version of this doc claimed
  it was — see "Correction" below for why that was wrong). It's a genuine
  WiFi *data throughput* limitation for large messages
  (`/rslidar_points`, raw RealSense color/depth): confirmed via direct
  testing (Sept 2026) that even with discovery working perfectly and the
  reader using `RELIABLE` QoS (recovering lost fragments via retransmission
  — see the "Known issue" section above), actual throughput for these large
  topics over this WiFi link is still only a handful of messages per
  *tens of seconds*, vs. a solid ~10 Hz over Ethernet. Small messages
  (compressed color, robot state topics) are largely unaffected. Ethernet
  remains the only reliable link for live large-topic visualization;
  recording and manual `docker`/`ssh` commands work fine over either link
  regardless, since they don't depend on DDS discovery or large-message
  throughput.

  **Correction (Sept 2026):** this bullet previously claimed WiFi discovery
  itself was broken due to "AP/client isolation" blocking multicast, based
  on an early one-off discovery probe. A later, more careful live test —
  sending/receiving real UDP packets on CycloneDDS's own SPDP multicast
  group (`239.255.0.1:7400`) directly between the PC's and dock's WiFi
  interfaces, in both directions — proved multicast works fine on this
  network. The original probe's "0 participants" result was most likely
  measuring something else (e.g. run before the `MaxMessageSize` fragmentation
  fix, or during an unrelated misconfiguration) rather than an actual AP
  isolation block. This is why `tools/cyclone_wifi.xml` and
  `go2_sensors_docker/config/cyclonedds_wifi.xml` no longer generate a
  per-run unicast `<Peer>`/`<ParticipantIndex>` config — see "WiFi CycloneDDS
  config simplification" below.
- **RViz shows nothing even over Ethernet, with no errors anywhere** —
  first check `RMW_IMPLEMENTATION` (see the table above); if that's already
  right, historical note: an earlier version of this setup used
  `domain_bridge` to relay topics from domain 0 onto an isolated domain 42,
  and hit a real bug where its Cyclone config needed each domain explicitly
  scoped (`<Domain id="0">` / `<Domain id="42">`) or the second domain
  silently never got bridged — full root-cause writeup in
  `previous_approaches_and_build_history.md` item 22. `domain_bridge` is no
  longer used at all (everything runs on domain 0 directly now), so this
  specific bug can't recur, but it's a good example of "silently half
  works" DDS config failures in this project.
- **Topic shows up in `ros2 topic list`/`topic info` but nothing is
  received (`topic hz`, subscribers, RViz displays all show 0)** — almost
  always `RMW_IMPLEMENTATION` not exported as `rmw_cyclonedds_cpp` in that
  shell (see the manual-CLI section above). Confirmed live: identical
  `ros2 topic hz /rslidar_points` got 0 messages with `RMW_IMPLEMENTATION`
  unset (falls back to `rmw_fastrtps_cpp`), ~7 Hz with it set correctly —
  same machine, same link, only the RMW differed. UFW is a separate known
  cause of the exact same symptom (see `AGENTS.md`'s "Critical gotcha")
  — check both if the env vars are already confirmed correct.
- **Only the *large* topics (`/rslidar_points`, raw RealSense color/depth)
  show 0 messages — small topics (compressed color, `camera_info`, robot
  state topics) work fine, and `RMW_IMPLEMENTATION`/UFW are already
  confirmed correct** — this is CycloneDDS's own `MaxMessageSize` default
  (14720 B), which is ~10x the real 1500 B Ethernet MTU. Left at default,
  any message needing more than one internal fragment gets sent as a single
  oversized UDP datagram that the kernel then IP-fragments to fit the wire —
  fragile for reliable delivery, since losing any single one of the ~9-10
  resulting IP fragments loses the whole multi-MB sample. Confirmed
  root-caused (Sept 2026) via `/proc/net/snmp` showing a ~50% `ReasmFails`
  rate under load, and `tcpdump` showing genuine ~13-14KB UDP payloads (not
  a GRO artifact — reproduced identically with GRO forced off via
  `ethtool -K enp3s0 gro off`). **Fix already applied** in this repo: both
  the container/publisher-side config
  (`go2_sensors_docker/config/cyclonedds_ethernet.xml`, the default
  `CYCLONEDDS_URI` in `docker-compose.yml`) and the PC/reader-side config
  (`tools/cyclone_ethernet.xml`) cap `MaxMessageSize` (1400 B) and
  `FragmentSize` (1300 B) safely under the MTU, forcing CycloneDDS to always
  emit single, unfragmented, MTU-safe UDP datagrams. If you ever see this
  symptom again (e.g. after regenerating a config from scratch), that's the
  setting to check first — full write-up in `AGENTS.md` item 11.
- **`ros2` CLI commands run in a plain terminal only ever show `/api/*` and
  other robot-native topics, never `/rslidar_points`/`/camera/...`, even
  though `launch_all_sensors_docker.sh` itself works fine** — check for a
  **stale `ros2cli` daemon**. Any bare `ros2 ...` command (run without first
  sourcing the three env vars — see the manual-CLI section above) silently
  spawns a background `ros2-daemon` process
  (`ros2cli.daemon.daemonize`) using whatever RMW/domain was active *at that
  moment* — typically the default `rmw_fastrtps_cpp` on domain 0 if you
  forgot to `source tools/ros2_env.sh` first. That daemon then keeps running
  in the background and answers `ros2 topic list`/etc. for the rest of the
  session regardless of what you `export` afterwards, because the CLI talks
  to the existing daemon instead of spawning a fresh participant with your
  new env vars. Fix: `ros2 daemon stop`, then re-run with the correct env
  vars sourced. Confirmed live (Sept 2026): killing a stray
  `rmw_fastrtps_cpp` daemon was what made `/rslidar_points` etc. actually
  appear in `ros2 topic list` afterwards.
- **`--wifi` mode's `rviz2` aborts immediately with `rtps_init: failed to
  create unicast sockets for domain 0 participant index 0 (ports 7410,
  7411)`** — `launch_all_sensors_docker.sh --wifi` hardcodes
  `<ParticipantIndex>0</ParticipantIndex>` in the temp CycloneDDS config it
  generates (needed so the dock's unicast `<Peer>` entry, which points at a
  fixed port derived from participant index 0, can actually find this PC's
  reader). This only works if nothing else on the PC already owns the fixed
  RTPS discovery ports (7410/7411 for participant index 0 on domain 0).
  The most common squatter is exactly the stale `ros2cli` daemon described
  in the bullet above — it's a full DDS participant of its own and, if
  already running when `rviz2` starts, will have already claimed those
  ports. Fix: `ros2 daemon stop` before launching, same as above.

## Known issue: LiDAR point cloud shows only the first frame, then freezes

**Symptom:** `/rslidar_points` shows up fine in `ros2 topic list`/`topic
info`, `RMW_IMPLEMENTATION`/UFW/`MaxMessageSize` are all already correct
(see above), and RViz's `HesaiRslidarCloud` display renders exactly one
point cloud when it first connects, then never updates again — while the
RealSense color/depth displays keep updating normally in the same RViz
session. A **fresh `ros2 topic hz /rslidar_points` or a brand-new `rclpy`
subscriber gets *zero* messages, indefinitely** (confirmed live over both
Ethernet and WiFi, for 85s+ continuous windows) — even though the topic is
genuinely still being published at a steady ~10 Hz the entire time
(confirmed via `docker exec ... ros2 topic hz /rslidar_points` run directly
inside the container on the dock, bypassing the network entirely).

**Root cause (confirmed Sept 2026, live packet capture):** each
`/rslidar_points` message is large enough (hundreds of KB) that CycloneDDS
splits it into on the order of ~200 fragments, sent back-to-back in a burst
lasting only a few **milliseconds** (`tcpdump` on the PC showed ~200 UDP
datagrams, each ~1384 B, arriving within a 3 ms window for a single sample).
Something in that burst — kernel socket buffering, NIC handling, or the
link itself — reliably drops at least one fragment out of every burst.

With the reader subscribed at **`BEST_EFFORT`** QoS (RViz's `PointCloud2`
display plugin's default), there is no mechanism to recover a dropped
fragment — DDS just discards that entire sample and waits for the next one,
which then loses a *different* fragment, and so on. In practice this means
almost every sample gets silently discarded, forever, with **zero errors
anywhere** — not in RViz, not in the CLI tools, not in the container logs.
The single frame that does render is just the rare lucky sample whose
fragments all happened to survive.

Proven experimentally: switching a test subscriber's QoS from `BEST_EFFORT`
to `RELIABLE` (matching the Hesai driver's own publisher QoS — `RELIABLE`,
`KEEP_LAST` depth 1000) immediately started receiving real messages, because
a `RELIABLE` reader NACKs the specific missing fragment(s) and the writer
resends just those, letting the sample complete despite the burst loss.

**Fix applied:** `tools/go2_sensors_docker.rviz`'s `HesaiRslidarCloud`
display QoS override was changed from `Reliability Policy: Best Effort` to
`Reliability Policy: Reliable` (and `Depth` bumped from 5 to 1000 to match
the publisher). No changes needed on the publisher/container side — its QoS
was already correct.

**Why not just make the *publisher* `BEST_EFFORT` too, to keep both sides
symmetric?** This would not help and would likely make things worse.
Reliability policy determines whether a lost fragment can be recovered *at
all* — it's not about which side is "at fault," and there's no such thing as
"symmetric" fixing the underlying burst-loss problem here. With
`BEST_EFFORT` on both ends (what this setup effectively had before, since a
`BEST_EFFORT` reader against a `RELIABLE` writer behaves like `BEST_EFFORT`
end-to-end anyway), every sample that loses so much as one fragment out of
~200 is gone for good — which is exactly the bug being fixed. `RELIABLE`
is what makes recovery possible; there's no equivalent "make it work" lever
available if both sides give up on retransmission.

If the (small) retransmission overhead this introduces ever becomes a
concern, the more correct long-term fixes would be to make the bursts
themselves less loss-prone rather than removing the recovery mechanism —
e.g. downsampling the point cloud before publishing (fewer/smaller
fragments per burst) or tuning kernel/NIC receive buffers further — but
`RELIABLE` is the confirmed, working fix as of this writing.

## WiFi CycloneDDS config simplification (Sept 2026): multicast works fine, so the unicast-peer hack was removed

**Background:** `--wifi` mode used to generate a brand-new temporary
CycloneDDS config on *every single run*, on both ends — a unicast
`<Peer address="...">` pointing at the other side's current WiFi IP, plus
an explicit `<ParticipantIndex>0</ParticipantIndex>`. This required an SSH
round-trip each run just to ask the dock for its current `wlan0` IP. The
justification (documented in this file and `AGENTS.md` for months) was that
this WiFi network's AP blocks multicast between wireless clients ("AP/client
isolation"), so plain multicast-based SPDP discovery (the same mechanism
Ethernet mode relies on with zero special config) supposedly didn't work,
and the unicast peer was a required workaround.

**That assumption was wrong.** A direct, live test (Sept 2026) proved
multicast works fine both ways on this network:

```
PC (wlp2s0, 192.168.1.135)  <---multicast 239.255.0.1:7400--->  dock (wlan0, 192.168.1.131)
```
A small Python script joined that exact multicast group/port (CycloneDDS's
own SPDP group) on each side and sent test packets from the other — both
directions received them cleanly, alongside plenty of *other* genuine DDS
SPDP traffic from the robot's own participants that was already reaching
both WiFi endpoints unprompted. Re-testing actual ROS2 discovery
(`ros2 topic list`) with a **plain multicast-only config (no `<Peer>`, no
`<ParticipantIndex>`)** on both the container and the PC confirmed topics
discover instantly over WiFi, identically to Ethernet.

**Conclusion:** the unicast-peer/participant-index generation was solving a
problem that didn't actually exist on this network (or at least, doesn't
anymore — hard to say in hindsight whether the original one-off probe that
motivated it was flawed, or something else changed since). It never helped
with the *actual* WiFi problem anyway (large-message throughput — see the
troubleshooting bullet above), since that's a link-bandwidth/loss issue,
not a discovery-layer one.

### What changed

- `tools/launch_all_sensors_docker.sh --wifi` no longer does any IP
  resolution or per-run temp-file generation for the normal case. It just
  points `CYCLONEDDS_URI` at two new **static, checked-in** config files:
  - `tools/cyclone_wifi.xml` (PC side, binds `wlp2s0` only)
  - `go2_sensors_docker/config/cyclonedds_wifi.xml` (dock/container side,
    binds `wlan0` only, selected via `CONTAINER_CYCLONEDDS_URI`)
- A custom `-i IFACE` that doesn't match either default interface name
  still generates a minimal temp config (just the interface name — no
  peers/participant index needed anymore either).
- The old per-run-generated `cyclonedds_wifi_discovery.xml` (dock side) is
  gone.

### Why there still isn't *one* config file for both Ethernet and WiFi

The natural next question: since neither side needs per-run IP baking
anymore, why not go one step further and have a single static config that
lists **both** interfaces (`eth0`+`wlan0`, or `enp3s0`+`wlp2s0`), so the
exact same file works regardless of which link is actually connected?

**Tested directly, and it doesn't work reliably — don't do this.** With
the *container* (writer/publisher side) configured to bind both `eth0` and
`wlan0` simultaneously, a PC subscribing over WiFi with `RELIABLE` QoS
(the fix above) got **zero messages** over a 33-second window — down from
already-working (if slow — a handful of messages per ~20-30s) when the
container was configured with `wlan0` only. Discovery (`ros2 topic list`)
still worked fine in the dual-interface case; only actual data delivery
broke. The likely cause: CycloneDDS picks one locator/interface path per
matched reader, and with two interfaces active it can end up choosing one
that doesn't correspond to where the remote reader is actually reachable —
silently, with no error anywhere, same as every other failure mode in this
document.

So the two static files stay genuinely separate (one interface each),
selected per-mode by the script, rather than merged into one. This is a
smaller, more honest simplification than "one file for everything" would
have been, but it's the one that's actually been verified to work.
