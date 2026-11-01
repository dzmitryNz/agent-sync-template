#!/usr/bin/env bash
# Cursor beforeSubmitPrompt. Once per conversation, inject the herdr-space plan.
# plan-resume.sh only speaks when source=clear; Cursor has no /clear event,
# and a new conversation is the same moment. sessionStart additional_context
# is dropped in the Agents window, so this rides the first prompt instead.
set -u

command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null)"
event="$(jq -r '.hook_event_name // ""' <<<"$payload" 2>/dev/null)"
[ "$event" = beforeSubmitPrompt ] || exit 0

sid="$(jq -r '.session_id // .conversation_id // ""' <<<"$payload" 2>/dev/null)"
[ -n "$sid" ] && [ "$sid" != null ] || exit 0

state="${CURSOR_PLAN_STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/cursor-plan-resume}"
marker="$state/seen-${sid//[^A-Za-z0-9]/_}"
[ -d "$marker" ] && exit 0

bin="$(dirname "$(readlink -f "$0")")"
text="$(jq -nc --arg s "$sid" \
  '{hook_event_name:"SessionStart", source:"clear", session_id:$s}' \
  | "$bin/plan-resume.sh" 2>/dev/null)"
[ -n "$text" ] || exit 0

mkdir -p "$state" 2>/dev/null || exit 0
mkdir "$marker" 2>/dev/null || exit 0

jq -nc --arg t "$text" '{continue:true, additional_context:$t}'
exit 0
