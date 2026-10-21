#!/usr/bin/env bash
# Tests for "agent-sync.sh timers": systemd user units on Linux/WSL, launchd agents on macOS.
# systemctl, loginctl and launchctl are stubs that log their arguments.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/bin/agent-sync.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "not satisfied: $*"; fi; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) fail "$1" "'$2' not in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail "$1" "'$2' found in: $3" ;; *) ok "$1" ;; esac; }

setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home" SYNC_HOME="$TMP/home/.agent-sync"
  mkdir -p "$SYNC_HOME" "$TMP/bin"
  ln -s "$REPO/systemd" "$SYNC_HOME/systemd"
  ln -s "$REPO/bin" "$SYNC_HOME/bin"
  : > "$SYNC_HOME/agent-sync.env"
  local s
  for s in systemctl loginctl launchctl; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\n[ "$1 $2" = "--user show-environment" ] && [ -n "$SYSTEMD_DOWN" ] && exit 1\n[ "$1" = print ] && exit 113\nexit 0\n' \
      "$s" "$TMP" > "$TMP/bin/$s"
    chmod +x "$TMP/bin/$s"
  done
  export PATH="$TMP/bin:$ORIG_PATH"
  unset XDG_CONFIG_HOME SYSTEMD_DOWN
  # a fake Homebrew so compat.sh accepts darwin on a Linux runner
  mkdir -p "$TMP/brew/opt/coreutils/libexec/gnubin" "$TMP/brew/opt/gnu-sed/libexec/gnubin" \
           "$TMP/brew/opt/findutils/libexec/gnubin"
  mkdir -p "$TMP/brew/bin"; ln -sf "$(command -v bash)" "$TMP/brew/bin/bash"
  export HOMEBREW_PREFIX="$TMP/brew"
}
teardown() { rm -rf "$TMP"; }
ORIG_PATH="$PATH"
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }
calls() { cat "$TMP/calls.log" 2>/dev/null; }

# plist <file> <python expression over p>: read a value from a plist with plistlib
plist() {
  python3 -c 'import plistlib,sys; p=plistlib.load(open(sys.argv[1],"rb")); print(eval(sys.argv[2]))' "$1" "$2" 2>&1
}

t_linux_enable() {
  AGENT_SYNC_OS=linux "$SCRIPT" timers enable >"$TMP/out" 2>&1; local rc=$?
  check "exit 0" test "$rc" -eq 0
  local u="$HOME/.config/systemd/user"
  check "sync service linked" test -L "$u/agent-sync.service"
  check "sync timer linked" test -L "$u/agent-sync.timer"
  check "link points into the repo" test "$(readlink "$u/agent-sync.timer")" = "$SYNC_HOME/systemd/agent-sync.timer"
  has "daemon-reload" "systemctl --user daemon-reload" "$(calls)"
  has "boundary and sync enabled" "systemctl --user enable --now agent-sync-boundary.service agent-sync.timer" "$(calls)"
  hasnt "history timer off without SYNC_SERVER" "agent-history.timer" "$(calls)"
  hasnt "linger is not changed by itself" "loginctl" "$(calls)"
  has "linger hint is printed" "loginctl enable-linger" "$(cat "$TMP/out")"
}

t_linux_history_with_server() {
  printf 'SYNC_SERVER=nas\n' > "$SYNC_HOME/agent-sync.env"
  AGENT_SYNC_OS=linux "$SCRIPT" timers enable >/dev/null 2>&1
  has "history timer enabled with SYNC_SERVER" "agent-history.timer" "$(calls)"
}

t_linux_named_and_xdg() {
  export XDG_CONFIG_HOME="$TMP/xdg"
  AGENT_SYNC_OS=linux "$SCRIPT" timers enable herdr-notify >/dev/null 2>&1
  check "units go to XDG_CONFIG_HOME" test -L "$TMP/xdg/systemd/user/herdr-notify.timer"
  has "only the named timer" "systemctl --user enable --now herdr-notify.timer" "$(calls)"
  AGENT_SYNC_OS=linux "$SCRIPT" timers enable nonsense >"$TMP/out" 2>&1; local rc=$?
  check "unknown name: exit 2" test "$rc" -eq 2
  has "unknown name is named" "nonsense" "$(cat "$TMP/out")"
}

