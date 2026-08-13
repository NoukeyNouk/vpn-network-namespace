#!/bin/bash
# setup-netns.sh
# Resilient AmneziaWG network namespace setup script.
# Supports both kernel module and amneziawg-go (userspace) modes.
#
# Kernel module mode:
#   Creates awg0 in main ns → moves to amnezia-vpn ns → configures.
#   The kernel handles the UDP socket internally, no extra plumbing needed.
#
# Userspace (amneziawg-go) mode:
#   Creates a veth pair to bridge the namespace to the host network.
#   Runs amneziawg-go inside the namespace so the TUN stays in the same ns.
#   Routes only the VPN endpoint traffic through the veth pair (NAT);
#   all other traffic goes through the awg0 tunnel.

# Exit on any error
set -e

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (e.g. sudo ./setup-netns.sh)"
  exit 1
fi

NETNS="amnezia-vpn"
IFACE="awg0"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CONF_FILE="$SCRIPT_DIR/awg0.conf"

# veth pair settings (used only in userspace mode)
VETH_HOST="veth-awg-host"
VETH_NS="veth-awg-ns"
VETH_HOST_IP="10.200.200.1/30"
VETH_NS_IP="10.200.200.2/30"
VETH_HOST_GW="10.200.200.1"

# ────────────────────────────────────────────────────────────────
# Phase 0: Ensure the kernel module is loaded (auto-rebuild DKMS if needed)
# ────────────────────────────────────────────────────────────────
ensure_module_loaded() {
    if lsmod | grep -q '^amneziawg '; then
        echo "AmneziaWG kernel module is already loaded."
        USE_KERNEL_MODULE=1
        return 0
    fi

    echo "AmneziaWG module not loaded. Attempting to load..."
    if modprobe amneziawg 2>/dev/null; then
        echo "Module loaded successfully."
        USE_KERNEL_MODULE=1
        return 0
    fi

    echo "Module failed to load. Checking DKMS..."
    local KVER
    KVER=$(uname -r)

    # Check if any amneziawg DKMS module is registered
    if dkms status 2>/dev/null | grep -q 'amneziawg'; then
        local DKMS_VER
        DKMS_VER=$(dkms status 2>/dev/null | grep 'amneziawg' | head -1 | awk -F'[/,]' '{print $2}' | tr -d ' ')

        echo "Rebuilding amneziawg DKMS module (version $DKMS_VER) for kernel $KVER..."
        dkms remove amneziawg/"$DKMS_VER" -k "$KVER" 2>/dev/null || true
        dkms install amneziawg/"$DKMS_VER" -k "$KVER" 2>/dev/null

        if modprobe amneziawg 2>/dev/null; then
            echo "Module rebuilt and loaded successfully."
            USE_KERNEL_MODULE=1
            return 0
        fi
    fi

    # DKMS doesn't know about the module — try to find and register it from /usr/src
    local SRC_DIR
    SRC_DIR=$(find /usr/src -maxdepth 1 -name 'amneziawg-*' -type d 2>/dev/null | head -1)
    if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/dkms.conf" ]; then
        local DIR_VER
        DIR_VER=$(basename "$SRC_DIR" | sed 's/amneziawg-//')
        echo "Found DKMS source in $SRC_DIR (version $DIR_VER). Registering and building..."
        dkms add amneziawg/"$DIR_VER" 2>/dev/null || true
        dkms install amneziawg/"$DIR_VER" -k "$KVER" 2>/dev/null

        if modprobe amneziawg 2>/dev/null; then
            echo "Module built from source and loaded successfully."
            USE_KERNEL_MODULE=1
            return 0
        fi
    fi

    # All kernel module methods failed — fall back to amneziawg-go
    if command -v amneziawg-go &>/dev/null; then
        echo "WARNING: Kernel module unavailable. Will use amneziawg-go (userspace) instead."
        USE_KERNEL_MODULE=0
        return 0
    fi

    echo "ERROR: No amneziawg kernel module or amneziawg-go found."
    echo "  Install kernel module: yay -S amneziawg-dkms"
    echo "  Or install userspace:  sudo pacman -S amneziawg-go"
    exit 1
}

