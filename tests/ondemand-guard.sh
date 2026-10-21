#!/usr/bin/env bash
# Tests for ondemand-guard.sh, the hook that prints a hint and does not stop the turn when the subscription limit
# is used up and further usage would go to paid on-demand credits.
set -uo pipefail

GUARD="$(cd "$(dirname "$0")/.." && pwd)/bin/ondemand-guard.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "not satisfied: $*"; fi; }

setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  export XDG_RUNTIME_DIR="$TMP/run"
  export LIMIT_STATE_DIR="$XDG_RUNTIME_DIR/claude-herdr-meta"
  mkdir -p "$LIMIT_STATE_DIR" "$HOME/.claude"
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

# .claude.json is written by Claude Code itself; the hook reads it as the source of truth
claude_json() { # claude_json <on-demand: true|false> <5h %> <week %> [age in seconds]
  local age="${4:-60}"
  jq -nc --argjson od "$1" --argjson h5 "$2" --argjson w "$3" \
        --argjson ts "$(( ($(date +%s) - age) * 1000 ))" \
    '{cachedUsageUtilization:{fetchedAtMs:$ts, utilization:{
        five_hour:{utilization:$h5}, seven_day:{utilization:$w},
        extra_usage:{is_enabled:$od, utilization:3.5, monthly_limit:20000}}}}' \
    > "$HOME/.claude.json"
}

# herdr pane cache: lives nearby and is sometimes fresher than .claude.json
herdr_cache() { # herdr_cache <5h %> <week %> [minutes ago]
  printf 'SHARED_SESSION_PCT=%s\nSHARED_WEEK_PCT=%s\n' "$1" "$2" \
    > "$LIMIT_STATE_DIR/usage-limits"
  [ -n "${3:-}" ] && touch -d "$3 minutes ago" "$LIMIT_STATE_DIR/usage-limits"
}

fire() { # fire [session_id] -> hook stdout
  jq -nc --arg s "${1:-sess-1}" \
    '{hook_event_name:"UserPromptSubmit", session_id:$s, cwd:"/home/me/proj"}' \
    | "$GUARD" 2>/dev/null
}

# --- 1. on-demand is off: the limit just runs out, nothing to pay with --------
t_off_silent() {
  claude_json false 99 99
  local out; out="$(fire)"
  check "silent when on-demand is off" test -z "$out"
}

# --- 2. 5h >= 95% and on-demand is on: stop -----------------------------------
t_session_over() {
  claude_json true 96 20
  local out; out="$(fire)"
  check "warning issued"       test -n "$out"
  check "percentage shown"               grep -q '96' <<<"$out"
  check "paid usage is mentioned"  grep -qi 'on-demand\|credit' <<<"$out"
  check "stop is mentioned"        grep -qi 'stop\|not continue' <<<"$out"
}

# --- 3. exactly 95% is already the threshold -----------------------------------
t_session_exactly_threshold() {
  claude_json true 95 20
  local out; out="$(fire)"
  check "95% triggers" test -n "$out"
}

# --- 4. margin on both limits: stay silent ------------------------------------
t_below_thresholds() {
  claude_json true 94 97
  local out; out="$(fire)"
  check "94% and 97% are not a reason yet" test -z "$out"
}

# --- 5. weekly limit: it also goes to paid credits, higher threshold ----------
t_week_over() {
  claude_json true 10 98
  local out; out="$(fire)"
  check "warning issued" test -n "$out"
  check "week is mentioned"      grep -qi 'week' <<<"$out"
}

# --- 6. no data: the hook does not get in the way -----------------------------
t_no_data() {
  local out rc; out="$(fire)"; fire >/dev/null 2>&1; rc=$?
  check "silent without .claude.json" test -z "$out"
  check "exit 0"                 test "$rc" -eq 0
}

# --- 7. broken json does not break the hook -----------------------------------
t_broken_json() {
  printf 'who knows what\n' > "$HOME/.claude.json"
  local out rc; out="$(fire)"; fire >/dev/null 2>&1; rc=$?
  check "silent on garbage" test -z "$out"
  check "exit 0"          test "$rc" -eq 0
}

# --- 8. a fresh herdr cache beats a stale .claude.json ------------------------
# .claude.json is updated every few minutes; with parallel sessions
# the threshold can be passed in that time without notice.
t_fresh_herdr_cache_wins() {
  claude_json true 10 20 3600
  herdr_cache 97 20
  local out; out="$(fire)"
  check "fresh percentage taken from the herdr cache" test -n "$out"
  check "same value shown"                       grep -q '97' <<<"$out"
}

# --- 9. and a stale cache does not raise a false alarm ------------------------
# This exact case happened: the cache showed 99% when the window had long reset.
t_stale_herdr_cache_ignored() {
  claude_json true 8 14 60
  herdr_cache 99 13 60
  local out; out="$(fire)"
  check "silent on fresh data" test -z "$out"
}

# --- 10. does not spam on every prompt ----------------------------------------
t_no_spam() {
  claude_json true 96 20
  fire >/dev/null
  local out; out="$(fire)"
  check "silent the second time in a row" test -z "$out"
}

# --- 11. but repeats after the quiet window -----------------------------------
t_repeat_after_window() {
  claude_json true 96 20
  fire >/dev/null
  touch -d '30 minutes ago' "$LIMIT_STATE_DIR"/ondemand-warned-* 2>/dev/null
  local out; out="$(fire)"
  check "reminds again after half an hour" test -n "$out"
}

# --- 12. sessions are counted independently -----------------------------------
t_per_session() {
  claude_json true 96 20
  fire sess-1 >/dev/null
  local out; out="$(fire sess-2)"
  check "second session is warned too" test -n "$out"
}

run_test "on-demand off: silent"          t_off_silent
run_test "5h over the threshold: stop"                 t_session_over
run_test "exactly 95% is already the threshold"                t_session_exactly_threshold
run_test "margin left: silent"                  t_below_thresholds
run_test "weekly limit over the threshold"           t_week_over
run_test "no data: silent"                  t_no_data
run_test "broken json does not break"                 t_broken_json
run_test "fresh herdr cache wins"              t_fresh_herdr_cache_wins
run_test "stale cache is ignored"           t_stale_herdr_cache_ignored
run_test "does not spam on every prompt"          t_no_spam
run_test "reminds after the quiet window"         t_repeat_after_window
run_test "sessions are counted independently"          t_per_session

printf '\ntotal: %d ok, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
