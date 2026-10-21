#!/usr/bin/env bash
# UserPromptSubmit hook: block the prompt when the external IP country is not allowed.
# Off unless GEO_ALLOWED is set to a non-empty list of country codes (for example
# "DE LT PL NL"). While it is on, the hook sends the machine's IP to icanhazip.com
# or api.ipify.org, then the country lookup to ipinfo.io or ip-api.com.
# Any check failure also blocks (fail closed).
#
# Two steps: learn the external IP at most once per GEO_IP_TTL seconds (default 60,
# 0 = on every prompt). Call the geo service only when the IP differs from the cached
# one — an IP change (VPN drop) is visible within TTL. Only an allowed result is
# cached, so after VPN recovery the next prompt passes immediately. Cache age is the
# file mtime. IPs listed in GEO_IPS_FILE (default ~/.agent-sync/geo-allowed-ips) skip
# the geo lookup but the IP itself is still checked. Only a synchronous hook can block
# — in settings.json it must NOT be async.
set -u
# fail closed like every other check failure; the test runs it with a bare PATH
_compat="${SYNC_HOME:-$HOME/.agent-sync}/bin/lib/compat.sh"
if [ -f "$_compat" ]; then
  . "$_compat" || { echo "Could not check the country: GNU tools are missing" >&2; exit 2; }
fi

STATE_DIR="${GEO_STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/claude-geo-guard}"
CACHE="$STATE_DIR/country"
TTL="${GEO_IP_TTL:-60}"
[[ "$TTL" =~ ^[0-9]+$ ]] || TTL=60
IPS_FILE="${GEO_IPS_FILE:-$HOME/.agent-sync/geo-allowed-ips}"

# Read stdin up front (SIGPIPE; see limit-guard.sh)
cat >/dev/null 2>&1

# Empty or unset: do nothing and do not call out.
if [ -z "${GEO_ALLOWED:-}" ]; then
  exit 0
fi
ALLOWED="$GEO_ALLOWED"

block() { echo "[geo-guard] $1 Prompt blocked." >&2; exit 2; }

fetch() { curl -fsS -m 3 "$1" 2>/dev/null; }

trim() { local x; read -r x <<<"$1"; printf '%s' "$x"; }

is_ip() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$1" == *:* && "$1" =~ ^[0-9a-fA-F:]+$ ]]
}
is_cc() { [[ "$1" =~ ^[A-Z]{2}$ ]]; }

is_allowed() {
  local c
  for c in $ALLOWED; do [ "$c" = "$1" ] && return 0; done
  return 1
}

# IPS_FILE: one IP per line; blank lines and "# …" comments are ignored
ip_listed() {
  local l
  [ -n "$1" ] && [ -f "$IPS_FILE" ] || return 1
  while read -r l || [ -n "$l" ]; do
    l="${l%%#*}"; l="${l//[[:space:]]/}"
    [ "$l" = "$1" ] && return 0
  done < "$IPS_FILE"
  return 1
}

command -v curl >/dev/null 2>&1 || block "Could not check IP country (curl not found)."

cache_trusted() { is_allowed "${cached_cc:-}" || ip_listed "${cached_ip:-}"; }

if [ "$TTL" -gt 0 ] && [ -f "$CACHE" ]; then
  read -r cached_ip cached_cc < "$CACHE"
  mtime="$(stat -c %Y "$CACHE" 2>/dev/null)" || mtime=0
  if [ $(( $(date +%s) - mtime )) -lt "$TTL" ] && cache_trusted; then exit 0; fi
fi

ip=''
for url in https://icanhazip.com https://api.ipify.org; do
  out="$(trim "$(fetch "$url")")"
  if is_ip "$out"; then ip="$out"; break; fi
done
[ -n "$ip" ] || block "Could not check IP country (icanhazip.com, api.ipify.org)."

save_cache() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s %s\n' "$ip" "$1" > "$CACHE.$$" 2>/dev/null && mv -f "$CACHE.$$" "$CACHE" 2>/dev/null
}

if ip_listed "$ip"; then save_cache -; exit 0; fi

if [ -f "$CACHE" ]; then
  read -r cached_ip cached_cc < "$CACHE"
  if [ "${cached_ip:-}" = "$ip" ] && cache_trusted; then touch "$CACHE" 2>/dev/null; exit 0; fi
fi

cc=''
for url in "https://ipinfo.io/$ip/country" "http://ip-api.com/line/$ip?fields=countryCode"; do
  out="$(trim "$(fetch "$url")")"
  if is_cc "$out"; then cc="$out"; break; fi
done
[ -n "$cc" ] || block "Could not check IP country (ipinfo.io, ip-api.com)."

is_allowed "$cc" || block "IP country $cc is not allowed ($ALLOWED)."

save_cache "$cc"
exit 0
