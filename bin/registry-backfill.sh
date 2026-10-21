#!/usr/bin/env bash
# Restores the session registry from transcripts that already exist.
# Needed once after the hook is connected: sessions started before it would not
# appear in the list — Claude Code reads hooks when a session starts.
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

PROJECTS_DIR="${PROJECTS_DIR:-$HOME/.claude/projects}"
SESSIONS_DIR="${SESSIONS_DIR:-$HOME/.agent-sync/sessions}"
HOST="${SESSIONS_HOST:-$(hostname -s 2>/dev/null || echo unknown)}"
MAX_AGE="${SESSIONS_MAX_AGE_DAYS:-30}"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
dir="$SESSIONS_DIR/$HOST"
mkdir -p "$dir"

ignore_re="$(cat "$(dirname "$(readlink -f "$0")")/role-agent-prompts.ere" 2>/dev/null)"
[ -n "${SESSIONS_IGNORE_PROMPTS:-}" ] && ignore_re="${ignore_re:+$ignore_re|}$SESSIONS_IGNORE_PROMPTS"

added=0
while IFS= read -r f; do
  sid="$(basename "$f" .jsonl)"
  out="$dir/$sid.json"
  # a live record is richer: it has herdr data that the transcript lacks
  [ -e "$out" ] && continue
  # subagent (Task) transcript: it cannot be continued, claude --resume does not know such an id
  case "$sid" in agent-*) continue ;; esac

  # The first user prompt = the session description. Sessions started by a slash command
  # or by a continuation open with a service block (<local-command-caveat>,
  # <command-name>): taking it as the description would make the whole list look the same.
  # One line per message: "p<TAB>prompt", "c<TAB>/command", "s<TAB>" — a service block.
  # isMeta — a skill body inserted by Claude Code, not the user's words.
  turns="$(jq -rs '
      map(select(.type == "user" and (.isMeta | not))
          | .message.content
          | if type == "string" then . else (map(select(.type=="text").text) | join(" ")) end)
      | map(select(. != null and . != "") | gsub("\n"; " "))
      | map(if test("<command-name>") then "c\t" + capture("<command-name>(?<n>[^<]*)").n
            elif test("^\\s*<") then "s\t"
            else "p\t" + . end)
      | .[]' "$f" 2>/dev/null)"
  [ -n "$turns" ] || continue

  # herdr standing role agents — the same filter as in session-record.sh.
  # The first thing said in the session decides: /clear and /model before /agent-qa do not count.
  if [ -n "$ignore_re" ]; then
    role=0
    while IFS=$'\t' read -r kind text; do
      [ "$kind" = s ] && continue
      printf '%s' "$text" | grep -qE "$ignore_re" && { role=1; break; }
      [ "$kind" = p ] && break
    done <<<"$turns"
    [ "$role" = 1 ] && continue
  fi

  prompt="$(printf '%s\n' "$turns" | sed -n 's/^p\t//p' | head -1)"
  # A session started by a slash command is named by that command: otherwise half of
  # the registry is "no description", and herdr /usage sessions cannot be filtered by name.
  [ -z "$prompt" ] && prompt="$(printf '%s\n' "$turns" | sed -n 's/^c\t//p' | head -1)"
  # a transcript of only service blocks gets no description but still enters the registry:
  # without a record such a session cannot be found or continued
  prompt="$(jq -rn --arg p "$prompt" '$p | gsub("\\s+"; " ") | .[0:120]' 2>/dev/null)"
  case "$prompt" in /usage|/usage\ *|/cost|/cost\ *|/status|/status\ *) continue ;; esac

  # The real path is in the transcript. Reversing the folder slug
  # ("-home-me-proj") breaks on names with dashes: web-login-redirect.
  cwd="$(jq -rs 'map(select(.cwd != null) | .cwd) | (.[0] // "")' "$f" 2>/dev/null)"
  if [ -z "$cwd" ]; then
    slug="$(basename "$(dirname "$f")")"
    cwd="$(printf '%s' "$slug" | sed 's|-|/|g')"
  fi

  started="$(date -u -d "@$(stat -c %Y "$f")" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
  jq -n --arg sid "$sid" --arg host "$HOST" --arg home "$HOME" \
        --arg cwd "$cwd" --arg prompt "$prompt" --arg transcript "$f" \
        --arg ts "$started" \
    '{session_id:$sid, agent:"claude", host:$host, home:$home, cwd:$cwd,
      transcript:$transcript, started_at:$ts, last_seen:$ts,
      first_prompt:$prompt, last_prompt:$prompt,
      herdr:{workspace:"", tab:"", pane:""}}' > "$out" 2>/dev/null && added=$((added+1))
done < <(find "$PROJECTS_DIR" -type f -name '*.jsonl' -mtime "-$MAX_AGE" 2>/dev/null)

echo "records restored: $added"
exit 0
