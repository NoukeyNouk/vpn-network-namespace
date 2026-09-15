#!/bin/bash
# teardown-netns.sh — Teardown or reset sing-box network namespace
# Preserves the namespace when applications are running so they don't break on restart.

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (e.g. sudo ./teardown-netns.sh)"
  exit 1
fi

NETNS="${NETNS:-hy2-vpn}"
IFACE="${IFACE:-neko-tun}"

FORCE_DELETE=0
if [ "${1:-}" = "--delete" ] || [ "${1:-}" = "--force" ] || [ "${1:-}" = "-f" ]; then
  FORCE_DELETE=1
fi

echo "Cleaning up namespace $NETNS..."

if ip netns list 2>/dev/null | grep -q "^$NETNS\b"; then
  # 1. Safely return sing-box interface back to main namespace
  if ip netns exec "$NETNS" ip link show "$IFACE" >/dev/null 2>&1; then
    echo "Returning $IFACE to main namespace..."
    ip netns exec "$NETNS" ip link set "$IFACE" netns 1 2>/dev/null || true
  fi

  # Also check other potential virtual interfaces
  for fallback_iface in hy2tun awg0; do
    if ip netns exec "$NETNS" ip link show "$fallback_iface" >/dev/null 2>&1; then
      echo "Returning $fallback_iface to main namespace..."
      ip netns exec "$NETNS" ip link set "$fallback_iface" netns 1 2>/dev/null || true
    fi
  done

  # 2. Check if applications are running in this namespace
  RUNNING_PIDS=$(ip netns pids "$NETNS" 2>/dev/null || true)
  if [ -n "$RUNNING_PIDS" ] && [ "$FORCE_DELETE" -eq 0 ]; then
    echo "Notice: Active processes detected in $NETNS (PIDs: $(echo $RUNNING_PIDS | tr '\n' ' '))."
    echo "Preserving network namespace so running applications do not need to be restarted."
    echo "Soft teardown complete. Start the service again to restore internet to running apps."
    exit 0
  fi

  # 3. If no processes or forced, delete the namespace
  echo "Deleting namespace $NETNS..."
  ip netns delete "$NETNS" 2>/dev/null || true
  echo "Namespace $NETNS deleted."
else
  echo "Namespace $NETNS does not exist."
fi

# Clean up DNS settings directory if namespace was deleted
if [ "$FORCE_DELETE" -eq 1 ] || ! ip netns list 2>/dev/null | grep -q "^$NETNS\b"; then
  if [ -d "/etc/netns/$NETNS" ]; then
    rm -rf "/etc/netns/$NETNS"
    echo "Removed /etc/netns/$NETNS directory."
  fi
fi

echo "Teardown complete."
