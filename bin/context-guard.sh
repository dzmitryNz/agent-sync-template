#!/usr/bin/env bash
# UserPromptSubmit hook: warns the AGENT that the context has grown large, so it
# records progress in the plan and offers /compact or a new session. Opus/Sonnet
# with a 1M window compact on their own only near ~967k, and every turn rereads the whole context.
#
# The size comes from the usage of the last main-branch reply in the transcript
# (subagent sidechains do not count). The warning repeats only when the context
# grows by CONTEXT_REWARN_STEP.
set -u
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

STATE_DIR="${CONTEXT_STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/claude-context-guard}"
WARN="${CONTEXT_WARN_TOKENS:-150000}"
STEP="${CONTEXT_REWARN_STEP:-50000}"
PLANS_DIR="$HOME/.claude/plans"

# Read all input at once, otherwise the caller gets SIGPIPE (see limit-guard.sh)
payload="$(cat 2>/dev/null)"

transcript="$(jq -r '.transcript_path // empty' <<<"$payload" 2>/dev/null)"
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

tokens="$(tail -n 400 "$transcript" 2>/dev/null \
  | jq -R 'fromjson? | select(.type == "assistant" and (.isSidechain | not))
      | .message.usage // empty
      | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)' 2>/dev/null \
  | tail -n 1)"
case "$tokens" in ''|*[!0-9]*) exit 0 ;; esac
[ "$tokens" -ge "$WARN" ] || exit 0

level=$(( (tokens - WARN) / STEP ))
sid="$(jq -r '.session_id // "unknown"' <<<"$payload" 2>/dev/null)"
marker="$STATE_DIR/warned-${sid//[^A-Za-z0-9]/_}"
prev="$(cat "$marker" 2>/dev/null)"
case "$prev" in ''|*[!0-9]*) prev=-1 ;; esac
[ "$level" -gt "$prev" ] || exit 0
mkdir -p "$STATE_DIR" 2>/dev/null
printf '%s\n' "$level" > "$marker" 2>/dev/null

cat <<EOF
[agent-sync] The session context is ~$(( tokens / 1000 ))k tokens: every turn rereads all of it.

At the nearest natural task boundary (not in the middle of an edit):
1. Update the plan in $PLANS_DIR: done items [x], remaining items [ ], where you
   stopped and the next step. After compaction the details (paths, ids, reasons for decisions) are lost.
2. Offer the user /compact or a new session that picks up from the plan.
Do not /clear (or suggest it) until you have confirmed the recipient got what you sent
([* REQUEST]/[* RESULT]): `herdr-handoff.sh` exited 0 or the message is visible in the
recipient's pane. Without confirmation, check the pane first; a lost message cannot be recovered
after a reset.
If the task is about to finish, just finish it; no compaction is needed.
EOF
exit 0
