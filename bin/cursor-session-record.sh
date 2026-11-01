#!/usr/bin/env bash
# Cursor hook: maps its event into session-record.sh so Cursor sessions enter the
# same registry as Claude (`agent-sessions list`).
#
# Wire in ~/.cursor/hooks.json on sessionStart / beforeSubmitPrompt / stop /
# sessionEnd. Pane herdr labels come from cursor-pane-meta.sh, not this script.
# Like session-record.sh, it must stay quiet and always exit 0.
#
# Cursor payload differences: its own event names and `workspace_roots`
# (array) instead of `cwd`.
set -u

command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null)"
[ -n "$payload" ] || exit 0

event="$(jq -r '.hook_event_name // ""' <<<"$payload" 2>/dev/null)"
case "$event" in
  sessionStart)       claude_event=SessionStart ;;
  beforeSubmitPrompt) claude_event=UserPromptSubmit ;;
  stop)               claude_event=Stop ;;
  sessionEnd)         claude_event=SessionEnd ;;
  *)                  exit 0 ;;  # beforeShellExecution and other mechanics — not ours
esac

sid="$(jq -r '.session_id // .conversation_id // ""' <<<"$payload" 2>/dev/null)"
[ -n "$sid" ] && [ "$sid" != null ] || exit 0

cwd="$(jq -r '.cwd // (.workspace_roots // [])[0] // ""' <<<"$payload" 2>/dev/null)"
prompt="$(jq -r '.prompt // ""' <<<"$payload" 2>/dev/null)"
transcript="$(jq -r '.transcript_path // ""' <<<"$payload" 2>/dev/null)"
[ "$transcript" = null ] && transcript=''

jq -nc --arg e "$claude_event" --arg s "$sid" --arg c "$cwd" \
       --arg p "$prompt" --arg t "$transcript" \
  '{hook_event_name:$e, session_id:$s, cwd:$c, prompt:$p, transcript_path:$t}' \
  2>/dev/null \
  | AGENT=cursor "$(dirname "$(readlink -f "$0")")/session-record.sh"

exit 0
