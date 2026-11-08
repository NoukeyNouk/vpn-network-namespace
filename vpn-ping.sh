#!/bin/bash
set -euo pipefail
source "$(dirname -- "$(readlink -f -- "$0")")/vpn-common.sh"
status() {
  local elapsed
  if elapsed=$(probe vpn); then
    awk -v t="$elapsed" 'BEGIN {printf "VPN HTTP check: OK (%.1f ms, including DNS and TLS)\n", t*1000}'
  else
    echo 'VPN HTTP check: FAILED (transport error or unexpected response)'
    return 1
  fi
}
case ${1:-} in
  -h|--help)
    echo 'Usage: vpn-ping [--watch | -c COUNT | --ip | --fix]'
    echo 'HTTP checks are not ICMP RTT or packet-loss measurements.' ;;
  --ip) vpn_exec curl -q --noproxy '*' --fail --silent --show-error --max-time 6 https://api.ipify.org; echo ;;
  -r|--fix)
    if [[ $EUID == 0 ]]; then bash "$VPN_DIR/vpn-watchdog.sh" --repair
    else sudo bash "$VPN_DIR/vpn-watchdog.sh" --repair; fi ;;
  -w|--watch)
    trap 'exit 0' INT TERM
    while true; do status || true; sleep "$CHECK_INTERVAL"; done ;;
  -c)
    count=${2:-4}
    [[ $count =~ ^[1-9][0-9]{0,3}$ ]] || { echo 'COUNT must be 1..9999' >&2; exit 2; }
    received=0
    for ((i=1; i<=count; i++)); do
      printf '%s/%s: ' "$i" "$count"
      if status; then received=$((received+1)); fi
      if (( i < count )); then sleep 1; fi
    done
    printf '%s/%s HTTP checks succeeded\n' "$received" "$count"
    (( received == count )) ;;
  '') status ;;
  *) echo 'Unknown option; use --help' >&2; exit 2 ;;
esac
