#!/bin/bash
# vpn-watchdog.sh — Self-healing watchdog for hy2-vpn (sing-box)

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Error: vpn-watchdog must run as root to monitor namespaces and restart services."
  echo "Usage: sudo ./vpn-watchdog.sh [--once]"
  echo "Or enable via systemd: sudo systemctl enable --now vpn-watchdog.service"
  exit 1
fi

NETNS="${NETNS:-hy2-vpn}"
IFACE="${IFACE:-neko-tun}"
CHECK_URL="http://cp.cloudflare.com/generate_204"
CHECK_INTERVAL=20
MAX_FAILURES=2

FAIL_COUNT=0

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [vpn-watchdog] $*"
}

# Check connectivity inside netns
check_vpn_online() {
  ip netns exec "$NETNS" curl -s -o /dev/null -m 4 --connect-timeout 2 "$CHECK_URL" 2>/dev/null
}

# Check connectivity on host (main namespace)
check_host_online() {
  curl -s -o /dev/null -m 3 --connect-timeout 2 "$CHECK_URL" 2>/dev/null || \
  curl -s -o /dev/null -m 3 --connect-timeout 2 "http://1.1.1.1" 2>/dev/null
}

run_check_once() {
  # 1. Do not interfere if sing-box is intentionally stopped
  if ! systemctl is-active --quiet sing-box 2>/dev/null; then
    return 0
  fi

  # 2. Check if namespace exists
  if ! ip netns list 2>/dev/null | grep -q "^$NETNS\b"; then
    log "Namespace $NETNS is missing while sing-box is active! Restarting sing-vpn service..."
    systemctl restart sing-vpn.service 2>/dev/null || systemctl restart amnezia-vpn.service 2>/dev/null || bash "$(dirname "$0")/setup-netns.sh"
    return 0
  fi

  # 3. Check if interface is inside netns
  if ! ip netns exec "$NETNS" ip link show "$IFACE" >/dev/null 2>&1; then
    log "Interface $IFACE missing in namespace $NETNS! Restarting sing-box and sing-vpn..."
    systemctl restart sing-box sing-vpn.service 2>/dev/null || systemctl restart sing-box amnezia-vpn.service 2>/dev/null || systemctl restart sing-box
    return 0
  fi

  # 4. Probe VPN connectivity
  if check_vpn_online; then
    FAIL_COUNT=0
    return 0
  fi

  # Failed probe: brief pause and retry to filter transient glitches
  sleep 2
  if check_vpn_online; then
    FAIL_COUNT=0
    return 0
  fi

  # VPN probe failed. Now verify if host itself has internet
  if ! check_host_online; then
    # Machine has no network connection at all (e.g. Wi-Fi disconnected)
    log "Host network is currently offline. Waiting for network connectivity..."
    FAIL_COUNT=0
    return 0
  fi

  # Host is online, but VPN tunnel inside namespace is unresponsive
  FAIL_COUNT=$((FAIL_COUNT + 1))
  log "VPN probe failed ($FAIL_COUNT/$MAX_FAILURES) while host is online."

  if [ "$FAIL_COUNT" -ge "$MAX_FAILURES" ]; then
    log "Auto-recovery triggered: Restarting sing-box and sing-vpn services..."
    systemctl restart sing-box sing-vpn.service 2>/dev/null || systemctl restart sing-box amnezia-vpn.service 2>/dev/null || systemctl restart sing-box
    FAIL_COUNT=0
    # Wait for re-initialization
    sleep 5
  fi
}

if [ "${1:-}" = "--once" ]; then
  run_check_once
  exit 0
fi

log "Starting VPN auto-healing watchdog daemon (check interval: ${CHECK_INTERVAL}s)..."

while true; do
  run_check_once || true
  sleep "$CHECK_INTERVAL"
done
