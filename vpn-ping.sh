#!/bin/bash
# vpn-ping — Diagnostic and ping tool for hy2-vpn (sing-box)

set -e

NETNS="${NETNS:-hy2-vpn}"
IFACE="${IFACE:-neko-tun}"
PING_TARGET="http://cp.cloudflare.com/generate_204"

# Color helpers
if [ -t 1 ]; then
  BOLD="\033[1m"
  GREEN="\033[0;32m"
  RED="\033[0;31m"
  YELLOW="\033[0;33m"
  CYAN="\033[0;36m"
  GRAY="\033[0;90m"
  RESET="\033[0m"
else
  BOLD=""
  GREEN=""
  RED=""
  YELLOW=""
  CYAN=""
  GRAY=""
  RESET=""
fi

# Detect whether this process is already inside the VPN netns
CURRENT_NS=$(ip netns identify $$ 2>/dev/null || true)
IN_NETNS=0
if [ "$CURRENT_NS" = "$NETNS" ]; then
  IN_NETNS=1
fi

# Execute command inside VPN namespace
vpn_exec() {
  if [ "$IN_NETNS" -eq 1 ]; then
    "$@"
  else
    if [ "$EUID" -eq 0 ]; then
      ip netns exec "$NETNS" "$@"
    else
      sudo ip netns exec "$NETNS" "$@"
    fi
  fi
}

# Execute command in host namespace
host_exec() {
  if [ "$IN_NETNS" -eq 1 ]; then
    if [ "$EUID" -eq 0 ] || sudo -n true 2>/dev/null; then
      sudo nsenter -t 1 -n "$@" 2>/dev/null || true
    else
      return 1
    fi
  else
    "$@"
  fi
}

# Measure single RTT probe in milliseconds
measure_rtt() {
  local time_sec
  time_sec=$(vpn_exec curl -o /dev/null -s -w "%{time_total}" --connect-timeout 2 -m 4 "$PING_TARGET" 2>/dev/null || true)
  if [ -z "$time_sec" ] || [ "$time_sec" = "0.000000" ]; then
    echo "fail"
  else
    awk -v t="$time_sec" 'BEGIN { printf "%.1f\n", t * 1000 }'
  fi
}

