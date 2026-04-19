#!/bin/bash
# run-vpn.sh

NETNS="amnezia-vpn"

if [ $# -eq 0 ]; then
  echo "Usage: $0 <command> [args...]"
  echo "Example: $0 curl ifconfig.me"
  exit 1
fi

if ! ip netns list | grep -q "^$NETNS\b"; then
  echo "Error: Namespace $NETNS does not exist."
  echo "Please run 'sudo ./setup-netns.sh' first."
  exit 1
fi

# Run the command inside the network namespace as the current user
# sudo is required to execute in the netns, but we switch back to the original user using 'sudo -u'
if [ "$EUID" -eq 0 ]; then
    # Already running as root
    ip netns exec $NETNS "$@"
else
    # Capture environment variables before the first sudo strips them
    CUR_DISPLAY="$DISPLAY"
    CUR_XAUTH="$XAUTHORITY"
    CUR_WAYLAND="$WAYLAND_DISPLAY"
    CUR_XDG="$XDG_RUNTIME_DIR"
    CUR_DBUS="$DBUS_SESSION_BUS_ADDRESS"
    
    USER_ID=$(id -u)
    # If they use pulse
    PULSE_SOCK="unix:/run/user/$USER_ID/pulse/native"

    sudo ip netns exec $NETNS sudo -u "$USER" \
        DISPLAY="$CUR_DISPLAY" \
        XAUTHORITY="$CUR_XAUTH" \
        WAYLAND_DISPLAY="$CUR_WAYLAND" \
        XDG_RUNTIME_DIR="$CUR_XDG" \
        DBUS_SESSION_BUS_ADDRESS="$CUR_DBUS" \
        PULSE_SERVER="$PULSE_SOCK" \
        "$@"
fi
