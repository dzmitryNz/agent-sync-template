#!/usr/bin/env bash
# Keeps the herdr pane metadata up to date: agent name, title, status labels.
# Attached to SessionStart / UserPromptSubmit / PreToolUse / Notification / Stop / SessionEnd.
# The event is taken from hook_event_name in the JSON on stdin — one script for all hooks.
#
# IMPORTANT about the herdr API: report-metadata REPLACES the whole set of fields of the given --source,
# it does not merge. So every time we send the full set (display-agent + title +
# all state-labels), and whatever is missing in the current event is taken from the state file.
# And --seq must grow strictly: two calls in the same millisecond — the second is silently lost.
#
# Manual check:
#   printf '%s' '{"hook_event_name":"UserPromptSubmit","cwd":"'"$PWD"'","prompt":"hello"}' \
#     | ~/.claude/hooks/herdr-pane-meta.sh && herdr pane get "$HERDR_PANE_ID"

set -u
for _compat in "$(dirname "$(readlink -f "$0")")/../../../bin/lib/compat.sh" "${SYNC_HOME:-$HOME/.agent-sync}/bin/lib/compat.sh"; do [ -f "$_compat" ] && { . "$_compat" || exit 1; break; }; done

[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
command -v herdr >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

SOURCE="claude-hook"
# Metadata lives 12 hours: if a session dies in a non-clean way, the pane
# goes back to the default display instead of lying forever.
TTL_MS=43200000

STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/claude-herdr-meta"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
STATE_FILE="$STATE_DIR/${HERDR_PANE_ID//[^A-Za-z0-9]/_}"

# The subscription limit % is shared by all panes/agents at once, so the cache is one file
# for all in $STATE_DIR, not per-pane. flock -n: if another agent is already refreshing the cache,
# we do not wait and do not duplicate the call — we just take what is there (even if stale).
SHARED_USAGE_FILE="$STATE_DIR/usage-shared"
SHARED_USAGE_LOCK="$STATE_DIR/usage-shared.lock"
USAGE_REFRESHED=0
SHARED_USAGE_LAST=""

# limit-pace.sh lives in the agent-sync bin/ next to store/; the hook is read through a symlink.
LIMIT_PACE_BIN="${LIMIT_PACE_BIN:-$(dirname "$(readlink -f "$0")")/../../../bin/limit-pace.sh}"

# pace_emoji <used %> <reset epoch> <window sec> -> arrow or empty. Herdr font cannot draw emoji.
pace_emoji() {
  [ -x "$LIMIT_PACE_BIN" ] && [ -n "$2" ] || return 0
  case "$("$LIMIT_PACE_BIN" "$1" "$2" "$3" 2>/dev/null)" in
    blue) printf '↑' ;; yellow) printf '↓' ;; red) printf '↓↓' ;;
  esac
}

