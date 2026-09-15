#!/bin/bash
# setup-netns.sh — Configure network namespace for sing-box VPN
# Designed to be persistent across restarts so running apps do NOT need to be reopened.

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

# 1. Check if namespace already exists and already has the interface working
if ip netns list 2>/dev/null | grep -q "^$NETNS\b"; then
  if ip netns exec "$NETNS" ip link show "$IFACE" >/dev/null 2>&1; then
    echo "Namespace $NETNS and interface $IFACE already exist and are active."
    # Ensure loopback, interface and routes are healthy
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
    echo "Namespace $NETNS already exists (preserving running applications). Waiting for $IFACE..."
  fi
fi

# 2. Wait dynamically for sing-box to create the interface in the main namespace
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

# 3. Create namespace ONLY if it doesn't already exist (keeps existing processes valid!)
if ! ip netns list 2>/dev/null | grep -q "^$NETNS\b"; then
  echo "Creating network namespace $NETNS..."
  ip netns add "$NETNS"
else
  echo "Reusing persistent namespace $NETNS (retaining running applications)..."
fi

# 4. Bring up loopback inside namespace
ip netns exec "$NETNS" ip link set dev lo up 2>/dev/null || true

# 5. Move interface to namespace
echo "Moving $IFACE to namespace $NETNS..."
ip link set "$IFACE" netns "$NETNS"

# 6. Configure interface inside namespace
echo "Configuring $IFACE inside namespace..."
# Remove old IP if any to avoid duplicate address conflicts
ip netns exec "$NETNS" ip address flush dev "$IFACE" 2>/dev/null || true
ip netns exec "$NETNS" ip address add "$WG_IP" dev "$IFACE"
ip netns exec "$NETNS" ip link set dev "$IFACE" up

# 7. Configure default routing inside namespace
echo "Configuring routing inside namespace..."
ip netns exec "$NETNS" ip route replace default dev "$IFACE"

# 8. Set up DNS
echo "Setting up DNS for namespace..."
mkdir -p "/etc/netns/$NETNS"
cat <<EOF > "/etc/netns/$NETNS/resolv.conf"
nameserver $DNS1
nameserver $DNS2
EOF

echo "Done! The VPN virtual network ($NETNS) is ready."
