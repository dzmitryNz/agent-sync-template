#!/usr/bin/env bash
# limit_wake_delay_seconds must not short-circuit on a stale weekly reset
# when the week limit was not what hit.
set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/limit-schedule.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "not satisfied: $*"; fi; }

setup() {
  TMP="$(mktemp -d)"
  export LIMIT_STATE_DIR="$TMP/limits"
  mkdir -p "$LIMIT_STATE_DIR"
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

t_stale_week_falls_through() {
  local past reset_epoch delay
  past=$(($(date +%s) - 3600))
  # Session reset ~2h ahead on the hour (same shape as claude /usage); week reset
  # already past with a low week % (session was the hit).
  reset_epoch="$(date -d "$(date -d '+2 hours' '+%Y-%m-%d %H:00')" +%s)"
  {
    printf 'SHARED_SESSION_PCT=95\n'
    printf 'SHARED_WEEK_PCT=40\n'
    printf 'SHARED_SESSION_RESET=%q\n' "$(date -d "@$reset_epoch" '+%b %-d, %-I%P') (UTC)"
    printf 'SHARED_WEEK_RESET_TS=%s\n' "$past"
  } > "$LIMIT_STATE_DIR/usage-limits"

  delay=$(bash "$BIN" wake-delay) || delay=
  check "wake-delay succeeded" test -n "$delay"
  check "delay is not the 30s week short-circuit" test "${delay:-0}" -gt 60
  check "delay looks like session reset + pad" test "${delay:-0}" -gt 3000
}

t_week_hit_uses_short_circuit() {
  local past delay
  past=$(($(date +%s) - 3600))
  {
    printf 'SHARED_SESSION_PCT=10\n'
    printf 'SHARED_WEEK_PCT=99\n'
    printf 'SHARED_WEEK_RESET_TS=%s\n' "$past"
  } > "$LIMIT_STATE_DIR/usage-limits"

  delay=$(bash "$BIN" wake-delay)
  check "week hit after reset → 30s" test "$delay" -eq 30
}

run_test "stale week reset with low week % uses session epoch" t_stale_week_falls_through
run_test "high week % after reset keeps 30s short-circuit" t_week_hit_uses_short_circuit

printf '\ntotal: %d ok, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
