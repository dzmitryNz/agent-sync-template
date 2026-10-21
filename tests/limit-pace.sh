#!/usr/bin/env bash
# Tests for limit-pace.sh: from the pace of use it says whether the limit lasts until the reset
# (blue/gray/yellow/red), and it parses the reset date from the /usage text.
set -uo pipefail

PACE="$(cd "$(dirname "$0")/.." && pwd)/bin/limit-pace.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "failed: $*"; fi; }
run_test() { printf '%s\n' "$1"; "$2"; }

NOW=1700000000
H5=18000
D7=604800

# level <used> <passed, s> <window, s> -> level; the reset is counted from NOW
level() { "$PACE" "$1" $((NOW + $3 - $2)) "$3" "$NOW"; }

t_blue() {
  check "week: 40% used, 117 h passed → blue" test "$(level 40 421200 $D7)" = blue
  check "pace 58 → blue"             test "$(level 29 302400 $D7)" = blue
}

t_gray() {
  check "pace exactly 60 → gray" test "$(level 30 9000 $H5)" = gray
  check "pace exactly 100 → gray" test "$(level 50 9000 $H5)" = gray
}

t_yellow() {
  check "pace 120 → yellow"  test "$(level 60 9000 $H5)" = yellow
  check "pace exactly 130 → yellow" test "$(level 65 9000 $H5)" = yellow
}

t_red() {
  check "pace 131 → red"           test "$(level 73 10000 $H5)" = red
  check "100% with time left → red" test "$(level 100 9000 $H5)" = red
  check "100% at the start of the window → red" test "$(level 100 1200 $H5)" = red
}

t_early_window() {
  check "20 minutes of 5 h, pace 75 → gray" test "$(level 5 1200 $H5)" = gray
  check "20 minutes of 5 h, pace 750 → gray" test "$(level 50 1200 $H5)" = gray
  check "exactly 10% of the window already counts" test "$(level 80 1800 $H5)" = red
}

t_stale() {
  check "reset has passed → empty"   test -z "$("$PACE" 40 $((NOW - 10)) $D7 "$NOW")"
  check "reset exactly now → empty" test -z "$("$PACE" 40 "$NOW" $D7 "$NOW")"
  check "remaining time beyond the window → empty" test -z "$("$PACE" 40 $((NOW + D7 + 1)) $D7 "$NOW")"
}

t_bad_input() {
  local out rc
  out="$("$PACE" abc $((NOW + 100)) $H5 "$NOW")"; rc=$?
  check "used=abc → empty, exit 0" test -z "$out" -a "$rc" -eq 0
  out="$("$PACE" '' $((NOW + 100)) $H5 "$NOW")"; rc=$?
  check "empty used → empty, exit 0" test -z "$out" -a "$rc" -eq 0
  out="$("$PACE" 40 xyz $H5 "$NOW")"; rc=$?
  check "reset=xyz → empty, exit 0" test -z "$out" -a "$rc" -eq 0
  out="$("$PACE" 40 $((NOW + 100)) 0 "$NOW")"; rc=$?
  check "window 0 → empty, exit 0" test -z "$out" -a "$rc" -eq 0
  out="$("$PACE")"; rc=$?
  check "no arguments → empty, exit 0" test -z "$out" -a "$rc" -eq 0
}

# LIMIT_PACE_TZ names the zone in sample /usage text. Empty: this machine's zone.
# LIMIT_PACE_GAP_HOURS is the signed hour offset used when the text has no zone.
pace_tz() {
  if [ -n "${LIMIT_PACE_TZ:-}" ]; then printf '%s' "$LIMIT_PACE_TZ"; return; fi
  local link
  link=$(readlink -f /etc/localtime 2>/dev/null || true)
  printf '%s' "${link#*/zoneinfo/}"  # macOS: /var/db/timezone/zoneinfo/...
}
PACE_TZ=$(pace_tz)
off_for() { TZ="$PACE_TZ" date -d "$1" +%:z; }
epoch() { date -d "$1" +%s; }
parse() { "$PACE" --parse-reset "$@"; }

