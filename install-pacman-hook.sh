#!/bin/bash
# install-pacman-hook.sh
# Installs a pacman hook that automatically handles AmneziaWG after kernel updates.
# This ensures the VPN namespace survives pacman -Syu.

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (e.g. sudo ./install-pacman-hook.sh)"
  exit 1
fi

HOOK_DIR="/etc/pacman.d/hooks"
HOOK_FILE="$HOOK_DIR/90-amneziawg-dkms-reload.hook"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

mkdir -p "$HOOK_DIR"

echo "Creating pacman hook: $HOOK_FILE"
cat <<'EOF' > "$HOOK_FILE"
# Automatically rebuild amneziawg DKMS module and restart the VPN namespace
# after kernel upgrades. This makes the VPN survive pacman -Syu.

[Trigger]
Operation = Upgrade
Type = Package
Target = linux
Target = linux-headers
Target = amneziawg-dkms
Target = amneziawg-dkms-git
Target = amneziawg-tools-git

[Action]
Description = Rebuilding AmneziaWG DKMS and restarting VPN namespace...
When = PostTransaction
Exec = /usr/local/bin/amneziawg-post-update.sh
NeedsTargets
EOF

echo "Creating post-update script: /usr/local/bin/amneziawg-post-update.sh"
cat <<SCRIPT > /usr/local/bin/amneziawg-post-update.sh
#!/bin/bash
# amneziawg-post-update.sh
# Called by pacman hook after kernel or amneziawg package updates.
# Rebuilds DKMS module if needed and restarts the VPN namespace service.

LOG="/var/log/amneziawg-post-update.log"
exec >> "\$LOG" 2>&1
echo ""
echo "=== \$(date) — AmneziaWG post-update triggered ==="

KVER=\$(uname -r)

# Read the list of updated packages from stdin (provided by pacman hook NeedsTargets)
while read -r pkg; do
    echo "Updated package: \$pkg"
done

# Check if we need to rebuild (the kernel module might not be built for current kernel)
DKMS_VER=\$(dkms status 2>/dev/null | grep 'amneziawg' | head -1 | awk -F'[/,]' '{print \$2}' | tr -d ' ')

if [ -z "\$DKMS_VER" ]; then
    echo "No amneziawg DKMS module found, skipping."
    exit 0
fi

# Check if module is built for current kernel
if ! dkms status 2>/dev/null | grep 'amneziawg' | grep -q "\$KVER.*installed"; then
    echo "Module not built for kernel \$KVER, rebuilding..."
    dkms install amneziawg/"\$DKMS_VER" -k "\$KVER" 2>&1 || echo "DKMS rebuild failed!"
fi

# Reload the module if it's currently loaded
if lsmod | grep -q '^amneziawg '; then
    echo "Reloading amneziawg module..."
    modprobe -r amneziawg 2>/dev/null || true
    sleep 1
    modprobe amneziawg 2>/dev/null || echo "Failed to reload module (may need reboot)"
fi

# Restart the systemd service if it exists and is enabled
if systemctl is-enabled amnezia-vpn-netns.service 2>/dev/null | grep -q enabled; then
    echo "Restarting amnezia-vpn-netns.service..."
    systemctl restart amnezia-vpn-netns.service 2>&1 || echo "Service restart failed"
fi

echo "=== Post-update complete ==="
SCRIPT

chmod +x /usr/local/bin/amneziawg-post-update.sh

echo ""
echo "Done! Pacman hook installed."
echo "After every kernel or amneziawg update, the module will be auto-rebuilt"
echo "and the VPN namespace service will be restarted."
echo ""
echo "Logs: /var/log/amneziawg-post-update.log"
