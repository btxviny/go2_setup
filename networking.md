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

- **Domain 0 is the robot's own domain.** The Go2's built-in sensors/nodes
  publish there, and the `go2-realsense-humble` container does too (it runs
  with `network_mode: host` and `ROS_DOMAIN_ID=0`), so RealSense + Hesai
  topics live on domain 0 alongside everything native to the robot.
- **This PC's own ROS2 tools (RViz2, `ros2` CLI, rqt) run on an isolated
  domain 42 instead of joining domain 0 directly.** Joining domain 0
  directly works too (see `AGENTS.md`'s "Quick/direct DDS access" snippet,
  useful for one-off debugging), but pollutes the robot's own domain 0
  discovery with this PC's tools and is not how the regular launch scripts
  operate.
- **`domain_bridge`** (`ros-humble-domain-bridge`) is what connects the two:
  a single local process on this PC that opens **two** DDS domain
  participants at once — one on domain 0 (reaching the dock over
  Ethernet/WiFi) and one on domain 42 (loopback only) — and relays exactly
  the topics listed in `tools/bridge_docker.yaml` from the former to the
  latter. Nothing from domain 0 reaches RViz except what's explicitly
  whitelisted there.
- Two separate Cyclone DDS config files drive this, because the two
  participants need different network interfaces: `tools/cyclone_domain0_enp3s0.xml`
  configures `domain_bridge` itself (`<Domain id="0">` bound to the real
  Ethernet/WiFi interface, `<Domain id="42">` bound to `lo`); `tools/cyclone_domain42_lo.xml`
  is for everything else on this PC that only ever needs domain 42 (RViz2,
  `ros2 topic` CLI checks) — always loopback, regardless of `--ethernet` vs
  `--wifi`. Each `<Domain>` block **must** carry its `id` attribute, or the
  second domain silently stops being bridged at all — see the
  troubleshooting entry below and `previous_approaches_and_build_history.md`
  item 22 for the full story of that bug.
- `tools/launch_all_sensors_docker.sh` automates the whole chain: brings the
  container up on the dock, starts `domain_bridge` locally, and launches
  RViz2 pointed at domain 42 — see `README.md`'s Launching section.

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
- **Live RViz data doesn't arrive over WiFi, but SSH/`docker` work fine** —
  this is a known limitation, not a bug: ROS2/DDS discovery needs multicast,
  which many consumer WiFi routers block between wireless clients ("AP/client
  isolation"). Confirmed on this project's own WiFi network using a one-off
  DDS discovery probe (since removed as no longer needed; 0 external
  participants found over WiFi in 10s, vs. instant over Ethernet) — check
  your router's wireless settings for an "AP Isolation" / "Client Isolation"
  toggle if you hit this. Ethernet is
  unaffected and always works; recording and manual `docker`/`ssh` commands
  work over either link regardless, since they don't depend on DDS discovery.
- **RViz shows nothing even over Ethernet, with no errors anywhere** — a
  real bug hit and fixed once: `domain_bridge` (used by
  `tools/launch_all_sensors_docker.sh`) opens two DDS domains in one
  process, and its Cyclone config file needs each domain explicitly scoped
  (`<Domain id="0">` / `<Domain id="42">`) or the second domain silently
  never gets bridged. Already fixed in `tools/cyclone_domain0_enp3s0.xml` —
  full root-cause writeup in `previous_approaches_and_build_history.md`
  item 22, if this ever resurfaces after editing that file.
