#!/usr/bin/env bash
# Restores the session registry from transcripts and local agent DBs that already exist.
# Claude: jsonl under ~/.claude/projects (as before).
# OpenCode / Mimo: SQLite (~/.local/share/.../*.db) — registry gets metadata and
# transcript=sqlite:<db>; the DBs themselves are not put in git/store.
# Codex: TODO — different on-disk shape; add when a cheap path exists.
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

PROJECTS_DIR="${PROJECTS_DIR:-$HOME/.claude/projects}"
SESSIONS_DIR="${SESSIONS_DIR:-$HOME/.agent-sync/sessions}"
HOST="${SESSIONS_HOST:-$(hostname -s 2>/dev/null || echo unknown)}"
MAX_AGE="${SESSIONS_MAX_AGE_DAYS:-30}"
OPENCODE_DB="${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"
MIMO_DB="${MIMO_DB:-$HOME/.local/share/mimocode/mimocode.db}"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
dir="$SESSIONS_DIR/$HOST"
mkdir -p "$dir"

ignore_re="$(cat "$(dirname "$(readlink -f "$0")")/role-agent-prompts.ere" 2>/dev/null)"
[ -n "${SESSIONS_IGNORE_PROMPTS:-}" ] && ignore_re="${ignore_re:+$ignore_re|}$SESSIONS_IGNORE_PROMPTS"

ms_cutoff=$(( $(date -u +%s) * 1000 - MAX_AGE * 86400000 ))

sqlite3_quote() {
  local s="$1"; s="${s//\'/\'\'}"; printf "'%s'" "$s"
}

trim_prompt() {
  jq -rn --arg p "${1:-}" '$p | gsub("\\s+"; " ") | .[0:120]' 2>/dev/null
}

