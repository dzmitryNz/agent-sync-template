#!/usr/bin/env bash
# Tests for store/.claude/hooks/limit-wake-hook.sh: after a usage-limit message, wake the pane
# 5 minutes after the reset. systemd-run on Linux, a one-shot launchd agent on macOS.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/store/.claude/hooks/limit-wake-hook.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "not satisfied: $*"; fi; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) fail "$1" "'$2' not in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail "$1" "'$2' found in: $3" ;; *) ok "$1" ;; esac; }

export LC_ALL=C  # month names and am/pm as claude /usage prints them
ORIG_PATH="$PATH"
setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/rt" HERDR_ENV=1 HERDR_PANE_ID=w1:p2
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR/claude-herdr-meta" "$TMP/bin"
  # reset in about two hours, in the format of claude /usage ("Oct 21, 12pm (UTC)")
  RESET_EPOCH="$(date -d "$(date -d '+2 hours' '+%Y-%m-%d %H:00')" +%s)"
  printf 'SHARED_SESSION_RESET=%q\n' "$(date -d "@$RESET_EPOCH" '+%b %-d, %-I%P') (UTC)" \
    > "$XDG_RUNTIME_DIR/claude-herdr-meta/usage-limits"
  local s
  printf '#!/bin/sh\necho "systemd-run $*" >> "%s/calls.log"\n' "$TMP" > "$TMP/bin/systemd-run"
  # launchctl keeps one state for the tests: $TMP/loaded exists while a job is loaded
  cat > "$TMP/bin/launchctl" <<SHIM
#!/bin/sh
echo "launchctl \$*" >> "$TMP/calls.log"
case "\$1" in
  print) [ -e "$TMP/loaded" ] || exit 113 ;;
  bootout) rm -f "$TMP/loaded" ;;
  bootstrap) touch "$TMP/loaded" ;;
esac
exit 0
SHIM
  printf '#!/bin/sh\n[ "$1 $2" = "--user is-active" ] && exit 3\nexit 0\n' > "$TMP/bin/systemctl"
  cat > "$TMP/bin/herdr" <<SHIM
#!/bin/sh
echo "herdr \$*" >> "$TMP/calls.log"
[ "\$1 \$2" = "agent get" ] && echo '{"result":{"agent":{"agent_status":"idle"}}}'
exit 0
SHIM
  chmod +x "$TMP/bin/"*
  export HERDR_BIN="$TMP/bin/herdr" PATH="$TMP/bin:$ORIG_PATH"
  mkdir -p "$TMP/brew/opt/coreutils/libexec/gnubin" "$TMP/brew/opt/gnu-sed/libexec/gnubin" \
           "$TMP/brew/opt/findutils/libexec/gnubin"
  mkdir -p "$TMP/brew/bin"; ln -sf "$(command -v bash)" "$TMP/brew/bin/bash"
  unset AGENT_SYNC_OS HOMEBREW_PREFIX
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }
calls() { cat "$TMP/calls.log" 2>/dev/null; }
event() { printf '{"hook_event_name":"Stop","message":"You have hit your usage limit · resets 3pm"}'; }
darwin() { export AGENT_SYNC_OS=darwin HOMEBREW_PREFIX="$TMP/brew"; }
PLIST() { printf '%s' "$HOME/Library/LaunchAgents/dev.agent-sync.limit-wake-w1-p2.plist"; }
plist() { python3 -c 'import plistlib,sys; p=plistlib.load(open(sys.argv[1],"rb")); print(eval(sys.argv[2]))' "$(PLIST)" "$1" 2>&1; }

t_linux_systemd_run() {
  export AGENT_SYNC_OS=linux
  event | "$HOOK"; local rc=$?
  check "exit 0" test "$rc" -eq 0
  has "systemd-run with a delay" "systemd-run --user --unit=agent-limit-wake-w1-p2 --on-active=" "$(calls)"
  hasnt "no launchctl on Linux" "launchctl" "$(calls)"
}

t_darwin_plist() {
  darwin
  event | "$HOOK"; local rc=$?
  check "exit 0" test "$rc" -eq 0
  check "plist written" test -f "$(PLIST)"
  local wake=$((RESET_EPOCH + 300))
  has "fires 5 minutes after the reset (local time)" \
    "$(date -d "@$wake" '+%-m %-d %-H %-M')" \
    "$(plist '" ".join(str(p["StartCalendarInterval"][k]) for k in ("Month","Day","Hour","Minute"))')"
  has "runs the hook for the pane" "'$HOOK', '--run', '--target', 'w1:p2'" "$(plist 'p["ProgramArguments"]')"
  has "removes itself after the run" "'--launchd-label', 'dev.agent-sync.limit-wake-w1-p2'" "$(plist 'p["ProgramArguments"]')"
  has "loaded into the GUI domain" "launchctl bootstrap gui/$(id -u) $(PLIST)" "$(calls)"
  hasnt "no systemd-run on macOS" "systemd-run" "$(calls)"
}

