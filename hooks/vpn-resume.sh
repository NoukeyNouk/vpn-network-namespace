#!/bin/bash
# vpn-resume.sh — Systemd sleep hook to restart VPN after waking from suspend
# Target location: /usr/lib/systemd/system-sleep/vpn-resume.sh

if [ "$1" = "post" ]; then
  if systemctl is-active --quiet sing-box 2>/dev/null; then
    logger -t vpn-resume "System resumed from suspend. Refreshing VPN stack..."
    systemctl restart sing-box sing-vpn.service 2>/dev/null || systemctl restart sing-box amnezia-vpn 2>/dev/null || systemctl restart sing-box
  fi
fi
