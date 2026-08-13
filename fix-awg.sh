#!/bin/bash
# fix-awg.sh — Fix AmneziaWG after system updates
# This script ensures the kernel module, tools, and config are all compatible.
#
# The problem: after pacman -Syu, the DKMS module can be rebuilt for AWG 3.0
# while the config file may be for AWG 1.0 (missing S3, S4 params), or vice versa.
#
# Solution: Use ONLY the AWG 3.0 stack consistently, and update the config.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== AmneziaWG Diagnostic & Fix Script ===${NC}"
echo ""

# 1. Check what's installed
echo -e "${YELLOW}[1/5] Checking installed packages...${NC}"
echo "Kernel: $(uname -r)"
echo "DKMS status:"
dkms status 2>/dev/null | grep -i amnezi || echo "  (no amneziawg DKMS modules)"
echo ""
echo "Installed amneziawg packages:"
pacman -Qs amnezia 2>/dev/null | grep "^local/" || echo "  (none)"
echo ""

# 2. Check module version
echo -e "${YELLOW}[2/5] Checking loaded kernel module...${NC}"
if lsmod | grep -q amneziawg; then
    MOD_VER=$(modinfo amneziawg 2>/dev/null | grep '^version:' | awk '{print $2}')
    echo "Loaded module version: $MOD_VER"
else
    echo -e "${RED}amneziawg module is NOT loaded!${NC}"
    echo "Trying to load it..."
    sudo modprobe amneziawg || echo -e "${RED}Failed to load module!${NC}"
fi
echo ""

# 3. Check tools version
echo -e "${YELLOW}[3/5] Checking awg tools...${NC}"
AWG_VER=$(awg --version 2>&1)
echo "awg version: $AWG_VER"
echo ""

# 4. Detect conflicts
echo -e "${YELLOW}[4/5] Detecting conflicts...${NC}"
DKMS_COUNT=$(pacman -Qs amneziawg-dkms 2>/dev/null | grep "^local/" | wc -l)
if [ "$DKMS_COUNT" -gt 1 ]; then
    echo -e "${RED}WARNING: Multiple amneziawg DKMS packages detected!${NC}"
    echo "This causes version conflicts. You should keep only ONE."
    echo ""
    echo "Installed DKMS packages:"
    pacman -Qs amneziawg-dkms 2>/dev/null | grep "^local/"
    echo ""
    echo -e "${YELLOW}Recommendation:${NC}"
    echo "  Keep amneziawg-dkms (3.0) and remove amneziawg-dkms-git (1.0):"
    echo "  sudo pacman -R amneziawg-dkms-git"
    echo ""
fi

TOOLS_COUNT=$(pacman -Qs amneziawg-tools 2>/dev/null | grep "^local/" | grep -v debug | wc -l)
if [ "$TOOLS_COUNT" -gt 1 ]; then
    echo -e "${RED}WARNING: Multiple amneziawg-tools packages detected!${NC}"
    echo "Installed tools packages:"
    pacman -Qs amneziawg-tools 2>/dev/null | grep "^local/" | grep -v debug
    echo ""
fi

# 5. Config check
echo -e "${YELLOW}[5/5] Checking config compatibility...${NC}"
CONF="$(dirname "$(readlink -f "$0")")/awg0.conf"
if [ -f "$CONF" ]; then
    HAS_S3=$(grep -ci '^S3' "$CONF" 2>/dev/null || echo 0)
    HAS_S4=$(grep -ci '^S4' "$CONF" 2>/dev/null || echo 0)
    if [ "$HAS_S3" -eq 0 ] || [ "$HAS_S4" -eq 0 ]; then
        echo -e "${RED}Config $CONF is missing S3/S4 — this is an AWG 1.0 config!${NC}"
        echo "The AWG 3.0 kernel module requires S3 and S4 parameters."
        echo ""
        HIDDEN_CONF="$(dirname "$(readlink -f "$0")")/.awg0.conf"
        if [ -f "$HIDDEN_CONF" ]; then
            H_S3=$(grep -ci '^S3' "$HIDDEN_CONF" 2>/dev/null || echo 0)
            if [ "$H_S3" -gt 0 ]; then
                echo -e "${GREEN}Found .awg0.conf with AWG 3.0 format!${NC}"
                echo "You can use it: cp .awg0.conf awg0.conf"
            fi
        fi
    else
        echo -e "${GREEN}Config has S3 and S4 — compatible with AWG 3.0${NC}"
    fi
else
    echo -e "${RED}Config file not found: $CONF${NC}"
fi

echo ""
echo -e "${YELLOW}=== Summary ===${NC}"
echo "To fix the issue, run these commands:"
echo ""
echo "  # 1. Remove conflicting old DKMS package"
echo "  sudo pacman -R amneziawg-dkms-git"
echo ""
echo "  # 2. Use the correct AWG 3.0 config (if .awg0.conf is your new config)"
echo "  cp .awg0.conf awg0.conf"
echo ""
echo "  # 3. Reload the module"
echo "  sudo modprobe -r amneziawg && sudo modprobe amneziawg"
echo ""
echo "  # 4. Restart the VPN"
echo "  sudo ./teardown-netns.sh 2>/dev/null; sudo ./setup-netns.sh"
echo ""