# Write or refresh a record. Do not wipe live herdr fields.
write_rec() { # sid agent cwd transcript first last started last_seen
  local sid="$1" agent="$2" cwd="$3" transcript="$4"
  local first="$5" last="$6" started="$7" seen="$8"
  local out="$dir/$sid.json"
  local prev='{}'
  [ -f "$out" ] && prev="$(cat "$out" 2>/dev/null)" && [ -n "$prev" ] || prev='{}'
  # do not overwrite a different agent already in the registry under this id
  local prev_agent; prev_agent="$(jq -r '.agent // ""' <<<"$prev" 2>/dev/null)"
  if [ -n "$prev_agent" ] && [ "$prev_agent" != "$agent" ]; then
    return 0
  fi
  jq -n --argjson prev "$prev" \
        --arg sid "$sid" --arg host "$HOST" --arg home "$HOME" \
        --arg agent "$agent" --arg cwd "$cwd" --arg transcript "$transcript" \
        --arg first "$first" --arg last "$last" \
        --arg started "$started" --arg seen "$seen" \
    '{
       session_id:   $sid,
       agent:        $agent,
       host:         $host,
       home:         $home,
       cwd:          (if $cwd != "" then $cwd else ($prev.cwd // "") end),
       transcript:   $transcript,
       started_at:   ($prev.started_at // $started),
       last_seen:    $seen,
       first_prompt: (if ($prev.first_prompt // "") != "" then $prev.first_prompt else $first end),
       last_prompt:  (if $last != "" then $last else ($prev.last_prompt // $first) end),
       plan:         ($prev.plan // ""),
       herdr: {
         workspace: ($prev.herdr.workspace // ""),
         tab:       ($prev.herdr.tab // ""),
         pane:      ($prev.herdr.pane // "")
       }
     }' > "$out.tmp.$$" 2>/dev/null && mv "$out.tmp.$$" "$out" 2>/dev/null || rm -f "$out.tmp.$$"
}

iso_from_ms() {
  date -u -d "@$(( ${1:-0} / 1000 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -r "$(( ${1:-0} / 1000 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null
}

should_skip_prompt() {
  local p="$1"
  case "$p" in /usage|/usage\ *|/cost|/cost\ *|/status|/status\ *) return 0 ;; esac
  if [ -n "$ignore_re" ] && printf '%s' "$p" | grep -qE "$ignore_re"; then
    return 0
  fi
  return 1
}

added=0
updated=0

# --- Claude jsonl -----------------------------------------------------------
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
  prompt="$(trim_prompt "$prompt")"
  case "$prompt" in /usage|/usage\ *|/cost|/cost\ *|/status|/status\ *) continue ;; esac

  # The real path is in the transcript. Reversing the folder slug
  # ("-home-me-proj") breaks on names with dashes: web-login-redirect.
  cwd="$(jq -rs 'map(select(.cwd != null) | .cwd) | (.[0] // "")' "$f" 2>/dev/null)"
  if [ -z "$cwd" ]; then
    slug="$(basename "$(dirname "$f")")"
    cwd="$(printf '%s' "$slug" | sed 's|-|/|g')"
  fi

  started="$(date -u -d "@$(stat -c %Y "$f")" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
  write_rec "$sid" claude "$cwd" "$f" "$prompt" "$prompt" "$started" "$started"
  added=$((added+1))
done < <(find "$PROJECTS_DIR" -type f -name '*.jsonl' -mtime "-$MAX_AGE" 2>/dev/null)

# --- OpenCode / Mimo SQLite -------------------------------------------------
# No hooks: periodic/manual backfill. Drop Claude→Mimo imports and skill-bootstrap
# titles; role prompts use the same ignore_re.

backfill_sqlite_agent() {
  local agent="$1" db="$2"
  [ -f "$db" ] || return 0
  command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 is required for $agent" >&2; return 0; }

  # One query per agent (not N+1): first/last user text via window functions.
  # US (\x1f) separator — rare in prompts; collapse newlines in SQL.
  local sql
  if [ "$agent" = opencode ]; then
    sql="
      WITH cand AS (
        SELECT id, directory, time_created, time_updated
        FROM session_v2
        WHERE time_archived IS NULL AND time_updated >= $ms_cutoff
      ),
      upts AS (
        SELECT session_id AS sid,
               replace(replace(json_extract(data,'\$.text'), char(10), ' '), char(13), ' ') AS t,
               row_number() OVER (PARTITION BY session_id ORDER BY seq) AS rn_first,
               row_number() OVER (PARTITION BY session_id ORDER BY seq DESC) AS rn_last
        FROM session_message
        WHERE session_id IN (SELECT id FROM cand) AND type='user'
          AND length(coalesce(json_extract(data,'\$.text'),'')) > 0
      )
      SELECT c.id, c.directory, c.time_created, c.time_updated, f.t, l.t
      FROM cand c
      JOIN upts f ON f.sid=c.id AND f.rn_first=1
      JOIN upts l ON l.sid=c.id AND l.rn_last=1
      ORDER BY c.time_updated DESC;"
  else
    sql="
      WITH cand AS (
        SELECT id, directory, time_created, time_updated
        FROM session
        WHERE time_archived IS NULL AND time_updated >= $ms_cutoff
          AND title NOT LIKE 'Claude Code%'
          AND title NOT LIKE 'Base directory for this skill%'
          AND title NOT LIKE 'New session -%'
      ),
      upts AS (
        SELECT m.session_id AS sid,
               replace(replace(json_extract(p.data,'\$.text'), char(10), ' '), char(13), ' ') AS t,
               row_number() OVER (PARTITION BY m.session_id ORDER BY m.time_created, p.time_created) AS rn_first,
               row_number() OVER (PARTITION BY m.session_id ORDER BY m.time_created DESC, p.time_created DESC) AS rn_last
        FROM message m
        JOIN part p ON p.message_id=m.id
        JOIN cand c ON c.id=m.session_id
        WHERE json_extract(m.data,'\$.role')='user'
          AND json_extract(p.data,'\$.type')='text'
          AND length(coalesce(json_extract(p.data,'\$.text'),'')) > 0
      )
      SELECT c.id, c.directory, c.time_created, c.time_updated, f.t, l.t
      FROM cand c
      JOIN upts f ON f.sid=c.id AND f.rn_first=1
      JOIN upts l ON l.sid=c.id AND l.rn_last=1
      ORDER BY c.time_updated DESC;"
  fi

  local transcript="sqlite:$db"
  local FS=$'\x1f'
  local sid cwd t_created t_updated first last started seen out existed
  while IFS="$FS" read -r sid cwd t_created t_updated first last; do
    [ -n "$sid" ] || continue
    first="$(trim_prompt "$first")"
    [ -n "$first" ] || continue
    should_skip_prompt "$first" && continue
    last="$(trim_prompt "${last:-$first}")"
    started="$(iso_from_ms "$t_created")"
    seen="$(iso_from_ms "$t_updated")"
    out="$dir/$sid.json"
    existed=0; [ -e "$out" ] && existed=1
    write_rec "$sid" "$agent" "$cwd" "$transcript" "$first" "$last" "$started" "$seen"
    if [ "$existed" = 1 ]; then updated=$((updated+1)); else added=$((added+1)); fi
  done < <(sqlite3 -separator "$FS" "$db" "$sql" 2>/dev/null)
}

backfill_sqlite_agent opencode "$OPENCODE_DB"
backfill_sqlite_agent mimo     "$MIMO_DB"

echo "records restored: $added (sqlite refreshed: $updated)"
exit 0