t_linux_disable() {
  AGENT_SYNC_OS=linux "$SCRIPT" timers enable >/dev/null 2>&1
  : > "$TMP/calls.log"
  AGENT_SYNC_OS=linux "$SCRIPT" timers disable >/dev/null 2>&1
  has "disable --now" "systemctl --user disable --now" "$(calls)"
  check "links removed" test ! -e "$HOME/.config/systemd/user/agent-sync.timer"
}

t_wsl_without_systemd() {
  export SYSTEMD_DOWN=1
  AGENT_SYNC_OS=wsl "$SCRIPT" timers enable >"$TMP/out" 2>&1; local rc=$?
  check "exit 1" test "$rc" -eq 1
  has "names /etc/wsl.conf" "/etc/wsl.conf" "$(cat "$TMP/out")"
  has "names systemd=true" "systemd=true" "$(cat "$TMP/out")"
  has "names wsl --shutdown" "wsl --shutdown" "$(cat "$TMP/out")"
  hasnt "nothing enabled" "enable --now" "$(calls)"
}

t_darwin_enable() {
  AGENT_SYNC_OS=darwin "$SCRIPT" timers enable >"$TMP/out" 2>&1; local rc=$?
  check "exit 0" test "$rc" -eq 0
  local d="$HOME/Library/LaunchAgents"
  local s="$d/dev.agent-sync.agent-sync.plist" b="$d/dev.agent-sync.agent-sync-boundary.plist"
  check "sync plist written" test -f "$s"
  check "boundary plist written" test -f "$b"
  check "no history plist without SYNC_SERVER" test ! -e "$d/dev.agent-sync.agent-history.plist"
  check "no systemd links on macOS" test ! -e "$HOME/.config/systemd"
  has "label" "dev.agent-sync.agent-sync" "$(plist "$s" 'p["Label"]')"
  has "sync program" "['$SYNC_HOME/bin/agent-sync.sh', 'sync']" "$(plist "$s" 'p["ProgramArguments"]')"
  has "every 5 minutes" "300" "$(plist "$s" 'p["StartInterval"]')"
  has "boundary pulls at login" "['$SYNC_HOME/bin/agent-sync.sh', 'pull']" "$(plist "$b" 'p["ProgramArguments"]')"
  has "boundary RunAtLoad" "True" "$(plist "$b" 'p["RunAtLoad"]')"
  has "PATH has Homebrew GNU tools" "$TMP/brew/opt/coreutils/libexec/gnubin" "$(plist "$s" 'p["EnvironmentVariables"]["PATH"]')"
  has "log under ~/Library/Logs" "$HOME/Library/Logs/agent-sync/agent-sync.log" "$(plist "$s" 'p["StandardErrorPath"]')"
  has "bootstrap into the GUI domain" "launchctl bootstrap gui/$(id -u) $s" "$(calls)"
  hasnt "no systemctl on macOS" "systemctl" "$(calls)"
}

t_darwin_escape_and_idempotent() {
  AGENT_SYNC_OS=darwin "$SCRIPT" timers enable >/dev/null 2>&1
  local s="$HOME/Library/LaunchAgents/dev.agent-sync.agent-sync.plist" first
  first="$(cat "$s")"
  AGENT_SYNC_OS=darwin "$SCRIPT" timers enable >/dev/null 2>&1
  check "second enable writes the same plist" test "$first" = "$(cat "$s")"
  has "reload: bootout before bootstrap" "launchctl bootout gui/$(id -u)/dev.agent-sync.agent-sync" "$(calls)"
  # a path with XML characters must stay valid XML
  PATH="$TMP/a&b<c:$PATH" AGENT_SYNC_OS=darwin "$SCRIPT" timers enable >/dev/null 2>&1
  has "XML characters escaped" "$TMP/a&b<c" "$(plist "$s" 'p["EnvironmentVariables"]["PATH"]')"
}