# ────────────────────────────────────────────────────────────────
# Phase 1: Validate config file
# ────────────────────────────────────────────────────────────────
validate_config() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "ERROR: Config file not found: $CONF_FILE"
        exit 1
    fi

    # Check if module is AWG 3.0 — if so, config must have S3/S4
    local MOD_VER
    MOD_VER=$(modinfo amneziawg 2>/dev/null | grep '^version:' | awk '{print $2}' || echo "unknown")

    if echo "$MOD_VER" | grep -q '^3\.'; then
        if ! grep -qi '^S3' "$CONF_FILE" || ! grep -qi '^S4' "$CONF_FILE"; then
            echo "WARNING: Kernel module is AWG 3.0 ($MOD_VER) but config lacks S3/S4 parameters."
            # Check for .awg0.conf backup with AWG 3.0 format
            if [ -f "$SCRIPT_DIR/.awg0.conf" ] && grep -qi '^S3' "$SCRIPT_DIR/.awg0.conf"; then
                echo "Found .awg0.conf with AWG 3.0 format. Switching to it..."
                cp "$SCRIPT_DIR/.awg0.conf" "$CONF_FILE"
                echo "Config updated to AWG 3.0 format."
            else
                echo "ERROR: You need an AWG 3.0 compatible config with S3 and S4 parameters."
                echo "Please regenerate your config from the AmneziaVPN client."
                exit 1
            fi
        fi
    fi
}

# ────────────────────────────────────────────────────────────────
# Phase 2: Setup veth pair for userspace mode
# ────────────────────────────────────────────────────────────────
setup_veth_bridge() {
    local ENDPOINT_IP="$1"

    echo "Setting up veth bridge for userspace mode..."

    # Create veth pair: one end in main ns, other end in our ns
    ip link add $VETH_HOST type veth peer name $VETH_NS

    # Move one end into the namespace
    ip link set $VETH_NS netns $NETNS

    # Configure host end
    ip addr add $VETH_HOST_IP dev $VETH_HOST
    ip link set $VETH_HOST up

    # Configure namespace end
    ip netns exec $NETNS ip addr add $VETH_NS_IP dev $VETH_NS
    ip netns exec $NETNS ip link set $VETH_NS up

    # Add route in namespace: VPN endpoint goes through veth (not through awg0)
    ip netns exec $NETNS ip route add "$ENDPOINT_IP/32" via $VETH_HOST_GW dev $VETH_NS

    # Enable IP forwarding on host
    sysctl -q -w net.ipv4.ip_forward=1

    # Add iptables MASQUERADE rule so namespace traffic can reach the internet
    # (only for traffic from the veth subnet)
    iptables -t nat -A POSTROUTING -s 10.200.200.0/30 -j MASQUERADE 2>/dev/null || \
    nft add rule ip nat POSTROUTING ip saddr 10.200.200.0/30 masquerade 2>/dev/null || \
    echo "WARNING: Could not add NAT rule. VPN endpoint may be unreachable."

    echo "Veth bridge ready: $VETH_HOST <-> $VETH_NS"
}

# ────────────────────────────────────────────────────────────────
# Parse config values
# ────────────────────────────────────────────────────────────────
WG_IP=$(grep -m 1 -i '^Address' "$CONF_FILE" | awk -F '=' '{print $2}' | tr -d ' ')
DNS_LIST=$(grep -m 1 -i '^DNS' "$CONF_FILE" | awk -F '=' '{print $2}' | tr -d ' ')
DNS1=$(echo "$DNS_LIST" | cut -d ',' -f 1)
DNS2=$(echo "$DNS_LIST" | cut -d ',' -f 2)
ENDPOINT_IP=$(grep -m 1 -i '^Endpoint' "$CONF_FILE" | awk -F '=' '{print $2}' | tr -d ' ' | cut -d ':' -f 1)

# ────────────────────────────────────────────────────────────────
# Main setup
# ────────────────────────────────────────────────────────────────

echo "Checking if namespace $NETNS already exists..."
if ip netns list | grep -q "^$NETNS\b"; then
  echo "Namespace $NETNS already exists. Run teardown-netns.sh first."
  exit 1
fi

