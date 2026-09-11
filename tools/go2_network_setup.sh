#!/usr/bin/env bash
#
# go2_network_setup.sh
#
# Configures this PC's Ethernet adapter for the Go2 EDU robot subnet
# (192.168.123.0/24), verifies connectivity, and checks for the UFW
# pitfall documented in go2_setup_session_summary.md (silent DDS drop
# even though ping/tcpdump look healthy).
#
# Usage:
#   ./go2_network_setup.sh [-i IFACE] [-a PC_IP] [-r ROBOT_IP] [-t]
#
#   -i IFACE     Network interface connected to the robot (default: auto-detect)
#   -a PC_IP     IP to assign to this PC on the 123 subnet (default: 192.168.123.222)
#   -r ROBOT_IP  Robot's main-computer IP to ping (default: 192.168.123.161)
#   -t           Temporary mode: use `ip addr add` instead of a persistent
#                NetworkManager profile (lost on reboot / interface reset)
#
# Refuses to set PC_IP to 192.168.123.161 (the robot's own address).
#
set -euo pipefail

IFACE=""
PC_IP="192.168.123.222"
ROBOT_IP="192.168.123.161"
PREFIX="24"
TEMP_MODE=0

usage() { grep '^#' "$0" | sed -n '3,20p'; exit 1; }

while getopts "i:a:r:th" opt; do
  case "$opt" in
    i) IFACE="$OPTARG" ;;
    a) PC_IP="$OPTARG" ;;
    r) ROBOT_IP="$OPTARG" ;;
    t) TEMP_MODE=1 ;;
    h) usage ;;
    *) usage ;;
  esac
done

if [[ "$PC_IP" == "192.168.123.161" ]]; then
  echo "ERROR: 192.168.123.161 is the Go2 robot's own IP. Choose a different PC_IP." >&2
  exit 1
fi

# --- Auto-detect the Ethernet interface if not given ---
if [[ -z "$IFACE" ]]; then
  IFACE=$(ip -br link show | awk '$1 != "lo" && $1 ~ /^en/ {print $1; exit}')
  if [[ -z "$IFACE" ]]; then
    echo "ERROR: could not auto-detect an Ethernet interface (en*). Pass one with -i." >&2
    ip -br link show >&2
    exit 1
  fi
  echo "Auto-detected interface: $IFACE"
fi

if ! ip link show "$IFACE" &>/dev/null; then
  echo "ERROR: interface '$IFACE' does not exist." >&2
  ip -br link show >&2
  exit 1
fi

echo "=== Go2 network setup ==="
echo "Interface : $IFACE"
echo "PC IP     : $PC_IP/$PREFIX"
echo "Robot IP  : $ROBOT_IP"
if [[ $TEMP_MODE -eq 1 ]]; then
  MODE_DESC="temporary (ip addr)"
else
  MODE_DESC="persistent (NetworkManager)"
fi
echo "Mode      : $MODE_DESC"
echo

# --- Configure the IP address ---
if [[ $TEMP_MODE -eq 1 ]]; then
  echo "[1/4] Flushing existing IPv4 addresses on $IFACE and assigning $PC_IP/$PREFIX (temporary)..."
  sudo ip addr flush dev "$IFACE" scope global
  sudo ip addr add "$PC_IP/$PREFIX" dev "$IFACE"
  sudo ip link set "$IFACE" up
else
  echo "[1/4] Configuring a persistent static-IP profile via NetworkManager..."
  if ! command -v nmcli &>/dev/null; then
    echo "ERROR: nmcli not found. Re-run with -t for a temporary ip-command based setup." >&2
    exit 1
  fi

  CON_NAME=$(nmcli -t -f DEVICE,NAME con show --active | awk -F: -v d="$IFACE" '$1==d{print $2}')
  if [[ -z "$CON_NAME" ]]; then
    CON_NAME=$(nmcli -t -f DEVICE,NAME con show | awk -F: -v d="$IFACE" '$1==d{print $2; exit}')
  fi
  if [[ -z "$CON_NAME" ]]; then
    echo "  No existing connection profile bound to $IFACE; creating one named 'go2-eth'."
    sudo nmcli con add type ethernet ifname "$IFACE" con-name go2-eth
    CON_NAME="go2-eth"
  fi
  echo "  Using connection profile: $CON_NAME"

  sudo nmcli con mod "$CON_NAME" ipv4.addresses "$PC_IP/$PREFIX"
  sudo nmcli con mod "$CON_NAME" ipv4.gateway ""
  sudo nmcli con mod "$CON_NAME" ipv4.dns ""
  sudo nmcli con mod "$CON_NAME" ipv4.ignore-auto-dns yes
  sudo nmcli con mod "$CON_NAME" ipv4.method manual
  sudo nmcli con mod "$CON_NAME" connection.autoconnect yes

  echo "  Bringing connection up..."
  sudo nmcli con down "$CON_NAME" &>/dev/null || true
  sudo nmcli con up "$CON_NAME"
fi

echo
echo "[2/4] Current address on $IFACE:"
ip -4 addr show "$IFACE"
echo

# --- Ping the robot ---
echo "[3/4] Pinging robot at $ROBOT_IP..."
if ping -c 4 -W 2 "$ROBOT_IP"; then
  echo "  Ping OK."
else
  echo "  Ping FAILED. Check cable, that the robot is powered on, and that $IFACE has link (ip -br link show $IFACE)." >&2
fi
echo

# --- UFW check (root cause from prior debugging session) ---
echo "[4/4] Checking UFW (this blocked all Go2 DDS multicast traffic on the previous machine even though ping worked)..."
if command -v ufw &>/dev/null; then
  UFW_STATUS=$(sudo ufw status verbose 2>/dev/null || echo "unknown")
  echo "$UFW_STATUS"
  if echo "$UFW_STATUS" | grep -qi "Status: active"; then
    if ! echo "$UFW_STATUS" | grep -qE "on ${IFACE}\b|Anywhere on ${IFACE}"; then
      echo
      echo "  WARNING: UFW is active and no rule explicitly allows traffic on $IFACE."
      echo "  This is the exact scenario that silently dropped all Go2 DDS packets last time"
      echo "  (ping/tcpdump looked fine, but no UDP payload ever reached the SDK)."
      read -r -p "  Add 'sudo ufw allow in on $IFACE' now? [y/N] " ans
      if [[ "$ans" =~ ^[Yy]$ ]]; then
        sudo ufw allow in on "$IFACE"
        sudo ufw reload
        echo "  Rule added and UFW reloaded."
      else
        echo "  Skipped. Remember: DDS will report all-zero sensor data if this isn't fixed."
      fi
    else
      echo "  OK: a rule for $IFACE already exists."
    fi
  else
    echo "  UFW is inactive; no firewall interference expected."
  fi
else
  echo "  ufw not installed; skipping firewall check."
fi

echo
echo "=== Done ==="
echo "Next: run your DDS probe / unitree_sdk2 example, e.g.:"
echo "  ~/go2_guide_docs/tools/dds_probe 10   (with CYCLONEDDS_URI pointed at $IFACE)"
echo "  ./go2_stand_example $IFACE"
