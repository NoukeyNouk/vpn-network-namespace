#!/bin/bash
# install-services.sh — Install and enable systemd services and auto-recovery hooks
# Run with: sudo ./install-services.sh

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run as root:"
  echo "  sudo ./install-services.sh"
  exit 1
fi

DIR="$(dirname "$(readlink -f "$0")")"

echo "=== Installing VPN Services and Recovery Hooks ==="

# 1. Make all scripts executable
chmod +x "$DIR"/*.sh "$DIR"/hooks/*.sh 2>/dev/null || true

# 2. Disable legacy amnezia-vpn.service if it was enabled
if systemctl is-enabled amnezia-vpn.service >/dev/null 2>&1; then
  echo "Disabling old amnezia-vpn.service..."
  systemctl stop amnezia-vpn.service 2>/dev/null || true
  systemctl disable amnezia-vpn.service 2>/dev/null || true
  rm -f /etc/systemd/system/amnezia-vpn.service
fi

# 3. Install sing-vpn.service
echo "[1/6] Installing sing-vpn.service..."
cp "$DIR/sing-vpn.service" /etc/systemd/system/sing-vpn.service
chmod 644 /etc/systemd/system/sing-vpn.service

# 4. Install vpn-watchdog.service
echo "[2/6] Installing vpn-watchdog.service..."
cp "$DIR/vpn-watchdog.service" /etc/systemd/system/vpn-watchdog.service
chmod 644 /etc/systemd/system/vpn-watchdog.service

# 5. Install vpn-ping into /usr/local/bin
echo "[3/6] Installing vpn-ping to /usr/local/bin..."
ln -sf "$DIR/vpn-ping.sh" /usr/local/bin/vpn-ping

# 6. Install NetworkManager dispatcher hook (if directory exists)
if [ -d /etc/NetworkManager/dispatcher.d ]; then
  echo "[4/6] Installing NetworkManager reconnect hook..."
  cp "$DIR/hooks/99-vpn-reconnect.sh" /etc/NetworkManager/dispatcher.d/99-vpn-reconnect.sh
  chmod 755 /etc/NetworkManager/dispatcher.d/99-vpn-reconnect.sh
else
  echo "[4/6] NetworkManager dispatcher directory not found, skipping."
fi

# 7. Install systemd sleep hook for suspend/resume
if [ -d /usr/lib/systemd/system-sleep ]; then
  echo "[5/6] Installing systemd suspend/resume hook..."
  cp "$DIR/hooks/vpn-resume.sh" /usr/lib/systemd/system-sleep/vpn-resume.sh
  chmod 755 /usr/lib/systemd/system-sleep/vpn-resume.sh
else
  echo "[5/6] Systemd sleep directory not found, skipping."
fi

# 8. Reload systemd daemon and enable services
echo "[6/6] Reloading systemd daemon and enabling services..."
systemctl daemon-reload
systemctl enable sing-vpn.service
systemctl enable vpn-watchdog.service

# Restart services cleanly
systemctl restart sing-box
systemctl restart sing-vpn.service
systemctl restart vpn-watchdog.service

echo ""
echo "=== Installation complete! ==="
echo "Services active:"
echo "  • sing-box.service:       $(systemctl is-active sing-box 2>/dev/null || echo 'inactive')"
echo "  • sing-vpn.service:       $(systemctl is-active sing-vpn.service 2>/dev/null || echo 'inactive')"
echo "  • vpn-watchdog.service:   $(systemctl is-active vpn-watchdog.service 2>/dev/null || echo 'inactive')"
echo ""
echo "Try running:"
echo "  vpn-ping"
echo "  vpn-ping -c 3"
echo "  vpn-ping --help"
