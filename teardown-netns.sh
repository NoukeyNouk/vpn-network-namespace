#!/bin/bash
# teardown-netns.sh

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (e.g. sudo ./teardown-netns.sh)"
  exit 1
fi

NETNS="${NETNS:-hy2-vpn}"
IFACE="${IFACE:-neko-tun}"

echo "Cleaning up namespace $NETNS..."

if ip netns list 2>/dev/null | grep -q "^$NETNS\b"; then
  # Return sing-box interface back to main namespace before deleting netns
  if ip netns exec "$NETNS" ip link show "$IFACE" >/dev/null 2>&1; then
    echo "Returning $IFACE to main namespace..."
    ip netns exec "$NETNS" ip link set "$IFACE" netns 1 2>/dev/null || true
  fi

  # Also check if any other neko-tun or hy2tun or tun interfaces are stuck in netns
  for fallback_iface in hy2tun awg0; do
    if ip netns exec "$NETNS" ip link show "$fallback_iface" >/dev/null 2>&1; then
      echo "Returning $fallback_iface to main namespace..."
      ip netns exec "$NETNS" ip link set "$fallback_iface" netns 1 2>/dev/null || true
    fi
  done

  # Delete the namespace
  ip netns delete "$NETNS" 2>/dev/null || true
  echo "Namespace $NETNS deleted."
else
  echo "Namespace $NETNS does not exist."
fi

# Remove DNS settings directory for this netns
if [ -d "/etc/netns/$NETNS" ]; then
  rm -rf "/etc/netns/$NETNS"
  echo "Removed /etc/netns/$NETNS directory."
fi

echo "Teardown complete."
