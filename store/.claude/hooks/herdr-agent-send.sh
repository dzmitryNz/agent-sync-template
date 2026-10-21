#!/usr/bin/env bash
# herdr-agent-send.sh <host> <pane_id|--label LABEL> [message]  — send a request to an agent on another host.
# The message comes from the argument, or from stdin if there is no argument:
#   herdr-agent-send.sh <host> w1K:p1 "[DEVOPS REQUEST] ..."
#   herdr-agent-send.sh <host> --label DevOps < request.txt
# Exit 0 — herdr accepted the prompt. Otherwise STATUS<TAB>details on stderr and a non-zero exit code:
#   no-pane    the given pane_id/label was not found on the host
#   busy       the agent in this space is working now — do not send, it would cut into another context
#   ssh-auth   Tailscale asks for re-authorization and there is no tailcat fallback (no address set)
#   ssh-down   the host is unreachable over both channels
#   send-fail  the channel works, but herdr prompt returned an error
# The channel is the same as in herdr-host-ping.sh: Tailscale SSH first, tailcat if it fails
# (~/.config/herdr-hosts.conf, agent-sync README "Cross-host SSH via tailcat").
set -u
for _compat in "$(dirname "$(readlink -f "$0")")/../../../bin/lib/compat.sh" "${SYNC_HOME:-$HOME/.agent-sync}/bin/lib/compat.sh"; do [ -f "$_compat" ] && { . "$_compat" || exit 1; break; }; done

host=${1:?host}; shift
if [ "${1:-}" = "--label" ]; then label=${2:?label}; pane=""; shift 2; else pane=${1:?pane_id or --label}; label=""; shift; fi
msg=
if [ "${1:-}" = "--file" ] || [ "${1:-}" = "-f" ]; then
  msg=$(cat "${2:?--file needs a path}")
else
  msg=${1-}
  [ $# -eq 0 ] && msg=$(cat)
fi
[ -z "$msg" ] && { printf 'send-fail\tempty message\n' >&2; exit 1; }

if [ "$host" = "$(hostname)" ]; then
  printf 'send-fail\t%s is this machine, use local herdr\n' "$host" >&2; exit 1
fi

user=$(jq -r '.home' ~/.agent-sync/sessions/"$host"/*.json 2>/dev/null | sort -u | head -1 | xargs -r basename)
user=${user:-$USER}
P='[ -d /run/user/$(id -u) ] && export XDG_RUNTIME_DIR=/run/user/$(id -u); PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH; herdr'

# run <remote-command> — prints the output, returns the ssh exit code; tries the direct channel, then tailcat
run() {
  local out rc addr tc
  out=$(timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=5 "$user@$host" "$1" 2>&1); rc=$?
  if [ $rc -ne 255 ] && [ $rc -ne 124 ] && ! grep -q 'login.tailscale.com' <<<"$out"; then
    printf '%s' "$out"; return $rc
  fi
  addr=$(sed -n "s/^$host=//p" "$HOME/.config/herdr-hosts.conf" 2>/dev/null | head -1)
  tc="$HOME/.local/bin/tailcat"
  if [ -z "$addr" ] || [ ! -x "$tc" ]; then printf '%s' "$out"; return $rc; fi
  timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$HOME/.config/tailcat/known_hosts" \
    -o ProxyCommand="$tc $addr 22" \
    "$user@$host-tc" "$1" 2>&1
}

ws=$(run "$P workspace list"); rc=$?
if ! jq -e '.result.workspaces' <<<"$ws" >/dev/null 2>&1; then
  if grep -q 'login.tailscale.com' <<<"$ws"; then
    printf 'ssh-auth\t%s: %s\n' "$host" "$(grep -o 'https://[^ ]*' <<<"$ws" | head -1)" >&2; exit 2
  fi
  printf 'ssh-down\t%s rc=%s: %s\n' "$host" "$rc" "$(head -c 160 <<<"$ws" | tr '\n' ' ')" >&2; exit 3
fi

# label → workspace_id + busy check; for an explicit pane_id take its workspace by the prefix
if [ -n "$label" ]; then
  wsid=$(jq -r --arg l "$label" '.result.workspaces[] | select(.label==$l or (.label|startswith($l+"-"))) | select(.agent_status=="idle") | .workspace_id' <<<"$ws" | head -1)
  if [ -z "$wsid" ]; then
    any=$(jq -r --arg l "$label" '.result.workspaces[] | select(.label==$l or (.label|startswith($l+"-"))) | "\(.label)=\(.agent_status)"' <<<"$ws" | tr '\n' ' ')
    [ -n "$any" ] && { printf 'busy\t%s: %s\n' "$host" "$any" >&2; exit 6; }
    printf 'no-pane\t%s: no space with label %s. Available: %s\n' "$host" "$label" \
      "$(jq -r '.result.workspaces[].label' <<<"$ws" | tr '\n' ' ')" >&2; exit 5
  fi
  panes=$(run "$P pane list --workspace $wsid")
  pane=$(jq -r '.result.panes[0].pane_id' <<<"$panes" 2>/dev/null)
  [ -z "$pane" ] || [ "$pane" = "null" ] && { printf 'no-pane\t%s: no pane in %s\n' "$host" "$wsid" >&2; exit 5; }
else
  st=$(jq -r --arg w "${pane%%:*}" '.result.workspaces[] | select(.workspace_id==$w) | .agent_status' <<<"$ws")
  [ -z "$st" ] && { printf 'no-pane\t%s: no workspace %s\n' "$host" "${pane%%:*}" >&2; exit 5; }
  [ "$st" = "working" ] && { printf 'busy\t%s: %s working\n' "$host" "${pane%%:*}" >&2; exit 6; }
fi

# Send the body as base64 — nested " and the length would otherwise break the ssh command and the local quotes
b64=$(printf '%s' "$msg" | base64 -w0 2>/dev/null || printf '%s' "$msg" | base64 | tr -d '\n')
remote_cmd="[ -d /run/user/\$(id -u) ] && export XDG_RUNTIME_DIR=/run/user/\$(id -u); PATH=\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH; msg=\$(printf '%s' '${b64}' | base64 -d); herdr agent prompt ${pane} \"\$msg\""
out=$(run "$remote_cmd")
if jq -e '.result.type == "agent_prompted"' <<<"$out" >/dev/null 2>&1; then
  printf 'sent\t%s %s\n' "$host" "$pane"; exit 0
fi
printf 'send-fail\t%s %s: %s\n' "$host" "$pane" "$(head -c 200 <<<"$out" | tr '\n' ' ')" >&2; exit 4