t_parse_reset() {
  local now tz="$PACE_TZ" z hours
  now=$(epoch "2026-10-14 11:20 $(off_for '2026-10-14 11:20')")
  check "Oct 16, 2pm"      test "$(parse "Oct 16, 2pm ($tz)" "$now")" = "$(epoch "2026-10-16 14:00 $(off_for '2026-10-16 14:00')")"
  check "Oct 14, 2:40pm"   test "$(parse "Oct 14, 2:40pm ($tz)" "$now")" = "$(epoch "2026-10-14 14:40 $(off_for '2026-10-14 14:40')")"
  check "12:29am"          test "$(parse "Oct 15, 12:29am ($tz)" "$now")" = "$(epoch "2026-10-15 00:29 $(off_for '2026-10-15 00:29')")"
  check "zone in the text wins" \
    test "$(LIMIT_PACE_TZ=Etc/GMT parse "Oct 16, 2pm ($tz)" "$now")" = "$(epoch "2026-10-16 14:00 $(off_for '2026-10-16 14:00')")"
  check "no zone uses LIMIT_PACE_TZ" \
    test "$(TZ=Etc/GMT LIMIT_PACE_TZ="$tz" parse 'Oct 16, 2pm' "$now")" = "$(epoch "2026-10-16 14:00 $(off_for '2026-10-16 14:00')")"
  z=$(TZ="$tz" date -d '2026-10-16 14:00' +%z)
  if [ "${z:3:2}" = 00 ]; then
    hours=$((10#${z:1:2}))
    [ "${z:0:1}" = - ] && hours=$((-hours))
    check "no zone uses LIMIT_PACE_GAP_HOURS" \
      test "$(TZ=Etc/GMT env -u LIMIT_PACE_TZ LIMIT_PACE_GAP_HOURS="$hours" "$PACE" --parse-reset 'Oct 16, 2pm' "$now")" = "$(epoch "2026-10-16 14:00 $(off_for '2026-10-16 14:00')")"
  fi
}

t_parse_year_rollover() {
  local now tz="$PACE_TZ"
  now=$(epoch "2026-12-30 10:00 $(off_for '2026-12-30 10:00')")
  check "Jan 2 after Dec 30 → next year" \
    test "$(parse "Jan 2, 9am ($tz)" "$now")" = "$(epoch "2027-01-02 09:00 $(off_for '2027-01-02 09:00')")"
  check "Dec 31 in the same year" \
    test "$(parse "Dec 31, 9am ($tz)" "$now")" = "$(epoch "2026-12-31 09:00 $(off_for '2026-12-31 09:00')")"
  now=$(epoch "2026-10-14 15:00 $(off_for '2026-10-14 15:00')")
  check "reset one hour before now → same year" \
    test "$(parse "Oct 14, 2:00pm ($tz)" "$now")" = "$(epoch "2026-10-14 14:00 $(off_for '2026-10-14 14:00')")"
}

t_parse_garbage() {
  local now out rc tz="$PACE_TZ"
  now=$(epoch "2026-10-14 11:20 $(off_for '2026-10-14 11:20')")
  out="$(parse "soon ($tz)" "$now")"; rc=$?
  check "garbage → empty, exit 0" test -z "$out" -a "$rc" -eq 0
  out="$(parse '' "$now")"; rc=$?
  check "empty text → empty" test -z "$out" -a "$rc" -eq 0
  out="$(parse "Foo 99, 2pm ($tz)" "$now")"; rc=$?
  check "a date that does not exist → empty" test -z "$out" -a "$rc" -eq 0
  out="$(parse 'Oct 16, 2pm (No/Such_Zone)' "$now")"; rc=$?
  check "unknown time zone → empty" test -z "$out" -a "$rc" -eq 0
}

run_test "blue: plenty of margin"           t_blue
run_test "gray: pace is normal"             t_gray
run_test "yellow: runs out before the reset" t_yellow
run_test "red: runs out much earlier"       t_red
run_test "start of the window: no forecast" t_early_window
run_test "stale data → empty"               t_stale
run_test "bad input → empty, exit 0"        t_bad_input
run_test "reset date from /usage"           t_parse_reset
run_test "date without a year: year rollover" t_parse_year_rollover
run_test "garbage instead of a date"        t_parse_garbage

printf '\ntotal: %d ok, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
