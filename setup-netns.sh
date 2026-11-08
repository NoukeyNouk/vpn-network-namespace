#!/bin/bash
# Reconcile namespace state without replacing the namespace used by applications.
set -euo pipefail
source "$(dirname -- "$(readlink -f -- "$0")")/vpn-common.sh"
require_root
install -d -m 0755 /run/mega-vpn
exec 8>/run/mega-vpn/setup.lock
flock -w 20 8
namespace_exists || ip netns add "$NETNS"
if ! ip -n "$NETNS" link show dev "$IFACE" >/dev/null 2>&1; then
  found=0
  for ((i=0; i<30; i++)); do
    if ip link show dev "$IFACE" >/dev/null 2>&1; then found=1; break; fi
    sleep 0.5
  done
  [[ $found == 1 ]] || { log "Interface $IFACE was not created by sing-box"; exit 1; }
  ip link set dev "$IFACE" netns "$NETNS"
fi
ip -n "$NETNS" link set dev lo up
ip -n "$NETNS" address replace "$VPN_ADDRESS" dev "$IFACE"
ip -n "$NETNS" link set dev "$IFACE" up
ip -n "$NETNS" route replace default dev "$IFACE"
install -d -m 0755 "/etc/netns/$NETNS"
# Write in place: existing ip-netns-exec bind mounts keep seeing updated DNS.
printf 'nameserver %s\nnameserver %s\n' "$DNS1" "$DNS2" > "/etc/netns/$NETNS/resolv.conf"
chmod 0644 "/etc/netns/$NETNS/resolv.conf"
log "Namespace $NETNS configured; connectivity is checked separately"
