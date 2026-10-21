#!/usr/bin/env bash
# Hook wrapper: takes or releases the sleep lock on a Claude Code event.
#   work started (UserPromptSubmit)                -> acquire
#   reply finished / input needed / session closed -> release
set -u
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1
payload="$(cat 2>/dev/null)"
command -v jq >/dev/null 2>&1 || exit 0
event="$(jq -r '.hook_event_name // ""' <<<"$payload" 2>/dev/null)"
sid="$(jq -r '.session_id // ""' <<<"$payload" 2>/dev/null)"
[ -n "$sid" ] && [ "$sid" != null ] || exit 0
case "$event" in
  UserPromptSubmit)                 "$(dirname "$0")/keep-awake.sh" acquire "$sid" ;;
  Stop|SessionEnd|Notification)     "$(dirname "$0")/keep-awake.sh" release "$sid" ;;
esac
exit 0
