#!/usr/bin/env bash
# herdr-host-ping.sh <host> [Label]  — can a request be sent to an agent on another host.
# One-line output: STATUS<TAB>details. Exit code 0 only for ok.
#   ok         herdr answers; with Label — the space is found too (label, agent_status)
#   no-space   herdr answers, but there is no space with this label
#   busy       the space exists, agent_status=working
#   ssh-auth   Tailscale SSH asks for re-authorization (the output has a login.tailscale.com link) — only the user can do it
#   ssh-down   the host does not answer over ssh (off / not in the tailnet / no key) — and the tailcat fallback failed too
#   herdr-down ssh works, the herdr server does not answer
#   local      $host is this machine (hostname matched); ssh was not tried
# On ssh-auth/ssh-down we try the fallback via tailcat (see ~/.config/herdr-hosts.conf,
# ~/.agent-sync/systemd/tailcat-serve.service, agent-sync README "Cross-host SSH via
# tailcat") — if the host has an address there. ok/busy/no-space through the fallback are marked "(tailcat)".
set -u
for _compat in "$(dirname "$(readlink -f "$0")")/../../../bin/lib/compat.sh" "${SYNC_HOME:-$HOME/.agent-sync}/bin/lib/compat.sh"; do [ -f "$_compat" ] && { . "$_compat" || exit 1; break; }; done
CACHE=${HERDR_HOSTS_CACHE:-$HOME/.cache/herdr-hosts}
if [ "${1:-}" = "--all" ]; then            # for the timer: status of every other host -> $CACHE/<host>.status
  mkdir -p "$CACHE"; me=$(hostname)
  for d in ~/.agent-sync/sessions/*/; do h=$(basename "$d"); [ "$h" = "$me" ] && continue
    printf '%s\t%s\n' "$(date -u +%FT%TZ)" "$("$0" "$h" 2>&1)" > "$CACHE/$h.status.tmp" && mv "$CACHE/$h.status.tmp" "$CACHE/$h.status"
  done; exit 0
fi
host=${1:?host}; label=${2:-}
if [ "$host" = "$(hostname)" ]; then printf 'local\t%s is this machine, use local herdr\n' "$host"; exit 0; fi
user=$(jq -r '.home' ~/.agent-sync/sessions/"$host"/*.json 2>/dev/null | sort -u | head -1 | xargs -r basename)
user=${user:-$USER}
P='[ -d /run/user/$(id -u) ] && export XDG_RUNTIME_DIR=/run/user/$(id -u); PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH; herdr'

# classify OUT RC WHO — prints STATUS\tdetails and returns a code (0/5/6 — final success/busy;
# 2/3/4 — failure, for 2 and 3 the caller may try the tailcat fallback)
classify() {
  local out=$1 rc=$2 who=$3
  if grep -q 'login.tailscale.com' <<<"$out"; then printf 'ssh-auth\t%s: %s\n' "$who" "$(grep -o 'https://[^ ]*' <<<"$out" | head -1)"; return 2; fi
  if [ "$rc" -eq 255 ] || [ "$rc" -eq 124 ] || [ -z "$out" ]; then printf 'ssh-down\t%s rc=%s\n' "$who" "$rc"; return 3; fi
  if ! jq -e '.result.workspaces' <<<"$out" >/dev/null 2>&1; then printf 'herdr-down\t%s: %s\n' "$who" "$(head -c 160 <<<"$out" | tr '\n' ' ')"; return 4; fi
  local spaces st
  spaces=$(jq -r '.result.workspaces[] | "\(.label)=\(.agent_status)"' <<<"$out" | tr '\n' ' ')
  if [ -z "$label" ]; then printf 'ok\t%s spaces: %s\n' "$who" "$spaces"; return 0; fi
  st=$(jq -r --arg l "$label" '.result.workspaces[] | select(.label==$l or (.label|startswith($l+"-"))) | "\(.label)=\(.agent_status)"' <<<"$out")
  [ -z "$st" ] && { printf 'no-space\t%s has: %s\n' "$who" "$spaces"; return 5; }
  if grep -q '=idle' <<<"$st"; then printf 'ok\t%s %s\n' "$who" "$(tr '\n' ' ' <<<"$st")"; return 0; fi
  printf 'busy\t%s %s\n' "$who" "$(tr '\n' ' ' <<<"$st")"; return 6
}

out=$(timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=5 "$user@$host" "$P workspace list" 2>&1); rc=$?
res=$(classify "$out" "$rc" "$user@$host"); code=$?

if [ $code -eq 2 ] || [ $code -eq 3 ]; then
  addr=$(sed -n "s/^$host=//p" "$HOME/.config/herdr-hosts.conf" 2>/dev/null | head -1)
  tc="$HOME/.local/bin/tailcat"
  if [ -n "$addr" ] && [ -x "$tc" ]; then
    out2=$(timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$HOME/.config/tailcat/known_hosts" \
      -o ProxyCommand="$tc $addr 22" \
      "$user@$host-tc" "$P workspace list" 2>&1); rc2=$?
    res2=$(classify "$out2" "$rc2" "$user@$host (tailcat)"); code2=$?
    if [ $code2 -ne 2 ] && [ $code2 -ne 3 ]; then printf '%s\n' "$res2"; exit $code2; fi
  fi
fi
printf '%s\n' "$res"; exit $code
