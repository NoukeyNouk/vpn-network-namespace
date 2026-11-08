#!/bin/bash
set -euo pipefail
source "$(dirname -- "$(readlink -f -- "$0")")/vpn-common.sh"
require_root
# systemd uses the host network by default. Reject manual execution in a
# named namespace without inspecting PID 1 (which can be access-restricted).
require_host_namespace
install -d -m 0755 /run/mega-vpn
FAIL_COUNT=0
recover() (
  exec 9>/run/mega-vpn/recovery.lock
  flock -n 9 || exit 0
  systemctl is-active --quiet sing-box.service || exit 0
  # Monotonic clock avoids changes to wall time; state is cleared at reboot.
  read -r uptime _ < /proc/uptime
  now=${uptime%%.*}
  last=0
  [[ ! -f /run/mega-vpn/last-recovery ]] || read -r last < /run/mega-vpn/last-recovery
  [[ $last =~ ^[0-9]+$ ]] || last=0
  if (( last > 0 && now - last < RECOVERY_COOLDOWN )); then
    log 'Recovery deferred: cooldown active'; exit 0
  fi
  printf '%s\n' "$now" > /run/mega-vpn/last-recovery
  log 'Repairing namespace configuration'
  if bash "$VPN_DIR/setup-netns.sh" && probe vpn >/dev/null; then
    log 'Connectivity restored without restarting sing-box'; exit 0
  fi
  log 'Namespace repair insufficient; restarting sing-box and namespace service'
  if ! systemctl restart sing-box.service sing-vpn.service; then
    log 'Service restart failed; inspect journalctl -u sing-box -u sing-vpn'
    exit 1
  fi
  if probe vpn >/dev/null; then log 'Connectivity restored'; else
    log 'VPN still unavailable; further recovery is rate limited'; exit 1
  fi
)
check_once() {
  systemctl is-active --quiet sing-box.service || { FAIL_COUNT=0; return 0; }
  if probe vpn >/dev/null; then FAIL_COUNT=0; return 0; fi
  if ! probe host >/dev/null; then
    log 'Host connectivity unavailable; leaving VPN untouched'
    FAIL_COUNT=0; return 0
  fi
  FAIL_COUNT=$((FAIL_COUNT + 1))
  log "VPN health check failed ($FAIL_COUNT/$MAX_FAILURES)"
  if (( FAIL_COUNT >= MAX_FAILURES )); then
    recover || log 'Recovery failed'
    FAIL_COUNT=0
  fi
}
case ${1:-} in
  --repair) recover ;;
  --once) check_once ;;
  '') while true; do check_once; sleep "$CHECK_INTERVAL"; done ;;
  *) echo 'Usage: vpn-watchdog.sh [--once|--repair]' >&2; exit 2 ;;
esac
