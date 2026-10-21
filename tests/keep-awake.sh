#!/usr/bin/env bash
# Tests for keep-awake.sh: keep the laptop awake while the agent works.
set -uo pipefail

AWAKE="$(cd "$(dirname "$0")/.." && pwd)/bin/keep-awake.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "not satisfied: $*"; fi; }

setup() {
  TMP="$(mktemp -d)"
  export AWAKE_STATE_DIR="$TMP/state"
  export POWER_SUPPLY_DIR="$TMP/power" AGENT_SYNC_OS=linux  # fake /sys: also on a macOS runner
  mkdir -p "$AWAKE_STATE_DIR" "$TMP/bin"
  # shim for systemd-inhibit: logs its arguments and lives until killed
  cat > "$TMP/bin/systemd-inhibit" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/inhibit.log"
exec sleep 300
SHIM
  chmod +x "$TMP/bin/systemd-inhibit"
  export PATH="$TMP/bin:/usr/bin:/bin"
}
# Own PIDs only: pkill by pattern once killed unrelated processes
teardown() {
  unset AGENT_SYNC_OS HOMEBREW_PREFIX
  for f in "$AWAKE_STATE_DIR"/awake-*.pid; do
    [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null
  done
  rm -rf "$TMP"
}
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

power() { # power <online>
  mkdir -p "$POWER_SUPPLY_DIR/AC" "$POWER_SUPPLY_DIR/BAT0"
  printf 'Mains\n'   > "$POWER_SUPPLY_DIR/AC/type";   printf '%s\n' "$1" > "$POWER_SUPPLY_DIR/AC/online"
  printf 'Battery\n' > "$POWER_SUPPLY_DIR/BAT0/type"; printf '50\n'     > "$POWER_SUPPLY_DIR/BAT0/capacity"
}
pidfile() { printf '%s/awake-%s.pid' "$AWAKE_STATE_DIR" "${1:-sess-1}"; }

# the holder starts in the background, so the log does not appear at once
wait_for() { local f="$1" i=0; while [ ! -s "$f" ] && [ $i -lt 40 ]; do sleep 0.05; i=$((i+1)); done; }

# --- 1. on battery, work keeps the system awake ---------------------------
t_battery_acquires() {
  power 0
  "$AWAKE" acquire sess-1 >/dev/null 2>&1
  wait_for "$TMP/inhibit.log"
  check "lock taken"             test -s "$(pidfile)"
  check "sleep and idle both"  grep -qE 'idle|sleep' "$TMP/inhibit.log"
  check "process alive"          kill -0 "$(cat "$(pidfile)")" 2>/dev/null
}

# --- 2. on mains power we do not interfere ---------------------------------
t_ac_noop() {
  power 1
  "$AWAKE" acquire sess-1 >/dev/null 2>&1
  check "no lock"            test ! -e "$(pidfile)"
  check "inhibit not called" test ! -s "$TMP/inhibit.log"
}

# --- 3. release lets go ----------------------------------------------------
# Otherwise the laptop would not sleep even after the agent has finished.
t_release() {
  power 0
  "$AWAKE" acquire sess-1 >/dev/null 2>&1
  local pid; pid="$(cat "$(pidfile)")"
  "$AWAKE" release sess-1 >/dev/null 2>&1
  sleep 0.3
  check "process stopped" test -z "$(kill -0 "$pid" 2>/dev/null && echo alive)"
  check "pid file removed"  test ! -e "$(pidfile)"
}

# --- 4. a second acquire does not create a second lock ------------------------
t_idempotent() {
  power 0
  "$AWAKE" acquire sess-1 >/dev/null 2>&1
  wait_for "$TMP/inhibit.log"
  local first; first="$(cat "$(pidfile)")"
  "$AWAKE" acquire sess-1 >/dev/null 2>&1
  check "same process"      test "$(cat "$(pidfile)")" = "$first"
  check "one inhibit call" test "$(wc -l < "$TMP/inhibit.log")" -eq 1
}

# --- 5. different sessions hold their own locks ---------------------------------
t_per_session() {
  power 0
  "$AWAKE" acquire sess-1 >/dev/null 2>&1
  "$AWAKE" acquire sess-2 >/dev/null 2>&1
  check "second session has its own" test -s "$(pidfile sess-2)"
  "$AWAKE" release sess-1 >/dev/null 2>&1
  check "other lock not released"  test -s "$(pidfile sess-2)"
}

# --- 6. an abandoned lock does not hold the system forever -------------------
# A session may die in an unclean way; without a sweeper the laptop would never sleep.
t_stale_cleanup() {
  power 0
  "$AWAKE" acquire sess-old >/dev/null 2>&1
  touch -t 200001010000 "$(pidfile sess-old)"
  "$AWAKE" acquire sess-new >/dev/null 2>&1
  check "expired lock removed" test ! -e "$(pidfile sess-old)"
  check "new lock works"    test -s "$(pidfile sess-new)"
}

# --- 7. no systemd-inhibit: quietly do nothing --------------------------------
t_no_inhibit_binary() {
  power 0
  export INHIBIT_BIN="$TMP/bin/no-such-binary"
  local rc; "$AWAKE" acquire sess-1 >/dev/null 2>&1; rc=$?
  check "exit 0"           test "$rc" -eq 0
  check "no pid file"      test ! -e "$(pidfile)"
}

# --- 8. macOS: pmset tells the power source, caffeinate holds the lock ----------
darwin() { # darwin <pmset source>: fake macOS with pmset and caffeinate shims
  mkdir -p "$TMP/brew/opt/coreutils/libexec/gnubin" "$TMP/brew/opt/gnu-sed/libexec/gnubin" \
           "$TMP/brew/opt/findutils/libexec/gnubin"
  mkdir -p "$TMP/brew/bin"; ln -sf "$(command -v bash)" "$TMP/brew/bin/bash"
  export AGENT_SYNC_OS=darwin HOMEBREW_PREFIX="$TMP/brew"
  unset INHIBIT_BIN
  printf '#!/bin/sh\necho "Now drawing from '"'"'%s'"'"'"\necho " -InternalBattery-0 (id=1)\t50%%; discharging; present: true"\n' "$1" \
    > "$TMP/bin/pmset"
  cat > "$TMP/bin/caffeinate" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/caffeinate.log"
exec sleep 300
SHIM
  chmod +x "$TMP/bin/pmset" "$TMP/bin/caffeinate"
}

t_darwin_battery() {
  darwin 'Battery Power'
  "$AWAKE" acquire sess-1 >/dev/null 2>&1
  wait_for "$TMP/caffeinate.log"
  check "lock taken with caffeinate" test -s "$(pidfile)"
  check "idle sleep blocked (-i)"    grep -q -- '-i' "$TMP/caffeinate.log"
  check "no systemd-inhibit"         test ! -s "$TMP/inhibit.log"
  "$AWAKE" release sess-1 >/dev/null 2>&1
  check "released"                   test ! -e "$(pidfile)"
}

t_darwin_ac() {
  darwin 'AC Power'
  "$AWAKE" acquire sess-1 >/dev/null 2>&1
  check "no lock on AC"        test ! -e "$(pidfile)"
  check "caffeinate not called" test ! -s "$TMP/caffeinate.log"
}

run_test "on battery we hold the system"       t_battery_acquires
run_test "on mains power we do not interfere"  t_ac_noop
run_test "release lets go"                     t_release
run_test "repeated acquire is idempotent"      t_idempotent
run_test "sessions are independent"            t_per_session
run_test "abandoned lock is removed"           t_stale_cleanup
run_test "no systemd-inhibit: do not crash"    t_no_inhibit_binary
run_test "macOS on battery: caffeinate"         t_darwin_battery
run_test "macOS on AC: nothing"                 t_darwin_ac

printf '\ntotal: %d ok, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
