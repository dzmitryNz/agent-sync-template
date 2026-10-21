#!/usr/bin/env bash
# Tests for bin/lib/compat.sh: OS detection, GNU tools on macOS, notifications, power source.
set -uo pipefail

LIB="$(cd "$(dirname "$0")/.." && pwd)/bin/lib/compat.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
eq()   { # eq <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}
has()  { # has <description> <needle> <haystack>
  case "$3" in *"$2"*) ok "$1" ;; *) fail "$1" "'$2' not in: $3" ;; esac
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BASE_PATH="/usr/bin:/bin"

# lib <code> [VAR=value ...]: source compat.sh in a clean shell, then run <code>
lib() {
  local code="$1"; shift
  env -i HOME="$TMP/home" PATH="${TEST_PATH:-$BASE_PATH}" AGENT_SYNC_BASH_MAJOR=5 "$@" \
    bash -c ". '$LIB' || { echo 'source-failed'; exit 1; }; $code" 2>&1
}

brew_prefix() { # brew_prefix <dir> <pkg...>: fake Homebrew layout; bash = bin/bash linked to the real one
  local d="$1" p; shift
  for p in "$@"; do
    if [ "$p" = bash ]; then mkdir -p "$d/bin"; ln -sf "$(command -v bash)" "$d/bin/bash"
    else mkdir -p "$d/opt/$p/libexec/gnubin"; fi
  done
}

echo "OS detection"
printf 'Linux version 6.1.0 (gcc) #1 SMP\n' > "$TMP/proc-linux"
printf 'Linux version 5.15.167.4-microsoft-standard-WSL2 (gcc)\n' > "$TMP/proc-wsl"
eq "linux from /proc/version"  linux  "$(lib 'echo $AGENT_SYNC_OS' AGENT_SYNC_PROC_VERSION="$TMP/proc-linux" AGENT_SYNC_UNAME=Linux)"
eq "wsl from /proc/version"    wsl    "$(lib 'echo $AGENT_SYNC_OS' AGENT_SYNC_PROC_VERSION="$TMP/proc-wsl" AGENT_SYNC_UNAME=Linux)"
brew_prefix "$TMP/brew-ok" bash coreutils gnu-sed findutils
eq "darwin from uname"         darwin "$(lib 'echo $AGENT_SYNC_OS' AGENT_SYNC_UNAME=Darwin HOMEBREW_PREFIX="$TMP/brew-ok")"
eq "override wins"             darwin "$(lib 'echo $AGENT_SYNC_OS' AGENT_SYNC_OS=darwin AGENT_SYNC_UNAME=Linux HOMEBREW_PREFIX="$TMP/brew-ok")"

echo "linux: PATH is not touched"
eq "PATH unchanged" "$BASE_PATH" "$(lib 'echo $PATH' AGENT_SYNC_OS=linux)"

echo "darwin: GNU tools first in PATH"
out="$(lib 'echo $PATH' AGENT_SYNC_OS=darwin HOMEBREW_PREFIX="$TMP/brew-ok")"
eq "coreutils, gnu-sed, findutils before the system PATH" \
  "$TMP/brew-ok/opt/findutils/libexec/gnubin:$TMP/brew-ok/opt/gnu-sed/libexec/gnubin:$TMP/brew-ok/opt/coreutils/libexec/gnubin:$TMP/brew-ok/bin:$BASE_PATH" "$out"
out="$(lib '. "'"$LIB"'"; echo $PATH' AGENT_SYNC_OS=darwin HOMEBREW_PREFIX="$TMP/brew-ok")"
eq "sourcing twice does not repeat entries" \
  "$TMP/brew-ok/opt/findutils/libexec/gnubin:$TMP/brew-ok/opt/gnu-sed/libexec/gnubin:$TMP/brew-ok/opt/coreutils/libexec/gnubin:$TMP/brew-ok/bin:$BASE_PATH" "$out"

echo "darwin: prefix from brew when HOMEBREW_PREFIX is unset"
mkdir -p "$TMP/fakebin"
printf '#!/bin/sh\n[ "$1" = --prefix ] && echo "%s"\n' "$TMP/brew-ok" > "$TMP/fakebin/brew"; chmod +x "$TMP/fakebin/brew"
out="$(TEST_PATH="$TMP/fakebin:$BASE_PATH" lib 'echo $PATH' AGENT_SYNC_OS=darwin AGENT_SYNC_BREW_DIRS="$TMP/none")"
has "brew --prefix is used" "$TMP/brew-ok/opt/coreutils/libexec/gnubin" "$out"

echo "darwin: missing GNU tools fail with the install command"
brew_prefix "$TMP/brew-part" coreutils
out="$(lib 'echo sourced' AGENT_SYNC_OS=darwin HOMEBREW_PREFIX="$TMP/brew-part")"
has "source fails" "source-failed" "$out"
has "names the brew command" "brew install bash coreutils gnu-sed findutils" "$out"
out="$(lib 'echo sourced' AGENT_SYNC_OS=darwin HOMEBREW_PREFIX="$TMP/nowhere" AGENT_SYNC_BREW_DIRS="$TMP/none")"
has "no Homebrew at all also fails" "source-failed" "$out"
has "and points to brew.sh" "https://brew.sh" "$out"
brew_prefix "$TMP/brew-nobash" coreutils gnu-sed findutils
out="$(lib 'echo sourced' AGENT_SYNC_OS=darwin HOMEBREW_PREFIX="$TMP/brew-nobash")"
has "no Homebrew bash also fails" "source-failed" "$out"
has "and names brew install bash" "brew install bash" "$out"