# Ensure module is available
ensure_module_loaded

# Validate config matches module version
validate_config

# Re-parse config in case validate_config updated it
WG_IP=$(grep -m 1 -i '^Address' "$CONF_FILE" | awk -F '=' '{print $2}' | tr -d ' ')
DNS_LIST=$(grep -m 1 -i '^DNS' "$CONF_FILE" | awk -F '=' '{print $2}' | tr -d ' ')
DNS1=$(echo "$DNS_LIST" | cut -d ',' -f 1)
DNS2=$(echo "$DNS_LIST" | cut -d ',' -f 2)
ENDPOINT_IP=$(grep -m 1 -i '^Endpoint' "$CONF_FILE" | awk -F '=' '{print $2}' | tr -d ' ' | cut -d ':' -f 1)

echo "Creating network namespace $NETNS..."
ip netns add $NETNS

# Bring up loopback in the namespace
ip netns exec $NETNS ip link set dev lo up

# ── Create interface and configure ──
echo "Creating AmneziaWG interface $IFACE..."

# Prepare stripped config for awg setconf
TMP_CONF=$(mktemp)
awk -v IGNORECASE=1 '/^[ \t]*(Address|MTU|DNS|Table|PreUp|PostUp|PreDown|PostDown|SaveConfig)[ \t]*=/ { next } /^[ \t]*[A-Za-z0-9_]+[ \t]*=[ \t]*\r?$/ { next } { print }' "$CONF_FILE" > "$TMP_CONF"

if [ "${USE_KERNEL_MODULE:-1}" -eq 1 ]; then
    # ── Kernel module mode ──
    # Create interface in main namespace, move it, then configure.
    # The kernel handles the UDP encapsulation socket internally,
    # so it works fine across namespaces without extra routing.
    ip link add $IFACE type amneziawg
    echo "Moving $IFACE to namespace $NETNS..."
    ip link set $IFACE netns $NETNS
    echo "Configuring $IFACE inside namespace..."
    ip netns exec $NETNS awg setconf $IFACE "$TMP_CONF"
else
    # ── Userspace amneziawg-go mode ──
    # amneziawg-go creates a TUN device + a regular UDP socket.
    # Both must live in the same namespace. But the UDP socket needs
    # a route to the VPN endpoint OUTSIDE the tunnel (otherwise it
    # would try to send endpoint traffic through itself → dead loop).
    #
    # Solution: veth pair bridges the namespace to the host network.
    # Explicit route sends only endpoint IP through veth+NAT;
    # default route goes through awg0 (the tunnel).

    # Setup veth bridge BEFORE creating the interface
    setup_veth_bridge "$ENDPOINT_IP"

    echo "Starting amneziawg-go (userspace) inside namespace $NETNS..."
    ip netns exec $NETNS bash -c "WG_I_PREFER_BUGGY_USERSPACE_TO_POLISHED_KMOD=1 amneziawg-go $IFACE"
    # Give amneziawg-go a moment to create the interface
    sleep 1

    echo "Configuring $IFACE inside namespace..."
    ip netns exec $NETNS awg setconf $IFACE "$TMP_CONF"
fi
rm -f "$TMP_CONF"

# Assign IP address
ip netns exec $NETNS ip address add $WG_IP dev $IFACE

# Bring up the interface
ip netns exec $NETNS ip link set dev $IFACE up

echo "Configuring routing inside namespace..."
# Route everything over the VPN interface
ip netns exec $NETNS ip route add default dev $IFACE

echo "Setting up DNS for namespace..."
mkdir -p /etc/netns/$NETNS
echo "nameserver $DNS1" > /etc/netns/$NETNS/resolv.conf
if [ -n "$DNS2" ] && [ "$DNS1" != "$DNS2" ]; then
    echo "nameserver $DNS2" >> /etc/netns/$NETNS/resolv.conf
fi

echo ""
echo "Done! The VPN virtual network is ready."
if [ "${USE_KERNEL_MODULE:-1}" -eq 0 ]; then
    echo "  Mode: userspace (amneziawg-go) with veth bridge"
else
    echo "  Mode: kernel module"
fi
echo "Use './run-vpn.sh <command>' to run applications inside it."
