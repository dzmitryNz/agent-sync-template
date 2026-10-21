#!/usr/bin/env bash
# UserPromptSubmit hook: warns the AGENT (not the human) that a limit is nearly used up,
# so it can record progress in the plan and the work can continue in
# another session, on this machine or on a second one.
#
# The percentages come from the cache that herdr-pane-meta.sh fills; the hook makes
# no requests of its own: it runs on every prompt and must be instant.
# Its output goes into the session context, so it is NOT async in settings.json.
set -u
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

STATE_DIR="${LIMIT_STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/claude-herdr-meta}"
LIMITS_FILE="$STATE_DIR/usage-limits"
THRESHOLD="${LIMIT_WARN_PCT:-90}"
BATTERY_THRESHOLD="${BATTERY_WARN_PCT:-20}"
QUIET_MIN="${LIMIT_QUIET_MINUTES:-20}"
PLANS_DIR="$HOME/.claude/plans"

# Read all input at once: if we exit early, the caller gets
# SIGPIPE on write to a closed pipe (code 141) instead of a quiet success.
payload="$(cat 2>/dev/null)"

# Check the charge only when the laptop is not on mains power
battery_low() {
  local src cap
  read -r src cap <<<"$(agent_sync_power)"
  [ "$src" = battery ] || return 1
  case "$cap" in ''|*[!0-9]*) return 1 ;; esac
  [ "$cap" -le "$BATTERY_THRESHOLD" ] || return 1
  printf '%s' "$cap"
}

battery_pct="$(battery_low)" || battery_pct=''

[ -f "$LIMITS_FILE" ] || [ -n "$battery_pct" ] || exit 0

session_pct=''; week_pct=''; session_reset=''; week_reset=''; fetched_at=''
[ -f "$LIMITS_FILE" ] && while IFS='=' read -r key value; do
  case "$key" in
    SHARED_SESSION_PCT)   session_pct="$value" ;;
    SHARED_WEEK_PCT)      week_pct="$value" ;;
    SHARED_SESSION_RESET) session_reset="$value" ;;
    SHARED_WEEK_RESET)    week_reset="$value" ;;
    SHARED_FETCHED_AT)    fetched_at="$value" ;;
  esac
done < "$LIMITS_FILE"

# Integers only: garbage in the cache must neither break the hook nor raise an alarm
is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

reason=''
if is_num "$session_pct" && [ "$session_pct" -ge "$THRESHOLD" ]; then
  reason="the 5-hour limit is ${session_pct}% used"
  [ -n "$session_reset" ] && reason="$reason (resets: $session_reset)"
fi
if is_num "$week_pct" && [ "$week_pct" -ge "$THRESHOLD" ]; then
  week_reason="the weekly limit is ${week_pct}% used"
  [ -n "$week_reset" ] && week_reason="$week_reason (resets: $week_reset)"
  if [ -n "$reason" ]; then
    reason="$reason, $week_reason"
  else
    reason="$week_reason"
  fi
fi
if [ -n "$battery_pct" ]; then
  bat="battery charge ${battery_pct}%, power not connected"
  reason="${reason:+$reason; }$bat"
fi
[ -n "$reason" ] || exit 0

# One warning per session per QUIET_MIN minutes: repeating it on every prompt
# would clutter the context of the very session we are trying to save.
sid="$(jq -r '.session_id // "unknown"' <<<"$payload" 2>/dev/null)"
[ -n "$sid" ] || sid=unknown
marker="$STATE_DIR/warned-${sid//[^A-Za-z0-9]/_}"
if [ -f "$marker" ]; then
  age_min=$(( ( $(date +%s) - $(stat -c %Y "$marker" 2>/dev/null || echo 0) ) / 60 ))
  [ "$age_min" -lt "$QUIET_MIN" ] && exit 0
fi
mkdir -p "$STATE_DIR" 2>/dev/null
touch "$marker" 2>/dev/null

fetched_note=''
if is_num "$fetched_at"; then
  fetched_note=" (data as of $(date -d "@$fetched_at" '+%H:%M %d.%m' 2>/dev/null || echo "?"))"
fi

cat <<EOF
[agent-sync] Warning: ${reason}${fetched_note}.

The reset dates are already known: do not ask again and do not run /usage again.

The work may stop at any moment. Before you continue:
1. Commit unfinished work as a plain WIP commit, without waiting until it is ready,
   and push it: changes on a sleeping laptop are not available on another machine.
2. Update the plan file in $PLANS_DIR (create it if it does not exist yet): mark
   finished items with [x] and leave remaining items as [ ].
3. At the end of the plan, write where you stopped and what the next step is,
   so that another agent or another machine can pick the task up.
4. Only then continue the work.
EOF
exit 0
