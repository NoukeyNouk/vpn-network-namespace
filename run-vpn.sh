#!/bin/bash
# run-vpn.sh

set -euo pipefail
SCRIPT_DIR="$(dirname -- "$(readlink -f -- "$0")")"
if [[ -r "$SCRIPT_DIR/vpn-common.sh" ]]; then
  source "$SCRIPT_DIR/vpn-common.sh"
elif [[ -r /usr/local/lib/mega-vpn/vpn-common.sh ]]; then
  # Legacy /usr/bin/run-vpn may be a hard link, not a resolvable symlink.
  source /usr/local/lib/mega-vpn/vpn-common.sh
else
  echo 'VPN support files not found. Install with install-services.sh.' >&2
  exit 1
fi

if [ $# -eq 0 ]; then
  echo "Usage: $0 <command> [args...]"
  echo "Example: $0 curl ipinfo.io"
  echo "         $0 firefox"
  exit 1
fi

# Codex workaround
if [ "$1" = "codex" ]; then
    shift
    set -- codex -c "log_dir=\"$HOME/.codex/log\"" "$@"
fi

# Check if we are already inside the target namespace
CURRENT_NS=$(ip netns identify $$ 2>/dev/null || true)
if [ "$CURRENT_NS" = "$NETNS" ]; then
  exec "$@"
fi

if ! namespace_exists; then
  echo "Error: Namespace '$NETNS' does not exist."
  echo "Please start the service with: sudo systemctl start sing-vpn"
  echo "Or manually run: sudo ./setup-netns.sh"
  exit 1
fi

# Run the command inside the network namespace as the current user
if [ "$EUID" -eq 0 ]; then
  # Already running as root
  exec ip netns exec "$NETNS" "$@"
else
  # Capture environment variables before sudo strips them
  CUR_DISPLAY="${DISPLAY:-}"
  CUR_XAUTH="${XAUTHORITY:-}"
  CUR_WAYLAND="${WAYLAND_DISPLAY:-}"
  CUR_XDG="${XDG_RUNTIME_DIR:-}"
  CUR_DBUS="${DBUS_SESSION_BUS_ADDRESS:-}"

  USER_ID=$(id -u)
  PULSE_SOCK="unix:/run/user/$USER_ID/pulse/native"

  exec sudo ip netns exec "$NETNS" sudo -H -u "$(id -un)" \
    DISPLAY="$CUR_DISPLAY" \
    XAUTHORITY="$CUR_XAUTH" \
    WAYLAND_DISPLAY="$CUR_WAYLAND" \
    XDG_RUNTIME_DIR="$CUR_XDG" \
    DBUS_SESSION_BUS_ADDRESS="$CUR_DBUS" \
    PULSE_SERVER="$PULSE_SOCK" \
    "$@"
fi
