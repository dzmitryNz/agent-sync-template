#!/usr/bin/env bash
set -uo pipefail
for _compat in "$(dirname "$(readlink -f "$0")")/../../../bin/lib/compat.sh" "${SYNC_HOME:-$HOME/.agent-sync}/bin/lib/compat.sh"; do [ -f "$_compat" ] && { . "$_compat" || exit 1; break; }; done

# Guard against recursion: `claude -p` below spawns a child session that
# would otherwise re-trigger this same SessionStart hook.
if [ -n "${AGENT_SYNC_USAGE_HOOK_RUNNING:-}" ]; then
  exit 0
fi

output=$(AGENT_SYNC_USAGE_HOOK_RUNNING=1 timeout 20 claude -p "/usage" 2>/dev/null)
status=$?

if [ $status -ne 0 ] || [ -z "$output" ]; then
  exit 0
fi

jq -n --arg ctx "$output" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: ("Current limit data (claude -p \"/usage\"), do not rely on stale numbers from memory:\n" + $ctx)}}' \
  2>/dev/null || exit 0
