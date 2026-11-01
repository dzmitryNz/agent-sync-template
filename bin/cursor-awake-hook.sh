#!/usr/bin/env bash
# Cursor keep-awake. beforeSubmitPrompt acquires, stop and sessionEnd release.
# Prints nothing: a JSON body here would be merged into the hook response.
set -u

command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null)"
event="$(jq -r '.hook_event_name // ""' <<<"$payload" 2>/dev/null)"
case "$event" in
  beforeSubmitPrompt) mapped=UserPromptSubmit ;;
  stop)               mapped=Stop ;;
  sessionEnd)         mapped=SessionEnd ;;
  *)                  exit 0 ;;
esac

sid="$(jq -r '.session_id // .conversation_id // ""' <<<"$payload" 2>/dev/null)"
[ -n "$sid" ] && [ "$sid" != null ] || exit 0

bin="$(dirname "$(readlink -f "$0")")"
jq -nc --arg e "$mapped" --arg s "$sid" \
  '{hook_event_name:$e, session_id:$s}' \
  | "$bin/awake-hook.sh"
exit 0
