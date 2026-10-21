#!/usr/bin/env bash
# Tests for limit-guard.sh, the hook that warns the AGENT about a nearly used-up limit,
# so it can record progress in the plan instead of stopping half way.
set -uo pipefail

GUARD="$(cd "$(dirname "$0")/.." && pwd)/bin/limit-guard.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "not satisfied: $*"; fi; }

setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  export XDG_RUNTIME_DIR="$TMP/run"
  export LIMIT_STATE_DIR="$XDG_RUNTIME_DIR/claude-herdr-meta"
  mkdir -p "$LIMIT_STATE_DIR" "$HOME/.claude/plans"
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

limits() { # limits <session %> <week %>
  printf 'SHARED_SESSION_PCT=%s\nSHARED_WEEK_PCT=%s\n' "$1" "$2" \
    > "$LIMIT_STATE_DIR/usage-limits"
}

fire() { # fire [session_id] -> hook stdout
  jq -nc --arg s "${1:-sess-1}" \
    '{hook_event_name:"UserPromptSubmit", session_id:$s, cwd:"/home/me/proj"}' \
    | "$GUARD" 2>/dev/null
}

# --- 1. margin left: the hook is silent ---------------------------------------
t_quiet_below() {
  limits 24 10
  local out; out="$(fire)"
  check "nothing said" test -z "$out"
}

# --- 2. the 5-hour limit is almost used up ------------------------------------
t_session_limit() {
  limits 92 10
  local out; out="$(fire)"
  check "warning issued"   test -n "$out"
  check "reason named"            grep -qi 'limit' <<<"$out"
  check "plan is mentioned"       grep -qi 'plan' <<<"$out"
  check "plans directory shown"   grep -q '.claude/plans' <<<"$out"
  check "usage percentage shown" grep -q '92'      <<<"$out"
}

# --- 3. the weekly limit is almost used up while the session is free ----------
t_week_limit() {
  limits 10 95
  local out; out="$(fire)"
  check "warning issued" test -n "$out"
  check "week is mentioned"      grep -qi 'week' <<<"$out"
}

# --- 4. no limit data: the hook is silent and does not interfere --------------
t_no_data() {
  local out; out="$(fire)"
  check "silent without data" test -z "$out"
  local rc; fire >/dev/null 2>&1; rc=$?
  check "exit 0"           test "$rc" -eq 0
}

# --- 5. garbage instead of data does not break the hook -----------------------
t_broken_data() {
  printf 'who knows what\n' > "$LIMIT_STATE_DIR/usage-limits"
  local out; out="$(fire)"
  check "silent on garbage" test -z "$out"
}

# --- 6. the warning is not repeated on every prompt ---------------------------
# Otherwise it would clutter the context of the very session we try to save.
t_no_spam() {
  limits 92 10
  fire >/dev/null
  local out; out="$(fire)"
  check "silent the second time in a row" test -z "$out"
}

# --- 7. but it repeats when the quiet window has passed -----------------------
t_repeat_after_window() {
  limits 92 10
  fire >/dev/null
  touch -d '30 minutes ago' "$LIMIT_STATE_DIR"/warned-* 2>/dev/null
  local out; out="$(fire)"
  check "reminds again after half an hour" test -n "$out"
}

# --- 8. different sessions are warned independently ---------------------------
t_per_session() {
  limits 92 10
  fire sess-1 >/dev/null
  local out; out="$(fire sess-2)"
  check "second session is warned too" test -n "$out"
}

power() { # power <online> <charge>
  export POWER_SUPPLY_DIR="$TMP/power" AGENT_SYNC_OS=linux  # fake /sys: also on a macOS runner
  mkdir -p "$POWER_SUPPLY_DIR/AC" "$POWER_SUPPLY_DIR/BAT0"
  printf 'Mains\n'   > "$POWER_SUPPLY_DIR/AC/type"
  printf '%s\n' "$1" > "$POWER_SUPPLY_DIR/AC/online"
  printf 'Battery\n' > "$POWER_SUPPLY_DIR/BAT0/type"
  printf '%s\n' "$2" > "$POWER_SUPPLY_DIR/BAT0/capacity"
}

# --- 9. battery almost empty: the same signal as the limit --------------------
# A flat battery stops the work as suddenly as a used-up limit. The difference is
# that not only the plan needs saving: unpushed changes on a sleeping laptop
# are not available from the second machine.
t_battery_low() {
  limits 24 10; power 0 12
  local out; out="$(fire)"
  check "warning issued"  test -n "$out"
  check "battery named"          grep -qi 'battery' <<<"$out"
  check "percentage shown"          grep -q '12' <<<"$out"
  check "commit is mentioned"    grep -qi 'commit' <<<"$out"
}

# --- 10. low charge on mains power is not an alarm ----------------------------
t_battery_charging() {
  limits 24 10; power 1 12
  local out; out="$(fire)"
  check "silent on mains power" test -z "$out"
}

# --- 11. enough charge: stay silent -------------------------------------------
t_battery_enough() {
  limits 24 10; power 0 80
  local out; out="$(fire)"
  check "silent at 80%" test -z "$out"
}

# --- 12. no battery (desktop): do not interfere -------------------------------
t_battery_absent() {
  limits 24 10
  export POWER_SUPPLY_DIR="$TMP/no-such-dir" AGENT_SYNC_OS=linux  # fake /sys: also on a macOS runner
  local out; out="$(fire)"
  check "silent without a battery" test -z "$out"
}

run_test "battery low: warn"  t_battery_low
run_test "low charge on mains power is not an alarm" t_battery_charging
run_test "enough charge: silent"            t_battery_enough
run_test "desktop without a battery"                t_battery_absent
run_test "margin left: silent"                t_quiet_below
run_test "5-hour limit almost used up"        t_session_limit
run_test "weekly limit almost used up"          t_week_limit
run_test "no data: silent"                t_no_data
run_test "garbage in the data does not break"           t_broken_data
run_test "does not spam on every prompt"        t_no_spam
run_test "reminds after the quiet window"       t_repeat_after_window
run_test "sessions are warned independently"  t_per_session

printf '\ntotal: %d ok, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
