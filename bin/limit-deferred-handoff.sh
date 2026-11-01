#!/usr/bin/env bash
# Queue herdr-handoff for Claude panes at usage limit; drain after limit-schedule fires.
set -euo pipefail

SYNC_BIN="${AGENT_SYNC_BIN:-$HOME/.agent-sync/bin}"
HOOKS="${HANDOFF_HOOKS_DIR:-$HOME/.claude/hooks}"
HANDOFF="$HOOKS/herdr-handoff.sh"
SCHEDULE="$SYNC_BIN/limit-schedule.sh"
QUEUE_DIR="${DEFERRED_HANDOFF_DIR:-$HOME/.cache/agent-roles/deferred}"
SEND="$HOOKS/herdr-pane-send.sh"

usage() {
  cat <<'EOF'
limit-deferred-handoff.sh --enqueue --target PANE --skill SKILL [--reason limit|pending] [--clear 0|1] (--message TEXT | message on stdin)
limit-deferred-handoff.sh --drain --target PANE
limit-deferred-handoff.sh --should-defer
EOF
}

queue_path() {
  printf '%s/%s.jsonl' "$QUEUE_DIR" "${1//[^A-Za-z0-9]/_}"
}

parse_from() {
  printf '%s' "$1" | sed -n 's/^From:[[:space:]]*//p' | head -n1
}

notify_from_queued() {
  local from=$1 pane=$2 skill=$3 reason=$4 wake_epoch=$5 position=$6
  [[ -n "$from" && -x "$SEND" ]] || return 0
  local wake_human='unknown'
  if [[ -n "$wake_epoch" && "$wake_epoch" =~ ^[0-9]+$ ]]; then
    wake_human=$(date -d "@$wake_epoch" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || wake_human)
  fi
  local why
  case "$reason" in
    limit) why='Claude usage limit (handoff not sent yet)' ;;
    pending) why='target pane still owes [* RESULT] on a prior request' ;;
    *) why="$reason" ;;
  esac
  "$SEND" "$from" "[PM NOTICE] Handoff deferred — work NOT started on ${pane} (${skill}).
Reason: ${why}.
Queue position: ${position}. Scheduled delivery attempt after limit reset (~${wake_human}, reset+5min).
You will get another notice when the full [* REQUEST] is delivered; [* RESULT] comes later from the role agent." \
    >/dev/null 2>&1 || true
}

enqueue() {
  local pane=$1 skill=$2 clear_flag=$3 message=$4 reason=$5
  local from line q wake_epoch position
  from=$(parse_from "$message")
  mkdir -p "$QUEUE_DIR"
  q=$(queue_path "$pane")
  command -v jq >/dev/null 2>&1 || return 1
  line=$(jq -nc \
    --arg skill "$skill" \
    --arg message "$message" \
    --arg from "$from" \
    --arg reason "$reason" \
    --argjson clear "$clear_flag" \
    --arg queued_at "$(date --iso-8601=seconds)" \
    '{skill:$skill,message:$message,from:$from,reason:$reason,clear:$clear,queued_at:$queued_at}')
  printf '%s\n' "$line" >>"$q"
  position=$(wc -l <"$q" | tr -d ' ')
  wake_epoch=$(bash "$SCHEDULE" wake-epoch 2>/dev/null || true)
  notify_from_queued "$from" "$pane" "$skill" "$reason" "$wake_epoch" "$position"
  bash "$SCHEDULE" schedule-job "$pane" deferred-handoff \
    "$(readlink -f "$0")" --drain --target "$pane" || true
}

