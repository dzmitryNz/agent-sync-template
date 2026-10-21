#!/usr/bin/env bash
# herdr-handoff.sh [--no-clear] <pane_id> <skill> [message] — reliably deliver a request to a role agent.
# Sequence: /clear → /<skill> → wait until the pane is quiet → request → verify the request
# is visible in the pane (one retry). Without this, requests are lost when they arrive while the
# pane is still processing /clear or /<skill> (herdr agent prompt --wait returns too early).
# Message from the argument or stdin. --no-clear: continue the previous task in the same pane
# (review fixes): skip /clear and /<skill>. Non-claude panes (cursor, mimo): send the request directly.
# Exit: 0 request visible; 1 not visible or send error; 2 agent has not sent [TAG RESULT] for the
# previous request (marker from role-clear.sh Stop hook) — /clear would drop it.
set -u
for _compat in "$(dirname "$(readlink -f "$0")")/../../../bin/lib/compat.sh" "${SYNC_HOME:-$HOME/.agent-sync}/bin/lib/compat.sh"; do [ -f "$_compat" ] && { . "$_compat" || exit 1; break; }; done

clear=1
[ "${1-}" = "--no-clear" ] && { clear=0; shift; }
pane=${1:?pane_id}; skill=${2:?skill e.g. agent-developer}; shift 2
msg=${1-}
[ $# -eq 0 ] && msg=$(cat)
[ -z "$msg" ] && { echo "handoff-fail: empty message" >&2; exit 1; }

send=~/.claude/hooks/herdr-pane-send.sh
marker=$(printf '%s\n' "$msg" | sed -n '1p' | cut -c1-60)

status() { herdr agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // "unknown"'; }
count_marker() { herdr pane read "$pane" --source recent-unwrapped --lines 400 2>/dev/null | grep -cF -- "$marker"; }

# Quiet = not working for three polls in a row at 2s (status may flash idle before work starts).
settle() {
  local quiet=0 i
  sleep "${HANDOFF_SETTLE_START:-3}"
  for i in $(seq 1 90); do
    if [ "$(status)" = "working" ]; then quiet=0; else quiet=$((quiet + 1)); fi
    [ "$quiet" -ge 3 ] && return 0
    sleep "${HANDOFF_POLL:-2}"
  done
  echo "handoff-fail: pane $pane did not settle within 3 minutes" >&2; return 1
}

kind=$(herdr agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent // empty')
[ -z "$kind" ] && { echo "handoff-fail: pane $pane has no named agent" >&2; exit 1; }

if [ "$kind" = "claude" ] && [ "$clear" -eq 1 ]; then
  pending=~/.cache/agent-roles/pending-${pane//[^A-Za-z0-9]/_}
  if [ -f "$pending" ] && [ -n "$(find "$pending" -mmin -180 2>/dev/null)" ]; then
    echo "handoff-busy: pane $pane has not sent [$(cat "$pending") RESULT] yet; use another idle instance or queue" >&2
    exit 2
  fi
  settle || exit 1
  "$send" "$pane" "/clear" >/dev/null || exit 1
  settle || exit 1
  "$send" "$pane" "/$skill" >/dev/null || exit 1
  settle || exit 1
fi

before=$(count_marker)
for attempt in 1 2; do
  "$send" "$pane" "$msg" >/dev/null || exit 1
  for i in 1 2 3 4 5 6 7 8; do
    sleep "${HANDOFF_POLL:-2}"
    if [ "$(count_marker)" -gt "$before" ]; then
      printf 'handoff-ok\t%s\t%s\n' "$pane" "$skill"; exit 0
    fi
  done
  [ "$(status)" = "working" ] && { printf 'handoff-ok\t%s\t%s (working)\n' "$pane" "$skill"; exit 0; }
done
echo "handoff-fail: request not visible in pane $pane after two sends" >&2; exit 1
