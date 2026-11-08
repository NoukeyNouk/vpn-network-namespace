#!/bin/bash
# Shared configuration and read-only health checks.
VPN_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Installed configuration must be owned by root and not writable by other users.
if [[ -f /etc/mega-vpn/config ]]; then
  if [[ $(stat -c '%u' /etc/mega-vpn/config) != 0 ]] ||
     [[ -n $(find /etc/mega-vpn/config -maxdepth 0 -perm /022 -print) ]]; then
    echo 'Unsafe /etc/mega-vpn/config permissions' >&2
    return 1
  fi
  source /etc/mega-vpn/config
fi
NETNS=${NETNS:-hy2-vpn}
IFACE=${IFACE:-neko-tun}
VPN_ADDRESS=${VPN_ADDRESS:-${WG_IP:-172.19.0.2/28}}
DNS1=${DNS1:-1.1.1.1}
DNS2=${DNS2:-8.8.8.8}
CHECK_INTERVAL=${CHECK_INTERVAL:-20}
MAX_FAILURES=${MAX_FAILURES:-3}
RECOVERY_COOLDOWN=${RECOVERY_COOLDOWN:-120}
CHECK_URLS=(https://cp.cloudflare.com/generate_204 https://www.gstatic.com/generate_204)
[[ $NETNS =~ ^[a-zA-Z0-9_-]{1,63}$ && $IFACE =~ ^[a-zA-Z0-9_-]{1,15}$ ]] || {
  echo 'Invalid namespace or interface name' >&2; return 1;
}
for value in "$CHECK_INTERVAL" "$MAX_FAILURES" "$RECOVERY_COOLDOWN"; do
  [[ $value =~ ^[1-9][0-9]{0,5}$ ]] || { echo 'Invalid recovery setting' >&2; return 1; }
done
log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }
require_root() { [[ $EUID == 0 ]] || { echo 'Run as root' >&2; return 1; }; }
namespace_exists() { ip netns list | awk '{print $1}' | grep -Fxq -- "$NETNS"; }
vpn_exec() {
  if [[ $(ip netns identify "$$" 2>/dev/null) == "$NETNS" ]]; then
    "$@"
  elif [[ $EUID == 0 ]]; then
    ip netns exec "$NETNS" "$@"
  else
    sudo ip netns exec "$NETNS" "$@"
  fi
}
# Require both transport success and the expected HTTP response. Ignore proxy
# environment and ~/.curlrc so a host proxy cannot fake namespace connectivity.
probe() {
  local scope=$1 url result
  for url in "${CHECK_URLS[@]}"; do
    if [[ $scope == vpn ]]; then
      result=$(vpn_exec curl -q --noproxy '*' --silent --show-error --output /dev/null \
        --connect-timeout 3 --max-time 6 --write-out '%{http_code} %{time_total}' "$url" 2>/dev/null) || continue
    else
      result=$(curl -q --noproxy '*' --silent --show-error --output /dev/null \
        --connect-timeout 3 --max-time 6 --write-out '%{http_code} %{time_total}' "$url" 2>/dev/null) || continue
    fi
    if [[ $result =~ ^204\ ([0-9]+\.[0-9]+)$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done
  return 1
}
