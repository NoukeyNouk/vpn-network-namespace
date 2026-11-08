#!/bin/bash
set -euo pipefail
source "$(dirname -- "$(readlink -f -- "$0")")/vpn-common.sh"
require_root
# Normal service stops must retain namespace identity and DNS bind mounts.
if [[ ${1:-} != --delete ]]; then
  log "Preserving $NETNS for running applications; sing-box owns the TUN lifetime"
  exit 0
fi
install -d -m 0755 /run/mega-vpn
exec 8>/run/mega-vpn/setup.lock
flock -w 20 8
if namespace_exists; then
  pids=$(ip netns pids "$NETNS")
  [[ -z $pids ]] || { echo "Refusing to delete $NETNS: applications are still running" >&2; exit 1; }
  ip netns delete "$NETNS"
fi
# Keep resolver files: a detached mount namespace may still reference them.
log "Namespace removed; resolver configuration retained"
