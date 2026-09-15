#!/bin/bash
# 99-vpn-reconnect.sh — NetworkManager dispatcher script for automatic VPN recovery
# Target location: /etc/NetworkManager/dispatcher.d/99-vpn-reconnect.sh

IFACE="$1"
ACTION="$2"

if [ "$ACTION" = "up" ] || [ "$ACTION" = "connectivity-change" ]; then
  # Ignore virtual interfaces
  case "$IFACE" in
    lo|neko-tun*|tun*|awg*|veth*)
      exit 0
      ;;
  esac

  if systemctl is-active --quiet sing-box 2>/dev/null; then
    logger -t vpn-dispatcher "Interface $IFACE changed state to $ACTION. Refreshing VPN connection..."
    systemctl restart sing-box sing-vpn.service 2>/dev/null || systemctl restart sing-box amnezia-vpn 2>/dev/null || systemctl restart sing-box
  fi
fi
