#!/bin/bash
# Install only. Service activation is a separate, explicit operation.
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run as root' >&2; exit 1; }
DIR="$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
for cmd in ip curl flock systemctl awk; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done
install -d -o root -g root -m 0755 /usr/local/lib/mega-vpn /etc/mega-vpn
for script in vpn-common.sh setup-netns.sh teardown-netns.sh vpn-watchdog.sh vpn-ping.sh run-vpn.sh; do
  bash -n "$DIR/$script"
  install -o root -g root -m 0755 "$DIR/$script" "/usr/local/lib/mega-vpn/$script"
done
for unit in sing-vpn.service vpn-watchdog.service; do
  install -o root -g root -m 0644 "$DIR/$unit" "/etc/systemd/system/$unit"
done
ln -sfn /usr/local/lib/mega-vpn/vpn-ping.sh /usr/local/bin/vpn-ping
ln -sfn /usr/local/lib/mega-vpn/run-vpn.sh /usr/local/bin/run-vpn
# Replace this project's old restart hooks with inert compatibility stubs.
if [[ -d /etc/NetworkManager/dispatcher.d ]]; then
  install -o root -g root -m 0755 "$DIR/hooks/99-vpn-reconnect.sh" /etc/NetworkManager/dispatcher.d/99-vpn-reconnect.sh
fi
if [[ -d /usr/lib/systemd/system-sleep ]]; then
  install -o root -g root -m 0755 "$DIR/hooks/vpn-resume.sh" /usr/lib/systemd/system-sleep/vpn-resume.sh
fi
systemctl daemon-reload
printf '%s\n' 'Installed. No services were started, stopped, enabled or restarted.' \
  'Review README.md before activation or migration from amnezia-vpn.service.'
