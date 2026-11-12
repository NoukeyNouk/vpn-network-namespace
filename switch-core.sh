#!/bin/bash
# Explicitly switch the local VPN; run from a host terminal with sudo.
set -euo pipefail
DIR="$(dirname -- "$(readlink -f -- "$0")")"
[[ $EUID == 0 ]] || { echo 'Run: sudo bash ./switch-core.sh' >&2; exit 1; }
current_ns=$(ip netns identify "$$")
[[ -z $current_ns ]] || { echo 'Run from the host terminal, outside run-vpn.' >&2; exit 1; }
candidate="$DIR/.local-stage/core-hy2-sing-box.json"
target=/etc/sing-box/config.json
[[ -f $candidate && -f $target ]] || { echo 'Missing configuration' >&2; exit 1; }
# Do not overwrite unrelated changes made since the candidate was prepared.
python3 - "$target" "$candidate" <<'PY'
import json,sys
old,new=[json.load(open(p)) for p in sys.argv[1:]]
for c in (old,new):
    c['outbounds']=[o for o in c.get('outbounds',[]) if o.get('tag')!='proxy']
if old!=new:
    sys.exit('Configuration changed since preparation; rebuild the candidate first.')
PY
source "$DIR/vpn-common.sh"
export ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true
export ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM=true
export ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true
sing-box check -c "$candidate"
install -d -m 0700 /root/mega-vpn-backup
backup=$(mktemp /root/mega-vpn-backup/before-core-hy2.XXXXXXXX.json)
cp -a -- "$target" "$backup"
watchdog_was_active=0
if systemctl is-active --quiet vpn-watchdog.service; then watchdog_was_active=1; fi
changed=0
rollback() {
  result=$?
  trap - EXIT
  if (( result != 0 && changed == 1 )); then
    echo "Switch failed; restoring $backup" >&2
    cp -a -- "$backup" "$target"
    systemctl restart sing-box.service sing-vpn.service || true
    if (( watchdog_was_active == 1 )); then systemctl start vpn-watchdog.service || true; fi
  fi
  exit "$result"
}
trap rollback EXIT
systemctl stop vpn-watchdog.service
changed=1
# Writing to the existing file retains its owner and permissions.
cat "$candidate" > "$target"
systemctl restart sing-box.service sing-vpn.service
healthy=0
for attempt in 1 2 3; do
  if probe vpn >/dev/null; then healthy=1; break; fi
  sleep 2
done
[[ $healthy == 1 ]] || { echo 'Core VPN health check failed' >&2; exit 1; }
systemctl start vpn-watchdog.service
changed=0
printf 'Switched to core successfully. Backup: %s\n' "$backup"
