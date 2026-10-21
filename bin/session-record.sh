#!/usr/bin/env bash
# Claude Code hook: keeps a session registry, so tomorrow (or from another machine)
# you can find the right session and continue it without digging through history.
#
# Attached to SessionStart / UserPromptSubmit / Stop / SessionEnd.
# The event arrives as JSON on stdin. The hook must be quiet and never fail:
# it runs on every prompt, and a crash would break the agent's work.
set -u
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

SESSIONS_DIR="${SESSIONS_DIR:-$HOME/.agent-sync/sessions}"
HOST="${SESSIONS_HOST:-$(hostname -s 2>/dev/null || echo unknown)}"
MAX_AGE="${SESSIONS_MAX_AGE_DAYS:-30}"

command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null)"
sid="$(jq -r '.session_id // .conversation_id // ""' <<<"$payload" 2>/dev/null)"
[ -n "$sid" ] && [ "$sid" != null ] || exit 0

dir="$SESSIONS_DIR/$HOST"
mkdir -p "$dir" 2>/dev/null || exit 0
file="$dir/$sid.json"

cwd="$(jq -r '.cwd // (.workspace_roots // [])[0] // ""' <<<"$payload" 2>/dev/null)"
prompt="$(jq -r '.prompt // ""'       <<<"$payload" 2>/dev/null)"
transcript="$(jq -r '.transcript_path // ""' <<<"$payload" 2>/dev/null)"
[ "$transcript" = null ] && transcript=''

# Cursor runs both its own hooks and ~/.claude/settings.json: the second call comes
# without AGENT and used to overwrite cursor back to claude. An explicit AGENT wins;
# otherwise we detect Cursor by the transcript path / payload fields and do not roll back.
cursor_hint="$(jq -r '
  if (.cursor_version // "") != "" then "cursor"
  elif ((.workspace_roots // []) | length) > 0 then "cursor"
  elif .hook_event_name == "beforeSubmitPrompt" then "cursor"
  elif .hook_event_name == "sessionStart" then "cursor"
  elif .hook_event_name == "sessionEnd" then "cursor"
  elif .hook_event_name == "stop" then "cursor"
  else ""
  end
' <<<"$payload" 2>/dev/null)"
case "$transcript" in
  */.cursor/*|*/agent-transcripts/*) cursor_hint=cursor ;;
esac

# The plan file, if the agent was just writing one: a fresh session picks up the work
# from the plan (kilobytes), not from the transcript (hundreds of kilobytes).
plan=''
touched="$(jq -r '.tool_input.file_path // ""' <<<"$payload" 2>/dev/null)"
case "$touched" in
  */.claude/plans/*.md|*/docs/plans/*.md) plan="$touched" ;;
esac
now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# The session description is the first prompt: it best answers "what was this about".
# Long ones are cut so the list stays readable. We cut with jq: GNU cut -c
# counts bytes and splits Cyrillic in half, and jq cannot write half a character.
prompt="$(jq -rn --arg p "$prompt" '$p | gsub("\\s+"; " ") | .[0:120]' 2>/dev/null)"

# Only a user prompt creates a record. Otherwise service sessions flood the registry:
# the herdr hook runs `claude -p /usage` every 5 minutes to read the limit percent,
# and such three-second sessions push real work out of the list.
# Events without a prompt (SessionStart, Stop, SessionEnd) update an existing record.
if [ ! -f "$file" ]; then
  [ -z "$prompt" ] && exit 0
  case "$prompt" in
    /usage|/usage\ *|/cost|/cost\ *|/status|/status\ *) exit 0 ;;
  esac
  # herdr standing role agents (Review, QA, DevOps, Logs, Developer, DB, Cleaner)
  # and requests to them: there are more of their sessions than real ones, and they push
  # real work out of the list. registry-backfill.sh and /retro (mine.py) read the same list.
  ignore_re="$(cat "$(dirname "$(readlink -f "$0")")/role-agent-prompts.ere" 2>/dev/null)"
  # the extra filter is a regex, not a "|" list in a case
  [ -n "${SESSIONS_IGNORE_PROMPTS:-}" ] && ignore_re="${ignore_re:+$ignore_re|}$SESSIONS_IGNORE_PROMPTS"
  if [ -n "$ignore_re" ] && printf '%s' "$prompt" | grep -qE "$ignore_re"; then
    exit 0
  fi
fi

prev='{}'
[ -f "$file" ] && prev="$(cat "$file" 2>/dev/null)" && [ -n "$prev" ] || prev='{}'

tmp="$file.tmp.$$"
jq -n \
  --argjson prev "$prev" \
  --arg sid "$sid" --arg host "$HOST" --arg home "$HOME" \
  --arg agent "${AGENT:-}" \
  --arg cursor_hint "${cursor_hint:-}" \
  --arg cwd "$cwd" --arg prompt "$prompt" --arg transcript "$transcript" \
  --arg now "$now" --arg plan "$plan" \
  --arg ws "${HERDR_WORKSPACE_ID:-}" --arg tab "${HERDR_TAB_ID:-}" --arg pane "${HERDR_PANE_ID:-}" \
  '{
     session_id:   $sid,
     agent:        (if $agent != "" then $agent
                    elif $cursor_hint == "cursor" then "cursor"
                    elif (($prev.transcript // "") | test("/\\.cursor/|/agent-transcripts/")) then "cursor"
                    else ($prev.agent // "claude") end),
     host:         $host,
     home:         $home,
     cwd:          (if $cwd != "" then $cwd else ($prev.cwd // "") end),
     transcript:   (if $transcript != "" then $transcript else ($prev.transcript // "") end),
     started_at:   ($prev.started_at // $now),
     last_seen:    $now,
     first_prompt: (if ($prev.first_prompt // "") != "" then $prev.first_prompt
                    else $prompt end),
     plan:         (if $plan != "" then $plan else ($prev.plan // "") end),
     last_prompt:  (if $prompt != "" then $prompt else ($prev.last_prompt // "") end),
     herdr: {
       workspace: (if $ws   != "" then $ws   else ($prev.herdr.workspace // "") end),
       tab:       (if $tab  != "" then $tab  else ($prev.herdr.tab       // "") end),
       pane:      (if $pane != "" then $pane else ($prev.herdr.pane      // "") end)
     }
   }' > "$tmp" 2>/dev/null && mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null

# Claude deletes transcripts older than 30 days itself — keep the registry in the same window,
# otherwise it would offer sessions that no longer exist.
find "$SESSIONS_DIR" -type f -name '*.json' -mtime "+$MAX_AGE" -delete 2>/dev/null

exit 0
