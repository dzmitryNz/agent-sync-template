#!/usr/bin/env bash
# Cursor hook: same herdr pane metadata as Claude (title, branch, usage, battery,
# working tool, tab label). Translates the Cursor payload and runs herdr-pane-meta.sh
# under the cursor agent name so the two sources do not wipe each other.
# preToolUse must answer with permission JSON; an empty stdout blocks the tool.
set -u

payload="$(cat 2>/dev/null || true)"

# Detect the event even without jq so preToolUse always gets an allow reply.
event=""
if command -v jq >/dev/null 2>&1 && [ -n "$payload" ]; then
  event="$(jq -r '.hook_event_name // ""' <<<"$payload" 2>/dev/null || true)"
elif [ -n "$payload" ]; then
  event="$(printf '%s' "$payload" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
fi

if [ "$event" = preToolUse ]; then
  # Every exit path (missing jq/meta, bad translate, early return) must print allow.
  trap 'printf "%s\n" "{\"permission\":\"allow\"}"' EXIT
fi

command -v jq >/dev/null 2>&1 || exit 0
[ -n "$payload" ] || exit 0
[ -n "$event" ] || exit 0

case "$event" in
  sessionStart)       mapped=SessionStart ;;
  beforeSubmitPrompt) mapped=UserPromptSubmit ;;
  preToolUse)         mapped=PreToolUse ;;
  stop)               mapped=Stop ;;
  subagentStop)       mapped=SubagentStop ;;
  sessionEnd)         mapped=SessionEnd ;;
  *)                  exit 0 ;;
esac

meta="${HERDR_PANE_META:-$HOME/.claude/hooks/herdr-pane-meta.sh}"
[ -x "$meta" ] || exit 0

translated="$(jq -c --arg e "$mapped" '
  .hook_event_name = $e
  | .cwd = (.cwd // (.workspace_roots // [])[0] // "")
  | .prompt = (.prompt // "")
  | .tool_name = (.tool_name // "")
  | .transcript_path = (if .transcript_path == null then "" else .transcript_path end)
  | .tool_input |= (
      if type == "object" and (.file_path == null) and ((.path | type) == "string")
      then . + {file_path: .path}
      else . end)
' <<<"$payload" 2>/dev/null)" || exit 0

printf '%s\n' "$translated" \
  | HERDR_META_SOURCE=cursor-hook HERDR_META_AGENT=cursor "$meta"

exit 0