usage_pct_shared() {
  local now=$1
  SHARED_USAGE_LAST=""
  local cached_ts=0 cached_pct=""
  if [ -f "$SHARED_USAGE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$SHARED_USAGE_FILE" 2>/dev/null
    cached_ts="${SHARED_TS:-0}"
    cached_pct="${SHARED_PCT:-}"
  fi
  # The closer to the edge, the shorter the cache lives: with several parallel sessions
  # usage grows by tens of percent in a couple of minutes, and a five-minute cache
  # showed 73% when it was already 92%.
  local ttl=300
  case "$cached_pct" in
    *%*)
      local head_pct="${cached_pct%%\%*}"
      head_pct="${head_pct##*[!0-9]}"
      case "$head_pct" in
        ''|*[!0-9]*) ;;
        *) [ "$head_pct" -ge 85 ] && ttl=60 || { [ "$head_pct" -ge 70 ] && ttl=120; } ;;
      esac
      ;;
  esac
  if [ -n "$cached_pct" ] && [ $((now - cached_ts)) -lt "$ttl" ]; then
    SHARED_USAGE_LAST="$cached_pct"
    return
  fi

  if command -v flock >/dev/null 2>&1; then
    exec 9>"$SHARED_USAGE_LOCK"
    flock -n 9 || { SHARED_USAGE_LAST="$cached_pct"; return; }
  fi

  local pct=""
  if command -v claude >/dev/null 2>&1; then
    # -u HERDR_ENV/-u HERDR_PANE_ID: otherwise the child `claude -p` sees the same
    # environment variables and its own hooks (including SessionEnd) would
    # write metadata to THIS SAME pane over the current session.
    local usage_json
    usage_json=$(env -u HERDR_ENV -u HERDR_PANE_ID timeout 20 claude -p /usage --output-format json 2>/dev/null)
    local usage_text session_pct week_pct session_reset week_reset
    usage_text=$(jq -r '.result // ""' <<<"$usage_json" 2>/dev/null)
    session_pct=$(sed -n 's/^Current session: \([0-9]\{1,3\}\)% used.*/\1/p' <<<"$usage_text" | head -1)
    # The weekly limit comes in the same answer; it matters more than the five-hour one —
    # that one is released by evening, but the weekly one can run out on Wednesday.
    week_pct=$(sed -n 's/^Current week.*: \([0-9]\{1,3\}\)% used.*/\1/p' <<<"$usage_text" | head -1)
    # The limit reset date ("resets Sep 16, 9:30pm (Zone)") — we take it as
    # is, as text: the agent should not recompute the TZ or ask
    # the user "when does the limit reset".
    session_reset=$(sed -n 's/^Current session:.*resets \(.*\)$/\1/p' <<<"$usage_text" | head -1)
    week_reset=$(sed -n 's/^Current week.*resets \(.*\)$/\1/p' <<<"$usage_text" | head -1)
    local session_reset_ts='' week_reset_ts=''
    if [ -x "$LIMIT_PACE_BIN" ]; then
      session_reset_ts=$("$LIMIT_PACE_BIN" --parse-reset "$session_reset" "$now" 2>/dev/null)
      week_reset_ts=$("$LIMIT_PACE_BIN" --parse-reset "$week_reset" "$now" 2>/dev/null)
    fi
    if [ -n "$session_pct" ]; then
      pct="$(pace_emoji "$session_pct" "$session_reset_ts" 18000)${session_pct}%"
      [ -n "$week_pct" ] && pct="$pct · W $(pace_emoji "$week_pct" "$week_reset_ts" 604800)${week_pct}%"
    fi
    # Bare numbers for limit-guard.sh. The file is shared by all panes: one agent
    # updated it — the others see at once how much is left. FETCHED_AT is the moment
    # of this very request, so it is clear how fresh the reset dates are.
    { printf 'SHARED_SESSION_PCT=%s\n'   "${session_pct:-}"
      printf 'SHARED_WEEK_PCT=%s\n'      "${week_pct:-}"
      printf 'SHARED_SESSION_RESET=%q\n' "${session_reset:-}"
      printf 'SHARED_WEEK_RESET=%q\n'    "${week_reset:-}"
      printf 'SHARED_SESSION_RESET_TS=%s\n' "${session_reset_ts:-}"
      printf 'SHARED_WEEK_RESET_TS=%s\n'    "${week_reset_ts:-}"
      printf 'SHARED_FETCHED_AT=%s\n'    "$now"; } > "$STATE_DIR/usage-limits" 2>/dev/null
  fi

  if [ -n "$pct" ]; then
    { printf 'SHARED_TS=%s\n' "$now"; printf 'SHARED_PCT=%q\n' "$pct"; } > "$SHARED_USAGE_FILE"
    USAGE_REFRESHED=1
    SHARED_USAGE_LAST="$pct"
  else
    SHARED_USAGE_LAST="$cached_pct"
  fi
}

