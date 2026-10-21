#!/usr/bin/env bash
# Records the CURRENT session in the `agent-sessions list` registry.
# Needed for sessions started before the hook was connected: Claude Code reads hooks at
# start, so those sessions do not record themselves.
#
#   register-me.sh --id <session-id> "what I am working on"
#   register-me.sh "what I am working on"      # only if the project has one session
#
# The agent knows its own id from its scratchpad path: /tmp/claude-<uid>/<slug>/<id>/
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

SESSIONS_DIR="${SESSIONS_DIR:-$HOME/.agent-sync/sessions}"
sid=''
[ "${1:-}" = --id ] && { sid="${2:?--id needs a value}"; shift 2; }
desc="${1:-}"
[ -n "$desc" ] || { echo 'give a description: register-me.sh [--id <session-id>] "what I am working on"' >&2; exit 2; }

cwd="${CWD_OVERRIDE:-$PWD}"
dir="${PROJECT_DIR_OVERRIDE:-$HOME/.claude/projects/${cwd//\//-}}"

if [ -z "$sid" ]; then
  # Auto-detect only when there is no ambiguity. "The newest transcript"
  # is the session that answered last, not the one running this script: with
  # parallel work we would record another session over our own.
  mapfile -t found < <(ls -t "$dir"/*.jsonl 2>/dev/null)
  case "${#found[@]}" in
    0) echo "no transcripts found for $cwd — pass the id: --id <session-id>" >&2; exit 1 ;;
    1) sid="$(basename "${found[0]}" .jsonl)" ;;
    *) echo "this project has ${#found[@]} sessions — an explicit id is needed: --id <session-id>" >&2
       echo "your id is in the scratchpad path: /tmp/claude-\$(id -u)/<slug>/<session-id>/" >&2
       exit 1 ;;
  esac
fi

transcript="$dir/$sid.jsonl"
[ -f "$transcript" ] || transcript=''

host="${SESSIONS_HOST:-$(hostname -s 2>/dev/null || echo unknown)}"
record="$SESSIONS_DIR/$host/$sid.json"
existed=''
[ -f "$record" ] && existed=1

recorder="$(dirname "$(readlink -f "$0")")/session-record.sh"
[ -x "$recorder" ] || { echo "session-record.sh not found next to this script: $recorder" >&2; exit 1; }

jq -nc --arg s "$sid" --arg c "$cwd" --arg p "$desc" --arg t "$transcript" \
  '{hook_event_name:"UserPromptSubmit", session_id:$s, cwd:$c, prompt:$p, transcript_path:$t}' \
  | "$recorder"

# session-record.sh is a hook: it must stay silent and exit 0 on any failure,
# so we judge success by the record itself, not by the exit code.
[ -f "$record" ] || { echo "could not write the record: $record" >&2; exit 1; }

echo "recorded: [${sid:0:8}] $desc"
# an existing record keeps its description: first_prompt answers
# "what was this about", not "what is happening now"
[ -n "$existed" ] && echo "the record already existed — the description is unchanged, only the time was updated"
echo "check: agent-sessions list"