t_darwin_history_and_disable() {
  printf 'SYNC_SERVER=nas\n' > "$SYNC_HOME/agent-sync.env"
  AGENT_SYNC_OS=darwin "$SCRIPT" timers enable >/dev/null 2>&1
  local h="$HOME/Library/LaunchAgents/dev.agent-sync.agent-history.plist"
  check "history plist with SYNC_SERVER" test -f "$h"
  has "hourly" "3600" "$(plist "$h" 'p["StartInterval"]')"
  : > "$TMP/calls.log"
  AGENT_SYNC_OS=darwin "$SCRIPT" timers disable >/dev/null 2>&1
  has "bootout on disable" "launchctl bootout gui/$(id -u)/dev.agent-sync.agent-sync" "$(calls)"
  check "plists removed" test -z "$(ls "$HOME/Library/LaunchAgents" 2>/dev/null)"
}

t_darwin_reenable_waits() {
  # launchd removes a job after bootout returns; bootstrap of the same label fails until then
  cat > "$TMP/bin/launchctl" <<SHIM
#!/bin/sh
echo "launchctl \$*" >> "$TMP/calls.log"
n=\$(cat "$TMP/leaving" 2>/dev/null || echo 0)
case "\$1" in
  print) [ "\$n" -gt 0 ] && { echo \$((n-1)) > "$TMP/leaving"; exit 0; }; exit 113 ;;
  bootstrap) [ "\$n" -gt 0 ] && { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; } ;;
esac
exit 0
SHIM
  echo 2 > "$TMP/leaving"
  AGENT_SYNC_OS=darwin "$SCRIPT" timers enable agent-sync >"$TMP/out" 2>&1; local rc=$?
  check "exit 0 while the old job is still leaving" test "$rc" -eq 0
  has "loaded" "timers: loaded agent-sync" "$(cat "$TMP/out")"
}

t_darwin_tailcat_unsupported() {
  AGENT_SYNC_OS=darwin "$SCRIPT" timers enable tailcat-serve >"$TMP/out" 2>&1; local rc=$?
  check "exit 2" test "$rc" -eq 2
  has "says Linux only" "Linux only" "$(cat "$TMP/out")"
}

t_status() {
  AGENT_SYNC_OS=linux "$SCRIPT" timers status >/dev/null 2>&1; local rc=$?
  check "linux status runs" test "$rc" -eq 0
  has "linux asks systemctl" "systemctl --user is-active" "$(calls)"
  : > "$TMP/calls.log"
  AGENT_SYNC_OS=darwin "$SCRIPT" timers status >/dev/null 2>&1
  has "darwin asks launchctl" "launchctl print gui/$(id -u)/dev.agent-sync.agent-sync" "$(calls)"
}

run_test "linux: enable links units and enables the default set" t_linux_enable
run_test "linux: history timer only with SYNC_SERVER"            t_linux_history_with_server
run_test "linux: named timer, XDG_CONFIG_HOME, unknown name"     t_linux_named_and_xdg
run_test "linux: disable"                                         t_linux_disable
run_test "wsl: no systemd user session — hint, nothing enabled"   t_wsl_without_systemd
run_test "darwin: enable writes launchd agents"                   t_darwin_enable
run_test "darwin: idempotent, XML escaped"                        t_darwin_escape_and_idempotent
run_test "darwin: history agent and disable"                      t_darwin_history_and_disable
run_test "darwin: re-enable waits for the old job"                t_darwin_reenable_waits
run_test "darwin: tailcat is Linux only"                          t_darwin_tailcat_unsupported
run_test "status on both"                                         t_status

printf '\ntotal: %s ok, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
