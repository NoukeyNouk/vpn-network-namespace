#!/bin/bash
# setup-netns.sh

# Exit on any error
set -e

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (e.g. sudo ./setup-netns.sh)"
  exit 1
fi

NETNS="amnezia-vpn"
IFACE="awg0"
CONF_FILE="$(dirname "$(readlink -f "$0")")/awg0.conf"
WG_IP="10.8.1.12/32"
DNS1="1.1.1.1"
DNS2="1.0.0.1"

echo "Checking if namespace $NETNS already exists..."
if ip netns list | grep -q "^$NETNS\b"; then
  echo "Namespace $NETNS already exists. Run teardown-netns.sh first."
  exit 1
fi

echo "Creating network namespace $NETNS..."
ip netns add $NETNS

# Bring up loopback in the namespace
ip netns exec $NETNS ip link set dev lo up

echo "Creating AmneziaWG interface $IFACE in main namespace..."
# Try to add amneziawg interface via kernel module first
if ! ip link add $IFACE type amneziawg 2>/dev/null; then
    echo "Kernel module not found or failed, falling back to amneziawg-go..."
    # Set the env var to bypass the kernel check in amneziawg-go
    WG_I_PREFER_BUGGY_USERSPACE_TO_POLISHED_KMOD=1 amneziawg-go $IFACE
fi

echo "Moving $IFACE to namespace $NETNS..."
ip link set $IFACE netns $NETNS

echo "Configuring $IFACE inside namespace..."
# Set the configuration from the file
ip netns exec $NETNS awg setconf $IFACE "$CONF_FILE"

# Assign IP address
ip netns exec $NETNS ip address add $WG_IP dev $IFACE

# Bring up the interface
ip netns exec $NETNS ip link set dev $IFACE up

echo "Configuring routing inside namespace..."
# Route everything over the VPN interface
ip netns exec $NETNS ip route add default dev $IFACE

echo "Setting up DNS for namespace..."
mkdir -p /etc/netns/$NETNS
cat <<EOF > /etc/netns/$NETNS/resolv.conf
nameserver $DNS1
nameserver $DNS2
EOF

echo "Done! The VPN virtual network is ready."
echo "Use './run-vpn.sh <command>' to run applications inside it."
