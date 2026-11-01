#!/usr/bin/env bash
# Find and resume agent sessions — your own and ones that came from other machines.
#
#   agent-sessions.sh list [query] [flags]    sessions, newest first
#   agent-sessions.sh resume <id|number>      continue a session (full transcript)
#   agent-sessions.sh resume <id> --print     only show the command
#   agent-sessions.sh brief <id>              digest of any readable transcript
#   agent-sessions.sh pickup <id|number> [--agent|--kind claude|cursor|opencode|mimo] [--print]
#                                            new session with a digest instead of resume;
#                                            source is jsonl/sqlite by shape, not by label;
#                                            --agent — where to open the new session;
#                                            --print — only the prompt, no exec
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

SESSIONS_DIR="${SESSIONS_DIR:-$HOME/.agent-sync/sessions}"
BIN_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
NORMALIZE="$BIN_DIR/session-transcript-normalize.sh"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

# All sessions in one stream, newest first: one entry per session, not per machine.
# A session picked up on a second machine is in the registry twice — each machine keeps
# its own record. We merge them here, not in cmd_list, so that `resume <number>` counts
# lines the same way the list showed them.
# The second sort key is needed for sessions with the same last_seen: without it find
# sets the order, and the line numbers change between runs.
records() {
  find "$SESSIONS_DIR" -type f -name '*.json' 2>/dev/null -print0 \
    | xargs -0 -r jq -s -c '
        def order: sort_by([(.last_seen // ""), (.host // ""), (.session_id // "")]) | reverse;
        group_by(.session_id // "")
        | map(order as $g
              | $g[0] + {hosts: (reduce ($g[] | .host // "?") as $h ([];
                                   if index([$h]) then . else . + [$h] end))})
        | order | .[]' 2>/dev/null
}

usage_list() {
  cat <<'EOF'
agent-sessions list [query] [flags]

  query             substring, case-insensitive: searched in prompts, plan name,
                    working directory and machine name
  -n, --limit N     how many lines to show (default 20)
      --page N      page, counted from one
      --since <d>   sessions not earlier than the date; --until <d> — not later;
                    --on <d> — exactly that day. The date can be in any form that
                    date -d understands: 2026-09-04, "last friday", "3 days ago"
      --host H      only from this machine
      --agent A     claude | cursor | opencode | mimo
      --all         no limit and no pages
EOF
}

# Day bounds in epoch: the tool is about days, so "--until 04.09" includes
# the whole Friday and does not stop at its midnight.
day_bound() { # <date string> <start|end>
  local day; day="$(date -d "$1" '+%F' 2>/dev/null)" || return 1
  [ -n "$day" ] || return 1
  if [ "$2" = end ]; then date -d "$day +1 day" '+%s' 2>/dev/null
  else                    date -d "$day"        '+%s' 2>/dev/null
  fi
}

bad_date() { echo "cannot parse the date: $1" >&2; exit 2; }
is_num()   { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# The transcript is under the slug of the working directory: /home/me/proj -> -home-me-proj
transcript_of() { # <cwd> <session_id>
  printf '%s/.claude/projects/%s/%s.jsonl' "$HOME" "${1//\//-}" "$2"
}

# The session directory in terms of THIS machine: another machine has its own home directory
local_cwd() { # <cwd> <home of the record>
  local cwd="$1" home="$2"
  if [ -n "$home" ] && [ "$home" != "$HOME" ] && [ "${cwd#"$home"}" != "$cwd" ]; then
    printf '%s%s' "$HOME" "${cwd#"$home"}"
  else
    printf '%s' "$cwd"
  fi
}

# Find a record by the number from list or by (sub)id — shared by resume and pickup,
# so numbers are counted the same way everywhere. The result goes to the global F_*.
locate_session() { # <number|id> -> 0/1, F_ID F_AGENT F_TARGET
  local want="$1" n=0 line found=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n+1))
    local id; id="$(jq -r '.session_id' <<<"$line")"
    if [ "$want" = "$n" ] || [ "$want" = "$id" ] || [ "${id#"$want"}" != "$id" ]; then
      found="$line"; break
    fi
  done < <(records)
  [ -n "$found" ] || return 1

  F_ID="$(jq -r '.session_id' <<<"$found")"
  F_AGENT="$(jq -r '.agent // "claude"' <<<"$found")"
  F_TRANSCRIPT="$(jq -r '.transcript // ""' <<<"$found")"
  local cwd home; cwd="$(jq -r '.cwd // ""' <<<"$found")"; home="$(jq -r '.home // ""' <<<"$found")"
  F_TARGET="$(local_cwd "$cwd" "$home")"
}

cmd_list() {
  local q='' limit=20 page=1 host='' agent='' since=0 until=0

  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--limit) is_num "${2:-}" || { echo "--limit needs a number" >&2; exit 2; }
                  limit="$2"; shift 2 ;;
      --page)     is_num "${2:-}" && [ "$2" -gt 0 ] || { echo "--page needs a number greater than zero" >&2; exit 2; }
                  page="$2"; shift 2 ;;
      --since)    since="$(day_bound "${2:-}" start)" || bad_date "${2:-}"; shift 2 ;;
      --until)    until="$(day_bound "${2:-}" end)"   || bad_date "${2:-}"; shift 2 ;;
      --on)       since="$(day_bound "${2:-}" start)" || bad_date "${2:-}"
                  until="$(day_bound "$2" end)";      shift 2 ;;
      --host)     host="${2:-}"; shift 2 ;;
      --agent)    agent="${2:-}"; shift 2 ;;
      --all)      limit=0; shift ;;
      -h|--help)  usage_list; return 0 ;;
      -*)         echo "unknown flag: $1" >&2; usage_list >&2; exit 2 ;;
      *)          q="$1"; shift ;;
    esac
  done

  # One jq draws the whole list: with a registry of hundreds of records, a jq call per field
  # turned into thousands of processes and seconds of waiting.
  local out
  out="$(records | jq -s -r \
        --arg q "$q" --arg host "$host" --arg agent "$agent" \
        --arg home "$HOME" --arg today "$(date '+%Y-%m-%d')" \
        --argjson since "$since" --argjson until "$until" \
        --argjson limit "$limit" --argjson page "$page" '
    def esc: gsub("(?<c>[.^$*+?()\\[\\]{}|\\\\\\-/])"; "\\" + .c);
    def ts:  (.last_seen // "") | if . == "" then 0 else (try fromdateiso8601 catch 0) end;
    def when($t): if $t == 0 then "?"
                  elif ($t | strflocaltime("%Y-%m-%d")) == $today
                  then "today " + ($t | strflocaltime("%H:%M"))
                  else $t | strflocaltime("%d.%m %H:%M") end;
    # a record from another machine has its own home directory — convert it to the local one
    def dir: (.cwd // "") as $c | (.home // "") as $h
             | (if $h != "" and $h != $home and ($c | startswith($h))
                then $home + $c[($h | length):] else $c end)
             | split("/") | (last // "-");
    def plan: (.plan // "") | if . == "" then "—" else split("/") | last | sub("\\.md$"; "") end;

    # records() already returned the records in the right order — do not sort a second time:
    # a second reverse undoes the tie-break of the first sort
    to_entries | map(.value + {n: (.key + 1)})
    | map(select($q == "" or
        ([.first_prompt, .last_prompt, .plan, .cwd] + (.hosts // [.host])
         | map(. // "") | join(" ") | test($q | esc; "i"))))
    | map(select($host  == "" or ((.hosts // [.host]) | index([$host]) != null)))
    | map(select($agent == "" or (.agent // "claude")  == $agent))
    | map(select(($since == 0 and $until == 0)
                 or (ts as $t | $t != 0
                     and ($since == 0 or $t >= $since)
                     and ($until == 0 or $t <  $until))))
    | . as $rows | ($rows | length) as $total
    | (if $limit == 0 then $rows else $rows[(($page - 1) * $limit):($page * $limit)] end) as $shown
    | (if ($shown | length) > 0 then
        ["#", "when", "host", "agent", "herdr", "dir", "plan", "about"],
        ($shown[] | [
          (.n | tostring), when(ts),
          ((.hosts // [.host // "?"]) | join(",")), (.agent // "claude"),
          ((.herdr.workspace // "") | if . == "" then "-" else . end),
          dir, plan,
          "[" + ((.session_id // "")[0:8]) + "] "
              + ([.first_prompt, .last_prompt] | map(select(. != null and . != "")) | (first // "no description"))
        ])
       else empty end | @tsv),
      "@@META\t\($total)\t\($shown | length)"
  ')"

  local meta table total shown pages
  meta="$(printf '%s\n' "$out" | grep '^@@META' | head -1)"
  table="$(printf '%s\n' "$out" | grep -v '^@@META')"
  total="$(cut -f2 <<<"$meta")"; shown="$(cut -f3 <<<"$meta")"

  if [ "${total:-0}" = 0 ]; then
    if [ -n "$q$host$agent" ] || [ "$since" != 0 ] || [ "$until" != 0 ]; then
      echo "nothing found for the given filters"
    else
      echo "registry is empty — no sessions"
    fi
    return 0
  fi

  [ -n "$table" ] && printf '%s\n' "$table" | column -t -s $'\t'

  if [ "$limit" = 0 ]; then
    printf '\nshown %s of %s\n' "$shown" "$total"
  else
    pages=$(( (total + limit - 1) / limit ))
    printf '\nshown %s of %s, page %s of %s' "$shown" "$total" "$page" "$pages"
    [ "$page" -lt "$pages" ] && printf ' — next: --page %s' "$((page + 1))"
    printf '\n'
  fi
  printf 'continue:  agent-sessions resume <number|id>\n'
}

# Digest: normalizer → {user,edit,shell}, no if-agent branches.
# jsonl (Claude/Cursor/similar) and sqlite (OpenCode/Mimo); an unknown agent with a
# similar shape still yields a digest.
cmd_brief() {
  local want="${1:?session id is required}" line found=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local id; id="$(jq -r '.session_id' <<<"$line")"
    if [ "$want" = "$id" ] || [ "${id#"$want"}" != "$id" ]; then found="$line"; break; fi
  done < <(records)

  local id="$want" cwd='' home='' transcript=''
  if [ -n "$found" ]; then
    id="$(jq -r '.session_id' <<<"$found")"
    cwd="$(jq -r '.cwd // ""' <<<"$found")"
    home="$(jq -r '.home // ""' <<<"$found")"
    transcript="$(jq -r '.transcript // ""' <<<"$found")"
  fi

  [ -x "$NORMALIZE" ] || { echo "missing $NORMALIZE" >&2; exit 1; }
  local -a norm_args=(--id "$id")
  [ -n "$transcript" ] && norm_args+=(--transcript "$transcript")
  [ -n "$cwd" ] && norm_args+=(--cwd "$cwd")
  local norm
  if ! norm="$("$NORMALIZE" "${norm_args[@]}" 2>/dev/null)"; then
    echo "transcript not found for session $want" >&2
    exit 1
  fi
  [ -n "$norm" ] || { echo "transcript not found for session $want" >&2; exit 1; }

  local meta_cwd
  meta_cwd="$(jq -rs 'map(select(.k=="meta") | .cwd // empty) | .[0] // empty' <<<"$norm")"
  [ -n "$cwd" ] || cwd="$meta_cwd"
  printf 'session [%s]  directory: %s\n' "${id:0:8}" "$(local_cwd "${cwd:-}" "${home:-}")"
  local plan; plan="$([ -n "$found" ] && jq -r '.plan // ""' <<<"$found")"
  [ -n "$plan" ] && printf 'plan: %s\n' "$plan"

  echo
  echo "what was asked:"
  jq -rs '
    map(select(.k=="user") | .t // empty)
    | map(select(. != null and . != ""))
    | (if length > 8 then (.[0:4] + ["…"] + .[-4:]) else . end)
    | map(gsub("\\s+"; " ") | if length > 100 then .[0:99] + "…" else . end)
    | .[]' <<<"$norm" 2>/dev/null \
    | sed 's/^/  · /'

  echo
  echo "files changed:"
  jq -rs '[.[] | select(.k=="edit") | .p // empty] | unique | .[]' <<<"$norm" 2>/dev/null \
    | tail -20 | sed 's/^/  · /'

  echo
  echo "commands run:"
  jq -rs '[.[] | select(.k=="shell") | .c // empty
           | gsub("\\s+"; " ") | if length > 80 then .[0:79] + "…" else . end] | unique | .[]' \
    <<<"$norm" 2>/dev/null | tail -12 | sed 's/^/  · /'
}

cmd_resume() {
  local want="${1:?a number or session id is required}" print=''
  [ "${2:-}" = --print ] && print=1

  locate_session "$want" || { echo "session not found: $want" >&2; exit 1; }
  local id="$F_ID" agent="$F_AGENT" target="$F_TARGET"

  [ -d "$target" ] || echo "warning: directory $target does not exist on this machine" >&2
  # history-sync warning only for Claude jsonl; sqlite/cursor stay local
  case "$agent" in
    cursor|opencode|mimo|codex) ;;
    *)
      if [ ! -f "$(transcript_of "$target" "$id")" ]; then
        echo "warning: no history for this session here — transcript sync has not run yet (bin/history-sync.sh)" >&2
      fi
      ;;
  esac

  local resume_cmd
  case "$agent" in
    cursor)   resume_cmd="cursor-agent --resume $id" ;;
    opencode) resume_cmd="opencode --session $id" ;;
    mimo)     resume_cmd="mimo --session $id" ;;
    *)        resume_cmd="claude --resume $id" ;;
  esac

  if [ -n "$print" ]; then
    printf "cd '%s' && %s\n" "$target" "$resume_cmd"
  else
    cd "$target" 2>/dev/null || { echo "cannot change to $target" >&2; exit 1; }
    case "$agent" in
      cursor)   exec cursor-agent --resume "$id" ;;
      opencode) exec opencode --session "$id" ;;
      mimo)     exec mimo --session "$id" ;;
      *)        exec claude --resume "$id" ;;
    esac
  fi
}

# Cursor Agent binary: PATH may have both `agent` and `cursor-agent` (often the same).
cursor_agent_bin() {
  if command -v agent >/dev/null 2>&1; then printf '%s' agent
  elif command -v cursor-agent >/dev/null 2>&1; then printf '%s' cursor-agent
  else printf '%s' cursor-agent
  fi
}

usage_pickup() {
  cat <<'EOF'
agent-sessions pickup <number|id> [--agent|--kind claude|cursor|opencode|mimo] [--print]

  new session with a brief digest instead of a full resume
  (source — any readable transcript: jsonl or sqlite; does not refuse by kind)
  --agent, --kind   where to open the new session (not "can we brief")
  --print           only print the prompt, no exec — to paste into a live pane
EOF
}

# A new session instead of resume: brief digest instead of the full transcript.
# --agent/--kind is only the launch target; brief reads the source by shape.
cmd_pickup() {
  local want='' into=claude print=''

  while [ $# -gt 0 ]; do
    case "$1" in
      --agent|--kind)
        into="${2:-}"
        case "$into" in
          claude|cursor|opencode|mimo) ;;
          *) echo "--agent/--kind needs claude|cursor|opencode|mimo" >&2; usage_pickup >&2; exit 2 ;;
        esac
        shift 2 ;;
      --print) print=1; shift ;;
      -h|--help) usage_pickup; return 0 ;;
      -*) echo "unknown flag: $1" >&2; usage_pickup >&2; exit 2 ;;
      *)  [ -z "$want" ] || { echo "extra argument: $1" >&2; usage_pickup >&2; exit 2; }
          want="$1"; shift ;;
    esac
  done
  [ -n "$want" ] || { echo "a number or session id is required" >&2; usage_pickup >&2; exit 2; }

  locate_session "$want" || { echo "session not found: $want" >&2; exit 1; }
  local id="$F_ID" agent="$F_AGENT" target="$F_TARGET" transcript="$F_TRANSCRIPT"

  [ -d "$target" ] || { echo "cannot pick up: directory $target does not exist on this machine" >&2; exit 1; }

  local brief; brief="$(cmd_brief "$id")" || exit 1
  local tr_hint="${transcript:-}"
  if [ -z "$tr_hint" ]; then
    case "$agent" in
      cursor)   tr_hint="~/.cursor/projects/*/agent-transcripts/${id}/${id}.jsonl" ;;
      opencode) tr_hint="sqlite:~/.local/share/opencode/opencode.db#$id" ;;
      mimo)     tr_hint="sqlite:~/.local/share/mimocode/mimocode.db#$id" ;;
      *)        tr_hint="~/.claude/projects/*/${id}.jsonl" ;;
    esac
  fi
  local prompt="Pick up session [${id:0:8}] without a full resume — here is a digest instead of the transcript history:

$brief

Briefly summarize what was done and what is next, and continue from there. Do not ask again about what the digest already shows; for details of specific reasoning, look into the transcript ${tr_hint} only if you really need it."

  if [ -n "$print" ]; then
    printf '%s\n' "$prompt"
    return 0
  fi

  cd "$target" 2>/dev/null || { echo "cannot change to $target" >&2; exit 1; }
  case "$into" in
    cursor)
      local bin; bin="$(cursor_agent_bin)"
      exec "$bin" "$prompt"
      ;;
    opencode)
      exec opencode --prompt "$prompt"
      ;;
    mimo)
      exec mimo run -- "$prompt"
      ;;
    *)
      exec claude "$prompt"
      ;;
  esac
}

case "${1:-list}" in
  list)   shift 2>/dev/null; cmd_list "$@" ;;
  resume) shift; cmd_resume "$@" ;;
  brief)  shift; cmd_brief  "$@" ;;
  pickup) shift; cmd_pickup "$@" ;;
  *) echo "commands: list [query] [flags] | resume <number|id> [--print] | brief <id> | pickup <number|id> [--agent|--kind …] [--print]" >&2
     echo >&2; usage_list >&2; exit 2 ;;
esac