payload=$(cat)
event=$(jq -r '.hook_event_name // ""' <<<"$payload" 2>/dev/null) || exit 0
cwd=$(jq -r '.cwd // ""' <<<"$payload" 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"
project=$(basename "$cwd")

branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
where="$project"
[ -n "$branch" ] && [ "$branch" != "HEAD" ] && where="$project@$branch"

# Truncate by code points via jq, not bash: otherwise Cyrillic is cut in the middle of a character.
clip() {
  jq -rn --arg s "$1" --argjson n "${2:-60}" \
    '$s | gsub("\\s+";" ") | sub("^ +";"") | sub(" +$";"")
        | if (.|length) > $n then .[0:$n-1] + "…" else . end' 2>/dev/null
}

# Previous state
TITLE=""; WORKING=""; BLOCKED=""; LAST_SEQ=0; LAST_USAGE_TS=0; USAGE=""
# shellcheck disable=SC1090
[ -f "$STATE_FILE" ] && . "$STATE_FILE"

# The sidebar (Agents section) draws only display_agent + the label under it — it has no
# place for arbitrary metadata: --token is visible in `pane get`, but is
# not rendered anywhere visually (checked on 0.8.2). So usage is glued
# to display_agent, not sent as a separate --token.

if [ "$event" = "SessionEnd" ]; then
  herdr pane report-metadata "$HERDR_PANE_ID" --source "$SOURCE" \
    --clear-title --clear-display-agent --clear-state-labels >/dev/null 2>&1
  [ -n "${HERDR_TAB_ID:-}" ] && herdr tab rename "$HERDR_TAB_ID" "" >/dev/null 2>&1
  rm -f "$STATE_FILE"
  exit 0
fi

case "$event" in
  SessionStart)
    TITLE="$where"; WORKING="starting"; BLOCKED=""
    ;;
  UserPromptSubmit)
    prompt=$(jq -r '.prompt // ""' <<<"$payload" 2>/dev/null)
    [ -n "$prompt" ] || exit 0
    TITLE=$(clip "$prompt" 60)
    WORKING=$(clip "$prompt" 40)
    BLOCKED=""
    ;;
  PreToolUse)
    tool=$(jq -r '.tool_name // ""' <<<"$payload" 2>/dev/null)
    [ -n "$tool" ] || exit 0
    detail=$(jq -r '
      .tool_input as $i |
      ( if   ($i.command? // null)     then ($i.command | split("\n")[0])
        elif ($i.file_path? // null)   then ($i.file_path | split("/") | last)
        elif ($i.description? // null) then $i.description
        elif ($i.pattern? // null)     then $i.pattern
        elif ($i.url? // null)         then $i.url
        else "" end ) // ""' <<<"$payload" 2>/dev/null)
    if [ -n "$detail" ]; then
      WORKING=$(clip "$tool: $detail" 40)
    else
      WORKING=$(clip "$tool" 40)
    fi
    BLOCKED=""
    ;;
  Notification)
    BLOCKED=$(clip "$(jq -r '.message // "input needed"' <<<"$payload" 2>/dev/null)" 40)
    ;;
  Stop|SubagentStop)
    WORKING="thinking"
    BLOCKED=""

    now_s=$(date +%s)
    usage_pct_shared "$now_s"
    usage_pct="$SHARED_USAGE_LAST"

    if [ -n "$usage_pct" ]; then
      USAGE="$usage_pct"
    elif [ $((now_s - LAST_USAGE_TS)) -ge 300 ]; then
      # Fallback if /usage is unavailable at all (no `claude` in PATH, no
      # subscription etc. — not a transient failure): the sum of session tokens from the
      # transcript, throttled separately per-pane, because this is not shared data.
      transcript=$(jq -r '.transcript_path // ""' <<<"$payload" 2>/dev/null)
      if [ -n "$transcript" ] && [ -f "$transcript" ]; then
        usage_fmt=$(jq -rn '
          def fmt: if . >= 1000000 then (./1000000*10|round/10|tostring) + "M"
                    elif . >= 1000 then (./1000*10|round/10|tostring) + "k"
                    else tostring end;
          reduce (inputs | .message.usage? // empty) as $u
            (0; . + (($u.input_tokens // 0) + ($u.output_tokens // 0)
                     + ($u.cache_creation_input_tokens // 0)
                     + ($u.cache_read_input_tokens // 0)))
          | if . > 0 then (fmt + " tok") else "" end
        ' "$transcript" 2>/dev/null)
        if [ -n "$usage_fmt" ]; then
          USAGE="$usage_fmt"
          LAST_USAGE_TS=$now_s
        fi
      fi
    fi
    ;;
  *)
    exit 0
    ;;
esac

[ -n "$TITLE" ] || TITLE="$where"

# seq must grow strictly even with two events in the same millisecond.
seq_num=$(date +%s%3N)
[ "$seq_num" -gt "$LAST_SEQ" ] 2>/dev/null || seq_num=$((LAST_SEQ + 1))

# The Agents sidebar draws two lines: the tab label on top, display_agent below.
# Before, both got the same string, and the entry duplicated itself.
# Now the roles are split (user request 2026-09-05):
#   top    — where we work: worktree and branch;
#   bottom — who works: the agent and the remaining limit.
# Battery charge: on mains "AC N%", on battery "B N%" (low charge with "!").
# A "running out" mark for the sidebar. herdr cannot set a color: it prints ANSI
# as code letters. So the mark is text — "!" with SIDEBAR_WARN_PCT and "!!!"
# when the edge is very close. The threshold is softer than limit-guard: seeing it early
# is more useful than learning it when it is too late.
usage_marker() {
  local file="$STATE_DIR/usage-limits" s='' w=''
  [ -f "$file" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in SHARED_SESSION_PCT) s="$v" ;; SHARED_WEEK_PCT) w="$v" ;; esac
  done < "$file"
  local warn="${SIDEBAR_WARN_PCT:-80}" hard="${LIMIT_WARN_PCT:-90}"
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  case "$w" in ''|*[!0-9]*) w=0 ;; esac
  local top=$s; [ "$w" -gt "$top" ] && top=$w
  if   [ "$top" -ge "$hard" ]; then printf '!!! '
  elif [ "$top" -ge "$warn" ]; then printf '! '
  fi
}

# After a fresh /usage the percents are shared — push display_agent on the other
# Claude panes that have our state file (an active session with claude-hook).
refresh_other_claude_panes() {
  local new_usage="$1"
  [ -n "$new_usage" ] || return 0

  local agents_json
  agents_json=$(herdr agent list 2>/dev/null) || return 0

  local pane_id agent_cwd sf
  while IFS= read -r pane_id; do
    [ -n "$pane_id" ] || continue
    [ "$pane_id" = "$HERDR_PANE_ID" ] && continue

    sf="$STATE_DIR/${pane_id//[^A-Za-z0-9]/_}"
    [ -f "$sf" ] || continue

    agent_cwd=$(jq -r --arg p "$pane_id" \
      '.result.agents[] | select(.pane_id == $p) | .cwd // ""' <<<"$agents_json" 2>/dev/null)
    [ -n "$agent_cwd" ] || continue

    local o_title="" o_working="" o_blocked="" o_last_seq=0 o_last_usage_ts=0
    # shellcheck disable=SC1090
    . "$sf"
    o_title="${TITLE:-}"
    o_working="${WORKING:-}"
    o_blocked="${BLOCKED:-}"
    o_last_seq="${LAST_SEQ:-0}"
    o_last_usage_ts="${LAST_USAGE_TS:-0}"

    local o_project o_branch o_where o_ready o_who o_seq
    o_project=$(basename "$agent_cwd")
    o_branch=$(git -C "$agent_cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
    o_where="$o_project"
    [ -n "$o_branch" ] && [ "$o_branch" != "HEAD" ] && o_where="$o_project@$o_branch"
    [ -n "$o_title" ] || o_title="$o_where"

    o_who="$(usage_marker)claude · $new_usage"
    o_who="$o_who$(battery_suffix)"

    o_ready="ready · $o_project"
    [ -n "$o_branch" ] && [ "$o_branch" != "HEAD" ] && o_ready="$o_ready · $o_branch"

    o_seq=$(date +%s%3N)
    [ "$o_seq" -gt "$o_last_seq" ] 2>/dev/null || o_seq=$((o_last_seq + 1))

    o_args=(
      --source "$SOURCE" --seq "$o_seq" --ttl-ms "$TTL_MS"
      --display-agent "$(clip "$o_who" 40)"
      --title "$o_title"
      --state-label "idle=$o_ready"
      --state-label "done=$o_ready"
    )
    [ -n "$o_working" ] && o_args+=(--state-label "working=$o_working")
    [ -n "$o_blocked" ] && o_args+=(--state-label "blocked=$o_blocked")
    herdr pane report-metadata "$pane_id" "${o_args[@]}" >/dev/null 2>&1

    {
      printf 'TITLE=%q\n' "$o_title"
      printf 'WORKING=%q\n' "$o_working"
      printf 'BLOCKED=%q\n' "$o_blocked"
      printf 'LAST_SEQ=%s\n' "$o_seq"
      printf 'LAST_USAGE_TS=%s\n' "$o_last_usage_ts"
      printf 'USAGE=%q\n' "$new_usage"
    } > "$sf"
  done < <(jq -r '.result.agents[] | select(.agent == "claude") | .pane_id' <<<"$agents_json" 2>/dev/null)
}

battery_suffix() {
  local src cap
  read -r src cap <<<"$(agent_sync_power)"
  case "$cap" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$src" = ac ]; then
    printf ' · AC %s%%' "$cap"
  elif [ "$cap" -le "${BATTERY_WARN_PCT:-20}" ]; then
    printf ' · ! B %s%%' "$cap"
  else
    printf ' · B %s%%' "$cap"
  fi
}

who="$(usage_marker)claude"
[ -n "$USAGE" ] && who="$who · $USAGE"
who="$who$(battery_suffix)"

# The worktree name is shown by Spaces, here — only the branch (without it we fall back to the directory name)
tree_label="$project"
[ -n "$branch" ] && [ "$branch" != "HEAD" ] && tree_label="$branch"

ready="ready · $project"
[ -n "$branch" ] && [ "$branch" != "HEAD" ] && ready="$ready · $branch"

args=(
  --source "$SOURCE" --seq "$seq_num" --ttl-ms "$TTL_MS"
  --display-agent "$(clip "$who" 40)"
  --title "$TITLE"
  --state-label "idle=$ready"
  --state-label "done=$ready"
)
[ -n "$WORKING" ] && args+=(--state-label "working=$WORKING")
[ -n "$BLOCKED" ] && args+=(--state-label "blocked=$BLOCKED")

herdr pane report-metadata "$HERDR_PANE_ID" "${args[@]}" >/dev/null 2>&1

# The workspace name (Spaces section). herdr derives the default name from the path, so
# several tasks in one repository get the same label ("myproject" ×3) and
# cannot be told apart. We replace such a name with the worktree name — it is unique per task.
# A name set by hand ("Review", "sync") is left alone: we recognize it because
# it matches NO segment of the current path.
if [ -n "${HERDR_WORKSPACE_ID:-}" ] && [ -n "$project" ]; then
  ws_label=$(herdr workspace get "$HERDR_WORKSPACE_ID" 2>/dev/null \
    | jq -r '.result.workspace.label // ""' 2>/dev/null)

  if [ -n "$ws_label" ] && [ "$ws_label" != "$project" ]; then
    # a match with a path segment = the name was generated, not chosen by a human
    generated=""
    probe="$cwd"
    while [ "$probe" != / ] && [ -n "$probe" ]; do
      [ "$(basename "$probe")" = "$ws_label" ] && { generated=1; break; }
      probe=$(dirname "$probe")
    done
    [ -n "$generated" ] && herdr workspace rename "$HERDR_WORKSPACE_ID" "$project" >/dev/null 2>&1
  fi
fi

# What the user sees in the screenshot as the "pane title" ("1" + "+") is in fact
# the TAB label (herdr tab rename), not the pane frame display_agent —
# the frame in this layout (one pane per tab) has no visible place. So the same
# "who" is duplicated there too.
if [ -n "${HERDR_TAB_ID:-}" ]; then
  herdr tab rename "$HERDR_TAB_ID" "$(clip "$tree_label" 40)" >/dev/null 2>&1
fi

{
  printf 'TITLE=%q\n' "$TITLE"
  printf 'WORKING=%q\n' "$WORKING"
  printf 'BLOCKED=%q\n' "$BLOCKED"
  printf 'LAST_SEQ=%s\n' "$seq_num"
  printf 'LAST_USAGE_TS=%s\n' "$LAST_USAGE_TS"
  printf 'USAGE=%q\n' "$USAGE"
} > "$STATE_FILE"

if [ "${USAGE_REFRESHED:-0}" = 1 ] && [ -n "${USAGE:-}" ]; then
  refresh_other_claude_panes "$USAGE"
fi

exit 0
