#!/bin/bash
# teardown-netns.sh

# Exit on any error
set -e

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (e.g. sudo ./teardown-netns.sh)"
  exit 1
fi

NETNS="amnezia-vpn"
VETH_HOST="veth-awg-host"

echo "Cleaning up namespace $NETNS..."

# Kill any amneziawg-go userspace processes for our interface
# (they run as daemons and won't stop when the namespace is deleted)
if pgrep -f "amneziawg-go awg0" >/dev/null 2>&1; then
  pkill -f "amneziawg-go awg0" 2>/dev/null || true
  sleep 0.5
  echo "Stopped amneziawg-go process."
fi

if ip netns list | grep -q "^$NETNS\b"; then
  # Note: Deleting the namespace automatically deletes the virtual interfaces (like awg0) inside it
  ip netns delete $NETNS
  echo "Namespace $NETNS deleted."
else
  echo "Namespace $NETNS does not exist. Nothing to do."
fi

# Clean up veth host end (if it exists — used in userspace mode)
if ip link show $VETH_HOST &>/dev/null; then
  ip link delete $VETH_HOST 2>/dev/null || true
  echo "Removed $VETH_HOST interface."
fi

# Remove NAT rules for veth subnet
iptables -t nat -D POSTROUTING -s 10.200.200.0/30 -j MASQUERADE 2>/dev/null || true
# Try nftables too
nft delete rule ip nat POSTROUTING handle \
  $(nft -a list chain ip nat POSTROUTING 2>/dev/null | grep '10.200.200.0/30' | awk '{print $NF}') 2>/dev/null || true

# Clean up DNS settings directory
if [ -d "/etc/netns/$NETNS" ]; then
  rm -rf "/etc/netns/$NETNS"
  echo "Removed /etc/netns/$NETNS directory."
fi

echo "Teardown complete."
