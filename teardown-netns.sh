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

echo "Cleaning up namespace $NETNS..."
if ip netns list | grep -q "^$NETNS\b"; then
  # Note: Deleting the namespace automatically deletes the virtual interfaces (like awg0) inside it
  ip netns delete $NETNS
  echo "Namespace $NETNS deleted."
else
  echo "Namespace $NETNS does not exist. Nothing to do."
fi

# Clean up DNS settings directory
if [ -d "/etc/netns/$NETNS" ]; then
  rm -rf "/etc/netns/$NETNS"
  echo "Removed /etc/netns/$NETNS directory."
fi

echo "Teardown complete."
