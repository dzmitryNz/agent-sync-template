#!/usr/bin/env bash
# UserPromptSubmit hook: prints a hint when the subscription limit is almost used up
# and on-demand is enabled, so the next request would be paid with credits.
# It prints a hint, does not stop the turn.
# This is not "save your progress in time" (limit-guard.sh does that).
#
# Source of truth is the cache of Claude Code itself in ~/.claude.json
# (cachedUsageUtilization): it holds both the limit percentages and the on-demand flag.
# The hook makes no network requests of its own: it runs on every prompt.
#
# Manual check:
#   printf '{"hook_event_name":"UserPromptSubmit","session_id":"t"}' \
#     | ~/.agent-sync/bin/ondemand-guard.sh
set -u
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

STATE_DIR="${LIMIT_STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/claude-herdr-meta}"
HERDR_LIMITS="$STATE_DIR/usage-limits"
CLAUDE_JSON="${CLAUDE_CONFIG_FILE:-$HOME/.claude.json}"
SESSION_THRESHOLD="${ONDEMAND_SESSION_PCT:-95}"
WEEK_THRESHOLD="${ONDEMAND_WEEK_PCT:-98}"
QUIET_MIN="${ONDEMAND_QUIET_MINUTES:-20}"

# Read all input at once: exiting early gives the caller SIGPIPE (141).
payload="$(cat 2>/dev/null)"

[ -f "$CLAUDE_JSON" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# One jq pass: the hook runs on every prompt, an extra process is noticeable here.
read -r on_demand fetched_s session_pct week_pct <<EOF
$(jq -r '(.cachedUsageUtilization // {}) as $c | ($c.utilization // {}) as $u |
  [ (if ($u.extra_usage.is_enabled // false) == true then "1" else "0" end),
    (($c.fetchedAtMs // 0) / 1000 | floor),
    (($u.five_hour.utilization // 0) | floor),
    (($u.seven_day.utilization // 0) | floor) ] | @tsv' "$CLAUDE_JSON" 2>/dev/null)
EOF

[ "${on_demand:-0}" = "1" ] || exit 0

is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_num "$session_pct" || session_pct=0
is_num "$week_pct"    || week_pct=0
is_num "$fetched_s"   || fetched_s=0

# The herdr cache is updated more often than Claude Code refreshes /usage, but it lives
# longer than needed: a stale file once showed 99% when the window had already reset.
# So we use it ONLY if it is newer than the data in .claude.json.
if [ -f "$HERDR_LIMITS" ]; then
  herdr_ts="$(stat -c %Y "$HERDR_LIMITS" 2>/dev/null || echo 0)"
  if is_num "$herdr_ts" && [ "$herdr_ts" -gt "$fetched_s" ]; then
    while IFS='=' read -r key value; do
      case "$key" in
        SHARED_SESSION_PCT) is_num "$value" && session_pct="$value" ;;
        SHARED_WEEK_PCT)    is_num "$value" && week_pct="$value" ;;
      esac
    done < "$HERDR_LIMITS"
  fi
fi

reason=''
[ "$session_pct" -ge "$SESSION_THRESHOLD" ] && reason="the 5-hour limit is ${session_pct}% used"
if [ "$week_pct" -ge "$WEEK_THRESHOLD" ]; then
  reason="${reason:+$reason, }the weekly limit is ${week_pct}% used"
fi
[ -n "$reason" ] || exit 0

# One warning per session per QUIET_MIN minutes: repeating it on every prompt
# would eat the very limit we are protecting.
sid="$(jq -r '.session_id // "unknown"' <<<"$payload" 2>/dev/null)"
[ -n "$sid" ] || sid=unknown
marker="$STATE_DIR/ondemand-warned-${sid//[^A-Za-z0-9]/_}"
if [ -f "$marker" ]; then
  age_min=$(( ( $(date +%s) - $(stat -c %Y "$marker" 2>/dev/null || echo 0) ) / 60 ))
  [ "$age_min" -lt "$QUIET_MIN" ] && exit 0
fi
mkdir -p "$STATE_DIR" 2>/dev/null
touch "$marker" 2>/dev/null

cat <<EOF
[agent-sync] STOP: $reason, and on-demand is enabled: further usage is paid
with credits, not covered by the subscription.

Do not continue the work silently:
1. Commit and push unfinished work as a WIP commit.
2. Update the plan file in $HOME/.claude/plans: [x] done items, [ ] remaining items,
   and at the end where you stopped and what the next step is.
3. Stop the work and tell the user how much was used and what is left
   to do. Continue only if the user explicitly asks.
EOF
exit 0
