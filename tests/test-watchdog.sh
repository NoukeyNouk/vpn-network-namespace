#!/bin/bash
# Real decision/state/report code, mocked network and systemd; no root required.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source ./vpn-watchdog.sh
sandbox=$(mktemp -d)
trap 'rm -rf -- "$sandbox"' EXIT
STATE_DIR="$sandbox/state"
REPORT_DIR="$sandbox/reports"
mkdir "$STATE_DIR" "$REPORT_DIR"
REPORT=''
# Check health() transport/status handling before replacing it for scenarios.
vpn_exec() { "$@"; }
curl() { echo '204 6.000000 0.001 0.002 127.0.0.1'; return 28; }
if health vpn 2>/dev/null; then echo 'Timeout falsely passed'; exit 1; fi
curl() { echo '302 0.1 0.01 0.02 127.0.0.1'; }
if health vpn 2>/dev/null; then echo 'Redirect falsely passed'; exit 1; fi
curl() { echo '204 0.1 0.01 0.02 127.0.0.1'; }
health vpn 2>/dev/null
test_clock=10000
monotonic() { echo "$test_clock"; }
snapshot() { echo 'mock snapshot' >> "$REPORT"; }
sleep() { :; }
ip() { return 0; }
systemctl() {
  case $1 in
    is-active) [[ $service == active ]] ;;
    restart) echo restart >> "$sandbox/actions"; touch "$sandbox/restarted"; return "$restart_exit" ;;
    *) echo 'Unexpected systemctl command' >&2; return 99 ;;
  esac
}
health() {
  if [[ $1 == host ]]; then [[ $host == online ]]; return; fi
  if [[ -f $sandbox/restarted ]]; then [[ $after == online ]]; else [[ $before == online ]]; fi
}
service=active host=online before=offline after=offline restart_exit=0
WATCHDOG_MODE=observe
recover 2>> "$sandbox/events"
[[ ! -f $sandbox/actions ]]
grep -q 'reason=observe_only' "$sandbox/events"
WATCHDOG_MODE=auto
test_clock=$((test_clock+200))
before=online
recover 2>> "$sandbox/events"
[[ ! -f $sandbox/actions ]]
grep -q 'reason=recovered_before_action' "$sandbox/events"
test_clock=$((test_clock+200)); before=offline; host=offline
recover 2>> "$sandbox/events"
[[ ! -f $sandbox/actions ]]
grep -q 'reason=host_also_unreachable' "$sandbox/events"
test_clock=$((test_clock+200)); host=online
recover 2>> "$sandbox/events"
[[ $(wc -l < "$sandbox/actions") == 1 ]]
grep -q 'outcome=no_sustained_recovery' "$sandbox/events"
test_clock=$((test_clock+200))
recover 2>> "$sandbox/events"
[[ $(wc -l < "$sandbox/actions") == 1 ]]
grep -q 'reason=failed_restart_backoff' "$sandbox/events"
# A later successful restart consumes the second budget slot.
test_clock=$((test_clock+1800)); after=online
# Only become healthy once systemctl restart is invoked again.
rm "$sandbox/restarted"
recover 2>> "$sandbox/events"
[[ $(wc -l < "$sandbox/actions") == 2 ]]
grep -q 'outcome=healthy_after_restart' "$sandbox/events"
# Immediate relapse still cannot produce a third restart in the hour.
test_clock=$((test_clock+200)); after=offline
recover 2>> "$sandbox/events"
[[ $(wc -l < "$sandbox/actions") == 2 ]]
grep -q 'reason=restart_budget_exhausted' "$sandbox/events"
# Expired window allows a new attempt; command failure is recorded and backed off.
test_clock=$((test_clock+4000)); restart_exit=1
if recover 2>> "$sandbox/events"; then echo 'Restart failure not propagated'; exit 1; fi
[[ $(wc -l < "$sandbox/actions") == 3 ]]
grep -q 'outcome=command_failed' "$sandbox/events"
test_clock=$((test_clock+200)); restart_exit=0
recover 2>> "$sandbox/events"
[[ $(wc -l < "$sandbox/actions") == 3 ]]
# Persistent state is loaded by each new recovery subshell.
[[ $(cat "$STATE_DIR/blocked-until") -gt $test_clock ]]
# Incident report retention is bounded.
for ((i=0;i<25;i++)); do start_report 2>/dev/null; done
[[ $(find "$REPORT_DIR" -name 'incident-*.log' | wc -l) == 20 ]]
echo 'PASS: health status, observe, recheck, host failure, backoff, restart budget, command failure, retention'