# Get external IP info inside VPN
get_vpn_ip_info() {
  local json
  json=$(vpn_exec curl -s -m 4 https://ipwho.is/ 2>/dev/null || true)
  if [ -n "$json" ]; then
    local parsed
    parsed=$(echo "$json" | python3 -c "import sys, json; d=json.load(sys.stdin); print(f\"{d.get('ip')} ({d.get('country')}, {d.get('city')} - {d.get('connection', {}).get('isp')})\") if d.get('success') else sys.exit(1)" 2>/dev/null || true)
    if [ -n "$parsed" ]; then
      echo "$parsed"
      return 0
    fi
  fi

  local simple_ip
  simple_ip=$(vpn_exec curl -s -m 3 https://api.ipify.org 2>/dev/null || true)
  if [ -n "$simple_ip" ]; then
    echo "$simple_ip"
  else
    echo "Unknown (offline)"
  fi
}

# Get host external IP (outside VPN)
get_host_ip() {
  local hip
  hip=$(host_exec curl -s -m 3 https://api.ipify.org 2>/dev/null || true)
  echo "${hip:-Unavailable}"
}

# Fix / restart VPN
fix_vpn() {
  echo -e "${BOLD}${CYAN}Restarting VPN services (sing-box + sing-vpn)...${RESET}"
  if [ "$EUID" -eq 0 ]; then
    systemctl restart sing-box sing-vpn.service 2>/dev/null || systemctl restart sing-box amnezia-vpn 2>/dev/null || systemctl restart sing-box
  else
    sudo systemctl restart sing-box sing-vpn.service 2>/dev/null || sudo systemctl restart sing-box amnezia-vpn 2>/dev/null || sudo systemctl restart sing-box
  fi
  sleep 1.5
  echo -e "${GREEN}✓ Restart command sent. Checking new status...${RESET}\n"
  show_status
}

# Continuous ping mode (-c N)
run_ping_count() {
  local count="$1"
  echo -e "${BOLD}PING via $NETNS interface $IFACE (target: Cloudflare 204)...${RESET}"
  local transmitted=0
  local received=0
  local total_rtt=0
  local min_rtt=999999
  local max_rtt=0

  for ((i = 1; i <= count; i++)); do
    transmitted=$((transmitted + 1))
    local rtt
    rtt=$(measure_rtt)
    if [ "$rtt" != "fail" ]; then
      received=$((received + 1))
      total_rtt=$(awk -v t="$total_rtt" -v r="$rtt" 'BEGIN { print t + r }')
      min_rtt=$(awk -v m="$min_rtt" -v r="$rtt" 'BEGIN { print (r < m) ? r : m }')
      max_rtt=$(awk -v m="$max_rtt" -v r="$rtt" 'BEGIN { print (r > m) ? r : m }')
      echo -e "seq=$i: ${GREEN}OK${RESET}  rtt=${BOLD}${rtt} ms${RESET}"
    else
      echo -e "seq=$i: ${RED}Request timed out / connection error${RESET}"
    fi
    [ "$i" -lt "$count" ] && sleep 1
  done

  echo ""
  echo -e "${BOLD}--- $NETNS ping statistics ---${RESET}"
  local loss
  loss=$(awk -v tx="$transmitted" -v rx="$received" 'BEGIN { printf "%.0f", (1 - rx/tx)*100 }')
  local avg_rtt="0"
  if [ "$received" -gt 0 ]; then
    avg_rtt=$(awk -v t="$total_rtt" -v rx="$received" 'BEGIN { printf "%.1f", t/rx }')
  fi
  echo -e "$transmitted packets transmitted, $received received, ${BOLD}${loss}% packet loss${RESET}"
  if [ "$received" -gt 0 ]; then
    echo -e "rtt min/avg/max = ${min_rtt}/${avg_rtt}/${max_rtt} ms"
  fi

  [ "$received" -gt 0 ] && exit 0 || exit 1
}

# Watch mode (-w)
run_watch() {
  trap 'echo -e "\n${YELLOW}Monitoring stopped.${RESET}"; exit 0' INT TERM
  while true; do
    clear 2>/dev/null || true
    echo -e "${BOLD}Live VPN Monitor (${CYAN}$NETNS${RESET}) — Press Ctrl+C to quit${RESET}"
    echo -e "${GRAY}$(date '+%Y-%m-%d %H:%M:%S')${RESET}"
    echo "--------------------------------------------------------"
    show_status
    sleep 2
  done
}

# Full status report
show_status() {
  echo -e "${BOLD}=== VPN Status & Health Diagnostic ===${RESET}"

  # 1. Sing-box service status
  local sb_status
  sb_status=$(systemctl is-active sing-box 2>/dev/null || echo "inactive")
  if [ "$sb_status" = "active" ]; then
    echo -e "  [${GREEN}✓${RESET}] Sing-box service:    ${GREEN}active (running)${RESET}"
  else
    echo -e "  [${RED}✗${RESET}] Sing-box service:    ${RED}$sb_status${RESET}"
  fi

  # 2. Namespace status
  if ip netns list 2>/dev/null | grep -q "^$NETNS\b"; then
    echo -e "  [${GREEN}✓${RESET}] Namespace ($NETNS): ${GREEN}present${RESET}"
  elif [ "$IN_NETNS" -eq 1 ]; then
    echo -e "  [${GREEN}✓${RESET}] Namespace ($NETNS): ${GREEN}inside netns${RESET}"
  else
    echo -e "  [${RED}✗${RESET}] Namespace ($NETNS): ${RED}NOT FOUND${RESET}"
  fi

  # 3. Interface status inside netns
  if vpn_exec ip link show "$IFACE" >/dev/null 2>&1; then
    local iface_ip
    iface_ip=$(vpn_exec ip -4 addr show "$IFACE" 2>/dev/null | grep -o 'inet [0-9./]*' | cut -d' ' -f2 || echo "no ip")
    echo -e "  [${GREEN}✓${RESET}] Interface ($IFACE):  ${GREEN}UP ($iface_ip)${RESET}"
  else
    echo -e "  [${RED}✗${RESET}] Interface ($IFACE):  ${RED}NOT FOUND inside $NETNS${RESET}"
  fi

  # 4. Latency / Ping through VPN
  local rtt
  rtt=$(measure_rtt)
  if [ "$rtt" != "fail" ]; then
    echo -e "  [${GREEN}✓${RESET}] Tunnel Latency (RTT): ${BOLD}${GREEN}${rtt} ms${RESET}"
  else
    echo -e "  [${RED}✗${RESET}] Tunnel Latency (RTT): ${RED}FAILED (Connection timeout/error)${RESET}"
  fi

  # 5. External IP info
  if [ "$rtt" != "fail" ]; then
    local vpn_ip_info
    vpn_ip_info=$(get_vpn_ip_info)
    echo -e "  [${GREEN}✓${RESET}] External VPN IP:     ${CYAN}${vpn_ip_info}${RESET}"
  fi

  # 6. Host IP comparison (if available)
  if [ "$IN_NETNS" -eq 0 ]; then
    local host_ip
    host_ip=$(get_host_ip)
    if [ "$host_ip" != "Unavailable" ]; then
      echo -e "  [${GRAY}i${RESET}] Host External IP:    ${GRAY}${host_ip}${RESET}"
    fi
  fi

  echo "--------------------------------------------------------"
  if [ "$rtt" != "fail" ]; then
    echo -e "Status: ${BOLD}${GREEN}VPN is ONLINE and HEALTHY ✓${RESET}"
    return 0
  else
    echo -e "Status: ${BOLD}${RED}VPN is OFFLINE or UNHEALTHY ✗${RESET}"
    echo -e "Hint:   Run '${BOLD}vpn-ping --fix${RESET}' to automatically restart the stack."
    return 1
  fi
}

# Argument parsing
case "${1:-}" in
  -h|--help)
    echo "Usage: vpn-ping [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  (no options)     Perform a full health diagnostic and print status"
    echo "  -c <count>       Ping mode: send <count> probes and show RTT statistics"
    echo "  -w, --watch      Live monitor mode: refresh status every 2 seconds"
    echo "  -r, --fix        Restart sing-box and re-apply network namespace"
    echo "  --ip             Print only the external VPN IP address"
    echo "  -h, --help       Show this help message"
    exit 0
    ;;
  -c)
    COUNT="${2:-4}"
    run_ping_count "$COUNT"
    ;;
  -w|--watch)
    run_watch
    ;;
  -r|--fix)
    fix_vpn
    ;;
  --ip)
    vpn_exec curl -s -m 3 https://api.ipify.org || echo "offline"
    ;;
  *)
    show_status
    ;;
esac