# Returns 0 if a queued handoff was delivered.
drain() {
  local pane=$1 q tmp first rest rc tag
  q=$(queue_path "$pane")
  [[ -f "$q" ]] || return 1
  [[ -s "$q" ]] || return 1
  first=$(head -n1 "$q")
  rest=$(tail -n +2 "$q" 2>/dev/null || true)
  tmp="${q}.tmp"
  printf '%s' "$rest" >"$tmp"
  mv "$tmp" "$q"

  local skill message from clear_flag
  skill=$(jq -r '.skill' <<<"$first")
  message=$(jq -r '.message' <<<"$first")
  from=$(jq -r '.from' <<<"$first")
  clear_flag=$(jq -r '.clear' <<<"$first")

  tag=$(printf '%s' "$message" | sed -n '1p' | grep -oE '\[(REVIEW|DEV|DEVOPS|QA|LOGS|DB|DOCS|CLEANER) REQUEST\]' | head -n1 |
    sed 's/^\[//;s/ REQUEST\]$//')

  export HANDOFF_NO_DEFER=1
  if [[ "$clear_flag" == "true" || "$clear_flag" == "1" ]]; then
    rc=0
    "$HANDOFF" "$pane" "$skill" "$message" || rc=$?
  else
    rc=0
    "$HANDOFF" --no-clear "$pane" "$skill" "$message" || rc=$?
  fi

  if [[ "$rc" -eq 0 && -n "$from" ]]; then
    "$SEND" "$from" "[PM NOTICE] Deferred handoff now delivered to ${pane} (${tag:-request}). Agent should run the task; expect [* RESULT] here when done." \
      >/dev/null 2>&1 || true
  fi

  if [[ -s "$q" ]]; then
    bash "$SCHEDULE" schedule-job "$pane" deferred-handoff \
      "$(readlink -f "$0")" --drain --target "$pane" || true
  else
    bash "$SCHEDULE" cancel-pane "$pane" 2>/dev/null || true
    bash "$SCHEDULE" sanitize-limits 2>/dev/null || true
  fi

  [[ "$rc" -eq 0 ]]
}

should_defer_for_limits() {
  local f session week thresh now week_ts
  [[ "${HANDOFF_NO_DEFER:-0}" == 1 ]] && return 1
  bash "$SCHEDULE" sanitize-limits 2>/dev/null || true
  f="${LIMIT_STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/claude-herdr-meta}/usage-limits"
  [[ -r "$f" ]] || return 1
  thresh=${HANDOFF_DEFER_LIMIT_PCT:-98}
  now=$(date +%s)
  # shellcheck disable=SC1090
  . "$f"
  session=${SHARED_SESSION_PCT:-0}
  week=${SHARED_WEEK_PCT:-0}
  [[ "$session" =~ ^[0-9]+$ ]] || session=0
  [[ "$week" =~ ^[0-9]+$ ]] || week=0
  week_ts=${SHARED_WEEK_RESET_TS:-0}
  if [[ "$week_ts" =~ ^[0-9]+$ ]] && ((week_ts > 0 && now > week_ts)); then
    week=0
  fi
  ((session >= thresh || week >= thresh))
}

mode=''
target=''
skill=''
clear_flag=1
message=''
reason='limit'

while (($#)); do
  case "$1" in
    --enqueue) mode=enqueue; shift ;;
    --drain) mode=drain; shift ;;
    --should-defer) mode=should-defer; shift ;;
    --target) target=${2:?}; shift 2 ;;
    --skill) skill=${2:?}; shift 2 ;;
    --reason) reason=${2:?}; shift 2 ;;
    --clear) clear_flag=${2:?}; shift 2 ;;
    --message) message=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "limit-deferred-handoff: unknown arg $1" >&2; exit 2 ;;
  esac
done

case "$mode" in
  enqueue)
    [[ -n "$target" && -n "$skill" ]] || { usage; exit 2; }
    [[ -n "$message" ]] || message=$(cat)
    [[ -n "$message" ]] || exit 1
    enqueue "$target" "$skill" "$clear_flag" "$message" "$reason"
    wake=$(bash "$SCHEDULE" wake-epoch 2>/dev/null || true)
    printf 'handoff-deferred\t%s\t%s\twake_epoch=%s\n' "$target" "$skill" "${wake:-unknown}"
    ;;
  should-defer)
    should_defer_for_limits && exit 0
    exit 1
    ;;
  drain)
    # exit 0 only when a queued handoff was delivered (limit-wake --run relies on this)
    [[ -n "$target" ]] || exit 1
    drain "$target"
    ;;
  *)
    usage
    exit 2
    ;;
esac
