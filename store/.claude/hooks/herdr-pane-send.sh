#!/usr/bin/env bash
# herdr-pane-send.sh <pane_id> [message] — send a message to the agent in a pane on this host.
# The message comes from the argument, or from stdin if there is no argument.
# agent prompt sends the text as a paste and Enter atomically. With Cursor, send-text + Enter leaves
# a copy of the text in the input field, and it sticks to the next message to this pane.
# send-text is only a fallback for panes without a named agent (agent_not_ready, e.g. mimo).
set -u
for _compat in "$(dirname "$(readlink -f "$0")")/../../../bin/lib/compat.sh" "${SYNC_HOME:-$HOME/.agent-sync}/bin/lib/compat.sh"; do [ -f "$_compat" ] && { . "$_compat" || exit 1; break; }; done

pane=${1:?pane_id}; shift
msg=${1-}
[ $# -eq 0 ] && msg=$(cat)
[ -z "$msg" ] && { printf 'send-fail\tempty message\n' >&2; exit 1; }

out=$(herdr agent prompt "$pane" "$msg" 2>&1)
if jq -e '.result and (.error | not)' <<<"$out" >/dev/null 2>&1; then
  printf 'sent\t%s\n' "$pane"; exit 0
fi
if jq -e '.error.code == "agent_not_ready"' <<<"$out" >/dev/null 2>&1; then
  herdr pane send-text "$pane" "$msg" >/dev/null && herdr pane send-keys "$pane" Enter >/dev/null &&
    { printf 'sent\t%s (send-text)\n' "$pane"; exit 0; }
fi
printf 'send-fail\t%s: %s\n' "$pane" "$(head -c 200 <<<"$out" | tr '\n' ' ')" >&2; exit 1
