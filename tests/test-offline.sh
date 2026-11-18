#!/bin/bash
# All connectivity calls below are shell mocks. Never touches network or services.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source ./vpn-common.sh
vpn_exec() { "$@"; }
curl() { printf '204 4.000000'; return 28; }
if probe vpn; then echo 'FAIL: accepted timed-out request'; exit 1; fi
curl() { printf '302 0.100000'; }
if probe vpn; then echo 'FAIL: accepted captive portal redirect'; exit 1; fi
curl() { printf '500 0.100000'; }
if probe host; then echo 'FAIL: accepted server error'; exit 1; fi
curl() { printf '204 0.123456'; }
[[ $(probe vpn) == 0.123456 ]]
[[ $(probe host) == 0.123456 ]]
curl() {
  if [[ ${*: -1} == "${CHECK_URLS[0]}" ]]; then return 7; fi
  printf '204 0.200000'
}
[[ $(probe vpn) == 0.200000 ]]
# Never run project scripts: syntax parsing only.
for script in ./*.sh hooks/*.sh tests/*.sh; do bash -n "$script"; done
# Load only watchdog functions, skipping privileged initialization and entrypoint.
source ./vpn-watchdog.sh
systemctl() { [[ $service_state == active ]]; }
health() {
  if [[ $1 == vpn ]]; then [[ $vpn_state == online ]];
  else [[ $host_state == online ]]; fi
}
recover() { recovery_calls=$((recovery_calls+1)); }
log() { :; }
service_state=inactive
vpn_state=offline
host_state=online
recovery_calls=0
check_once
[[ $FAIL_COUNT == 0 && $recovery_calls == 0 ]]
service_state=active
host_state=offline
check_once
[[ $FAIL_COUNT == 0 && $recovery_calls == 0 ]]
host_state=online
MAX_FAILURES=3
check_once
check_once
[[ $FAIL_COUNT == 2 && $recovery_calls == 0 ]]
check_once
[[ $FAIL_COUNT == 0 && $recovery_calls == 1 ]]
check_once
vpn_state=online
check_once
[[ $FAIL_COUNT == 0 && $recovery_calls == 1 ]]
echo 'PASS: HTTP errors, fallback, stopped service, offline host, failure threshold, reset and syntax' 

# Host guard must handle unnamed host, named VPN, and identification errors.
ip() { return 0; }
require_host_namespace
ip() { echo hy2-vpn; }
if require_host_namespace 2>/dev/null; then exit 1; fi
ip() { return 1; }
if require_host_namespace 2>/dev/null; then exit 1; fi
echo 'PASS: host namespace guard'
