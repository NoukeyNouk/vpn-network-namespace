#!/bin/bash
# install-service.sh

# Exit on any error
set -e

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (e.g. sudo ./install-service.sh)"
  exit 1
fi

DIR="$(dirname "$(readlink -f "$0")")"
SERVICE_FILE="/etc/systemd/system/amnezia-vpn-netns.service"

echo "Creating systemd service file..."
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=AmneziaWG Network Namespace (amnezia-vpn)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$DIR/setup-netns.sh
ExecStop=$DIR/teardown-netns.sh

[Install]
WantedBy=multi-user.target
EOF

echo "Reloading systemd daemon..."
systemctl daemon-reload

echo "Enabling service to start on boot..."
systemctl enable amnezia-vpn-netns.service

echo "Starting the service now..."
systemctl start amnezia-vpn-netns.service

echo "Done! The VPN network namespace is now running and will start automatically on boot."
echo "You can check its status anytime with: systemctl status amnezia-vpn-netns.service"