t_darwin_once() {
  darwin
  event | "$HOOK"; event | "$HOOK"
  check "the same wake twice: one bootstrap" test "$(grep -c bootstrap "$TMP/calls.log")" -eq 1
}

t_darwin_replace() {
  darwin
  # a loaded agent of this pane for another time (it missed its minute while the Mac was off)
  mkdir -p "$HOME/Library/LaunchAgents"; echo old > "$(PLIST)"; touch "$TMP/loaded"
  event | "$HOOK"
  has "the old agent is unloaded" "launchctl bootout gui/$(id -u)/dev.agent-sync.limit-wake-w1-p2" "$(calls)"
  has "the new one is loaded" "launchctl bootstrap gui/$(id -u) $(PLIST)" "$(calls)"
  check "with the new time" grep -q StartCalendarInterval "$(PLIST)"
}

t_darwin_run_cleans_up() {
  darwin
  mkdir -p "$HOME/Library/LaunchAgents"; : > "$(PLIST)"
  "$HOOK" --run --target w1:p2 --message 'go on' --launchd-label dev.agent-sync.limit-wake-w1-p2; local rc=$?
  check "exit 0" test "$rc" -eq 0
  has "pane prompted" "herdr agent prompt w1:p2 go on" "$(calls)"
  check "plist removed" test ! -e "$(PLIST)"
  has "job unloaded" "launchctl bootout gui/$(id -u)/dev.agent-sync.limit-wake-w1-p2" "$(calls)"
}

t_darwin_run_cleans_up_without_herdr() {
  darwin
  mkdir -p "$HOME/Library/LaunchAgents"; : > "$(PLIST)"
  HERDR_BIN="$TMP/none/herdr" PATH="$TMP/bin:/usr/bin:/bin" \
    "$HOOK" --run --target w1:p2 --message x --launchd-label dev.agent-sync.limit-wake-w1-p2
  check "plist removed when herdr is missing" test ! -e "$(PLIST)"
  has "job unloaded when herdr is missing" "launchctl bootout gui/$(id -u)/dev.agent-sync.limit-wake-w1-p2" "$(calls)"
}

t_darwin_stale_plist() {
  darwin
  touch "$TMP/loaded"
  local dir="$HOME/Library/LaunchAgents"
  mkdir -p "$dir"; : > "$(PLIST)"; : > "$dir/dev.agent-sync.limit-wake-w9-p9.plist"
  touch -t 200001010000 "$(PLIST)" "$dir/dev.agent-sync.limit-wake-w9-p9.plist"
  event | "$HOOK"
  has "a stale agent of this pane is replaced" "launchctl bootstrap gui/$(id -u) $(PLIST)" "$(calls)"
  check "a stale agent of another pane is removed" test ! -e "$dir/dev.agent-sync.limit-wake-w9-p9.plist"
  has "and unloaded" "launchctl bootout gui/$(id -u)/dev.agent-sync.limit-wake-w9-p9" "$(calls)"
}

t_darwin_runtime_dir() {
  darwin
  unset XDG_RUNTIME_DIR
  "$HOOK" --run --target w1:p2 --message x >/dev/null 2>&1
  check "herdr is not pointed at /run/user on macOS" test -z "$(env -u XDG_RUNTIME_DIR \
    AGENT_SYNC_OS=darwin HOMEBREW_PREFIX="$TMP/brew" bash -c '. "'"$REPO"'/bin/lib/compat.sh"; echo ${XDG_RUNTIME_DIR:-}')"
}

run_test "linux: systemd-run timer"                 t_linux_systemd_run
run_test "darwin: one-shot launchd agent"           t_darwin_plist
run_test "darwin: a loaded agent is not doubled"    t_darwin_once
run_test "darwin: a new wake replaces the old one"   t_darwin_replace
run_test "darwin: the run prompts and cleans up"    t_darwin_run_cleans_up
run_test "darwin: cleanup when herdr is missing"     t_darwin_run_cleans_up_without_herdr
run_test "darwin: an agent older than 8 days"     t_darwin_stale_plist
run_test "darwin: no /run/user"                     t_darwin_runtime_dir

printf '\ntotal: %s ok, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
