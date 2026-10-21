#!/usr/bin/env bash
# Stop hook: a standing herdr agent (Review, QA, DB, Logs, ...) finished a request but its
# context grew — send /clear to its pane. Each [* REQUEST] is self-contained per the skill
# protocol; piled-up context from past requests is reread on every turn.
#
# A role session is one whose FIRST prompt matches role-agent-prompts.ere.
# /clear runs in the background after a delay: the Stop hook must return before the TUI accepts input.
# Then /agent-<role>: without the skill protocol a cleared agent does not send replies back.
set -u
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

WARN="${ROLE_CLEAR_TOKENS:-100000}"
DELAY="${ROLE_CLEAR_DELAY:-3}"
SKILL_DELAY="${ROLE_SKILL_DELAY:-5}"

payload="$(cat 2>/dev/null)"
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
command -v herdr >/dev/null 2>&1 || exit 0

transcript="$(jq -r '.transcript_path // empty' <<<"$payload" 2>/dev/null)"
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

role_re="$(cat "$(dirname "$(readlink -f "$0")")/role-agent-prompts.ere" 2>/dev/null)"
[ -n "$role_re" ] || exit 0

# Requests arrive via herdr send-text wrapped in <pasted_content>; skills as
# <command-name>/agent-x</command-name>; /model and other commands may come first.
first="$(jq -R -r 'fromjson? | select(.type == "user" and (.isSidechain | not) and (.isMeta | not))
    | .message.content
    | if type == "string" then .
      else (map(select(.type == "text") | .text) | join("\n")) end
    | sub("^\\s*<(pasted_content|command-name)[^>]*>\\s*"; "")
    | split("\n")[0]' "$transcript" 2>/dev/null \
  | grep -m1 -E "$role_re")"
[ -n "$first" ] || exit 0

role=""
if [[ "$first" =~ agent-(review|developer|devops|qa|logs|db|cleaner) ]]; then
  role="${BASH_REMATCH[1]}"
elif [[ "$first" =~ \[(REVIEW|DEV|DEVOPS|QA|LOGS|DB|CLEANER)\ REQUEST\] ]]; then
  case "${BASH_REMATCH[1]}" in
    DEV) role=developer ;;
    *)   role="${BASH_REMATCH[1],,}" ;;
  esac
fi

# Last [TAG REQUEST] without a following [TAG RESULT] — work not finished
# (e.g. turn ended while background /code-review still runs): /clear would drop the reply.
# herdr-handoff.sh reads the marker so the pane is not cleared before the reply is sent.
pending="$(jq -R -r 'fromjson? | select(.isSidechain | not) |
  if .type == "user" and (.isMeta | not) then
    .message.content
    | if type == "string" then . else (map(select(.type == "text") | .text) | join("\n")) end
    | sub("^\\s*<pasted_content[^>]*>\\s*"; "")
    | capture("^\\[(?<t>[A-Z]+) REQUEST\\]")? | "REQ " + .t
  elif .type == "assistant" then
    .message.content[]? | select(.type == "tool_use") | .input | tostring
    | scan("\\[([A-Z]+) RESULT\\]")[] | "RES " + .
  else empty end' "$transcript" 2>/dev/null \
  | awk '$1 == "REQ" { p = $2 } $1 == "RES" && $2 == p { p = "" } END { print p }')"
marker="$HOME/.cache/agent-roles/pending-${HERDR_PANE_ID//[^A-Za-z0-9]/_}"
if [ -n "$pending" ]; then
  mkdir -p "${marker%/*}" && printf '%s\n' "$pending" > "$marker"
  exit 0
fi
rm -f "$marker"

tokens="$(tail -n 400 "$transcript" 2>/dev/null \
  | jq -R 'fromjson? | select(.type == "assistant" and (.isSidechain | not))
      | .message.usage // empty
      | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)' 2>/dev/null \
  | tail -n 1)"
case "$tokens" in ''|*[!0-9]*) exit 0 ;; esac
[ "$tokens" -ge "$WARN" ] || exit 0

pane="$HERDR_PANE_ID"
(
  sleep "$DELAY"
  herdr pane send-text "$pane" "/clear" && herdr pane send-keys "$pane" Enter || exit 0
  [ -n "$role" ] || exit 0
  sleep "$SKILL_DELAY"
  herdr pane send-text "$pane" "/agent-$role" && herdr pane send-keys "$pane" Enter
) >/dev/null 2>&1 </dev/null &
disown 2>/dev/null
exit 0
