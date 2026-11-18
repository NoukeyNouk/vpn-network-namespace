#!/bin/bash
# Safe to source for offline tests: privileged operations live in main().
set -euo pipefail
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vpn-common.sh"
WATCHDOG_MODE=${WATCHDOG_MODE:-observe}
RESTART_WINDOW=${RESTART_WINDOW:-3600}
MAX_RESTARTS=${MAX_RESTARTS:-2}
FAILED_RESTART_BACKOFF=${FAILED_RESTART_BACKOFF:-1800}
STATE_DIR=/run/mega-vpn
REPORT_DIR=/var/log/mega-vpn
FAIL_COUNT=0
REPORT=''
event() {
  local line="[$(date -Is)] $*"
  printf '%s\n' "$line" >&2
  if [[ -n $REPORT ]]; then printf '%s\n' "$line" >> "$REPORT"; fi
}
monotonic() { local up rest; read -r up rest < /proc/uptime; printf '%s\n' "${up%%.*}"; }
# Test every endpoint. This logs partial failures too, unlike the user-facing probe.
health() {
  local scope=$1 url result rc kind ok=1
  local -a command
  for url in "${CHECK_URLS[@]}"; do
    command=(curl -q --noproxy '*' --silent --output /dev/null
      --connect-timeout 3 --max-time 6
      --write-out '%{http_code} %{time_total} %{time_namelookup} %{time_connect} %{remote_ip}')
    rc=0
    if [[ $scope == vpn ]]; then
      result=$(vpn_exec "${command[@]}" "$url" 2>/dev/null) || rc=$?
    else
      result=$("${command[@]}" "$url" 2>/dev/null) || rc=$?
    fi
    case $rc in
      0) if [[ $result == '204 '* ]]; then kind=ok; else kind=unexpected_http; fi ;;
      6) kind=dns_resolution_failed ;;
      7) kind=connect_failed ;;
      28) kind=timeout ;;
      35|60) kind=tls_error ;;
      *) kind=execution_or_transport_error ;;
    esac
    event "event=probe kind=$kind scope=$scope url=$url curl_exit=$rc http_total_dns_connect_ip=[$result]"
    if [[ $rc == 0 && $result == '204 '* ]]; then ok=0; fi
  done
  return "$ok"
}
snapshot() {
  {
    echo '--- local state (read-only) ---'
    systemctl show sing-box.service sing-vpn.service -p Id -p ActiveState -p MainPID -p ActiveEnterTimestamp
    ip -n "$NETNS" -brief address
    ip -n "$NETNS" route show
    ip route show
    ip rule show
    echo '--- error counts in the last 3 minutes (not a root cause verdict) ---'
    journalctl -u sing-box.service --since '3 minutes ago' --no-pager -o cat |
      awk '/remote error: dial/{remote++} /i\/o timeout/{timeouts++} /connection refused/{refused++}
        END {printf "remote_dial_errors=%d timeouts=%d refused=%d\n", remote,timeouts,refused}'
  } >> "$REPORT" 2>&1 || event 'event=snapshot status=partial'
}
start_report() {
  REPORT=$(mktemp "$REPORT_DIR/incident-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX.log") || return 1
  # Bound disk use: retain the newest 20 reports, including this one.
  python3 - "$REPORT_DIR" <<'PY' || return 1
import pathlib,sys
files=sorted(pathlib.Path(sys.argv[1]).glob('incident-*.log'),key=lambda p:p.stat().st_mtime,reverse=True)
for p in files[20:]: p.unlink()
PY
  event "event=incident mode=$WATCHDOG_MODE report=$REPORT reason=consecutive_vpn_failures_host_reachable"
  snapshot
}
recover() (
  exec 9>"$STATE_DIR/recovery.lock"
  flock -n 9 || { event 'event=decision action=skip reason=recovery_already_running'; exit 0; }
  systemctl is-active --quiet sing-box.service || { event 'event=decision action=skip reason=service_stopped'; exit 0; }
  local now last=0 blocked=0
  now=$(monotonic)
  [[ ! -f $STATE_DIR/last-recovery ]] || read -r last < "$STATE_DIR/last-recovery"
  [[ $last =~ ^[0-9]+$ ]] || last=0
  if (( last > 0 && now - last < RECOVERY_COOLDOWN )); then
    event 'event=decision action=skip reason=incident_cooldown'; exit 0
  fi
  printf '%s\n' "$now" > "$STATE_DIR/last-recovery" || exit 1
  start_report || exit 1
  # Recheck under lock. A transient recovery must not cause any mutation.
  if health vpn; then event 'event=decision action=none reason=recovered_before_action'; exit 0; fi
  if ! health host; then event 'event=decision action=none reason=host_also_unreachable'; exit 0; fi
  if [[ $WATCHDOG_MODE == observe ]]; then
    event 'event=decision action=none reason=observe_only root_cause=undetermined'; exit 0
  fi
  [[ ! -f $STATE_DIR/blocked-until ]] || read -r blocked < "$STATE_DIR/blocked-until"
  [[ $blocked =~ ^[0-9]+$ ]] || blocked=0
  if (( now < blocked )); then
    event "event=decision action=none reason=failed_restart_backoff remaining_seconds=$((blocked-now))"; exit 0
  fi
  # Do not rewrite a healthy-looking namespace on every HTTP failure.
  if ! ip -n "$NETNS" link show dev "$IFACE" >/dev/null 2>&1; then
    event 'event=repair reason=interface_or_namespace_missing'
    bash "$VPN_DIR/setup-netns.sh" >> "$REPORT" 2>&1 || event 'event=repair result=failed'
    if health vpn; then event 'event=repair result=connectivity_restored'; exit 0; fi
  fi
  touch "$STATE_DIR/restarts" || exit 1
  awk -v cutoff="$((now-RESTART_WINDOW))" '$1 ~ /^[0-9]+$/ && $1>cutoff' "$STATE_DIR/restarts" > "$STATE_DIR/restarts.new" || exit 1
  mv "$STATE_DIR/restarts.new" "$STATE_DIR/restarts" || exit 1
  local count
  count=$(wc -l < "$STATE_DIR/restarts")
  if (( count >= MAX_RESTARTS )); then
    event "event=decision action=none reason=restart_budget_exhausted count=$count window_seconds=$RESTART_WINDOW"; exit 0
  fi
  systemctl is-active --quiet sing-box.service || { event 'event=decision action=none reason=service_stopped'; exit 0; }
  printf '%s\n' "$now" >> "$STATE_DIR/restarts" || exit 1
  # Persist pessimistically before restart: a killed watchdog cannot lose backoff.
  printf '%s\n' "$((now+FAILED_RESTART_BACKOFF))" > "$STATE_DIR/blocked-until" || exit 1
  event "event=restart reason=persistent_vpn_failure_host_reachable root_cause=undetermined attempt_in_window=$((count+1))"
  if ! systemctl restart sing-box.service sing-vpn.service >> "$REPORT" 2>&1; then
    event 'event=restart_result outcome=command_failed'; exit 1
  fi
  local passed=0 attempt
  for attempt in 1 2 3; do
    sleep 5
    if health vpn; then passed=$((passed+1)); fi
  done
  if (( passed == 3 )); then
    printf '0\n' > "$STATE_DIR/blocked-until" || exit 1
    event 'event=restart_result outcome=healthy_after_restart checks_passed=3/3 causality=not_proven'
  else
    event "event=restart_result outcome=no_sustained_recovery checks_passed=$passed/3 backoff_seconds=$FAILED_RESTART_BACKOFF"
  fi
)
check_once() {
  if ! systemctl is-active --quiet sing-box.service; then
    FAIL_COUNT=0; event 'event=decision action=none reason=service_stopped'; return 0
  fi
  if health vpn; then
    if (( FAIL_COUNT > 0 )); then event "event=recovered_without_action previous_failures=$FAIL_COUNT"; fi
    FAIL_COUNT=0; return 0
  fi
  if ! health host; then
    event 'event=decision action=none reason=host_also_unreachable'; FAIL_COUNT=0; return 0
  fi
  FAIL_COUNT=$((FAIL_COUNT+1))
  event "event=failure consecutive=$FAIL_COUNT threshold=$MAX_FAILURES"
  if (( FAIL_COUNT >= MAX_FAILURES )); then
    recover || event 'event=recovery result=failed'
    FAIL_COUNT=0
  fi
}
main() {
  require_root
  require_host_namespace
  [[ $WATCHDOG_MODE == observe || $WATCHDOG_MODE == auto ]] || { echo 'WATCHDOG_MODE must be observe or auto' >&2; return 2; }
  local value
  for value in "$RESTART_WINDOW" "$MAX_RESTARTS" "$FAILED_RESTART_BACKOFF"; do
    [[ $value =~ ^[1-9][0-9]{0,5}$ ]] || { echo 'Invalid restart budget setting' >&2; return 2; }
  done
  install -d -m 0700 "$STATE_DIR" "$REPORT_DIR"
  case ${1:-} in
    --repair) WATCHDOG_MODE=auto; recover ;;
    --once) check_once ;;
    '') event "event=start mode=$WATCHDOG_MODE max_restarts=$MAX_RESTARTS window_seconds=$RESTART_WINDOW"
        while true; do check_once; sleep "$CHECK_INTERVAL"; done ;;
    *) echo 'Usage: vpn-watchdog.sh [--once|--repair]' >&2; return 2 ;;
  esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
