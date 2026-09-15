#!/bin/bash
# setup-netns.sh

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (e.g. sudo ./setup-netns.sh)"
  exit 1
fi

DIR="$(dirname "$(readlink -f "$0")")"
NETNS="${NETNS:-hy2-vpn}"
IFACE="${IFACE:-neko-tun}"
WG_IP="${WG_IP:-172.19.0.2/28}"
DNS1="${DNS1:-1.1.1.1}"
DNS2="${DNS2:-8.8.8.8}"

# If namespace already exists, check if it's already properly configured
if ip netns list 2>/dev/null | grep -q "^$NETNS\b"; then
  if ip netns exec "$NETNS" ip link show "$IFACE" >/dev/null 2>&1; then
    echo "Namespace $NETNS and interface $IFACE already exist and are active."
    # Ensure loopback and interface are UP
    ip netns exec "$NETNS" ip link set dev lo up 2>/dev/null || true
    ip netns exec "$NETNS" ip link set dev "$IFACE" up 2>/dev/null || true
    ip netns exec "$NETNS" ip route replace default dev "$IFACE" 2>/dev/null || true
    mkdir -p "/etc/netns/$NETNS"
    cat <<EOF > "/etc/netns/$NETNS/resolv.conf"
nameserver $DNS1
nameserver $DNS2
EOF
    echo "Namespace $NETNS is ready and healthy."
    exit 0
  else
    echo "Namespace $NETNS exists without $IFACE. Performing clean reset..."
    bash "$DIR/teardown-netns.sh" || true
  fi
fi

# Wait dynamically for sing-box to create the interface in the main namespace
echo "Waiting for interface $IFACE to be created by sing-box..."
FOUND=0
for i in {1..30}; do
  if ip link show "$IFACE" >/dev/null 2>&1; then
    FOUND=1
    break
  fi
  sleep 0.5
done

if [ "$FOUND" -ne 1 ]; then
  echo "Error: Interface $IFACE not found after waiting 15s. Is sing-box running?"
  echo "Try: systemctl status sing-box"
  exit 1
fi

echo "Creating network namespace $NETNS..."
ip netns add "$NETNS"

# Bring up loopback inside namespace
ip netns exec "$NETNS" ip link set dev lo up

echo "Moving $IFACE to namespace $NETNS..."
ip link set "$IFACE" netns "$NETNS"

echo "Configuring $IFACE inside namespace..."
ip netns exec "$NETNS" ip address add "$WG_IP" dev "$IFACE"
ip netns exec "$NETNS" ip link set dev "$IFACE" up

echo "Configuring routing inside namespace..."
ip netns exec "$NETNS" ip route replace default dev "$IFACE"

echo "Setting up DNS for namespace..."
mkdir -p "/etc/netns/$NETNS"
cat <<EOF > "/etc/netns/$NETNS/resolv.conf"
nameserver $DNS1
nameserver $DNS2
EOF

echo "Done! The VPN virtual network ($NETNS) is ready."