echo "darwin: an old /bin/bash re-runs the script with Homebrew bash"
brew_prefix "$TMP/brew-bash" coreutils gnu-sed findutils
mkdir -p "$TMP/brew-bash/bin"
printf '#!/bin/sh\necho "reexec $*"\n' > "$TMP/brew-bash/bin/bash"; chmod +x "$TMP/brew-bash/bin/bash"
printf '#!/usr/bin/env bash\n. "%s" || exit 1\necho "still old bash"\n' "$LIB" > "$TMP/script.sh"
out="$(env -i HOME="$TMP/home" PATH="$BASE_PATH" AGENT_SYNC_OS=darwin HOMEBREW_PREFIX="$TMP/brew-bash" \
  AGENT_SYNC_BASH_MAJOR=3 bash "$TMP/script.sh" a 'b c' 2>&1)"
eq "exec with the script and its arguments" "reexec $TMP/script.sh a b c" "$out"
out="$(env -i HOME="$TMP/home" PATH="$BASE_PATH" AGENT_SYNC_OS=darwin HOMEBREW_PREFIX="$TMP/brew-bash" \
  AGENT_SYNC_BASH_MAJOR=3 AGENT_SYNC_REEXEC=1 bash "$TMP/script.sh" 2>&1)"
eq "no second exec (no loop)" "still old bash" "$out"
out="$(env -i HOME="$TMP/home" PATH="$BASE_PATH" AGENT_SYNC_OS=darwin HOMEBREW_PREFIX="$TMP/brew-bash" \
  AGENT_SYNC_BASH_MAJOR=5 bash "$TMP/script.sh" 2>&1)"
eq "bash 4+ is not re-run" "still old bash" "$out"

echo "notify"
mkdir -p "$TMP/nbin"
printf '#!/bin/sh\nprintf "%%s|" "$@" >> "%s/notify.log"\n' "$TMP" > "$TMP/nbin/notify-send"
printf '#!/bin/sh\nprintf "%%s|" "$@" >> "%s/osa.log"\n' "$TMP" > "$TMP/nbin/osascript"
chmod +x "$TMP/nbin/"*
TEST_PATH="$TMP/nbin:$BASE_PATH" lib 'agent_sync_notify "Title" "Body \"x\""' AGENT_SYNC_OS=linux >/dev/null
has "linux uses notify-send" "-u|critical|Title|Body \"x\"|" "$(cat "$TMP/notify.log" 2>/dev/null)"
TEST_PATH="$TMP/nbin:$BASE_PATH" lib 'agent_sync_notify "Title" "Body \"x\""' AGENT_SYNC_OS=darwin HOMEBREW_PREFIX="$TMP/brew-ok" >/dev/null
has "darwin passes text as osascript arguments, not inside the script" "Title|Body \"x\"|" "$(cat "$TMP/osa.log" 2>/dev/null)"
eq "no notifier: silent, exit 0" "0" "$(lib 'agent_sync_notify T B; echo $?' AGENT_SYNC_OS=linux)"

echo "power source"
mkdir -p "$TMP/pbin"
pmset() { # pmset <text>: fake pmset -g batt
  printf '#!/bin/sh\ncat <<EOF\n%s\nEOF\n' "$1" > "$TMP/pbin/pmset"; chmod +x "$TMP/pbin/pmset"
}
pmset "Now drawing from 'AC Power'
 -InternalBattery-0 (id=1234)	100%; charged; 0:00 remaining present: true"
eq "darwin AC with the battery level" "ac 100" "$(TEST_PATH="$TMP/pbin:$BASE_PATH" lib 'agent_sync_power' AGENT_SYNC_OS=darwin HOMEBREW_PREFIX="$TMP/brew-ok")"
pmset "Now drawing from 'Battery Power'
 -InternalBattery-0 (id=1234)	42%; discharging; 3:10 remaining present: true"
eq "darwin battery with capacity" "battery 42" "$(TEST_PATH="$TMP/pbin:$BASE_PATH" lib 'agent_sync_power' AGENT_SYNC_OS=darwin HOMEBREW_PREFIX="$TMP/brew-ok")"
eq "darwin without pmset: unknown" "unknown" "$(lib 'agent_sync_power' AGENT_SYNC_OS=darwin HOMEBREW_PREFIX="$TMP/brew-ok" AGENT_SYNC_PMSET="$TMP/none/pmset")"
mkdir -p "$TMP/power/AC" "$TMP/power/BAT0"
printf 'Mains\n' > "$TMP/power/AC/type"; printf '0\n' > "$TMP/power/AC/online"
printf 'Battery\n' > "$TMP/power/BAT0/type"; printf '57\n' > "$TMP/power/BAT0/capacity"
eq "linux battery from /sys" "battery 57" "$(lib 'agent_sync_power' AGENT_SYNC_OS=linux POWER_SUPPLY_DIR="$TMP/power")"
printf '1\n' > "$TMP/power/AC/online"
eq "linux AC with the battery level" "ac 57" "$(lib 'agent_sync_power' AGENT_SYNC_OS=linux POWER_SUPPLY_DIR="$TMP/power")"
rm -rf "$TMP/power/BAT0"
eq "linux desktop on mains, no battery" "ac" "$(lib 'agent_sync_power' AGENT_SYNC_OS=linux POWER_SUPPLY_DIR="$TMP/power")"
eq "linux desktop without /sys power: unknown" "unknown" "$(lib 'agent_sync_power' AGENT_SYNC_OS=linux POWER_SUPPLY_DIR="$TMP/none")"

printf '\ntotal: %s ok, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
