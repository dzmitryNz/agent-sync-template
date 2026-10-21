#!/usr/bin/env bash
# Platform layer for agent-sync scripts and hooks. Source it, do not run it.
#
# Sets AGENT_SYNC_OS to linux, wsl or darwin (override: AGENT_SYNC_OS=...).
# On macOS the scripts keep their GNU calls (date -d, stat -c, sed -i, find -printf,
# timeout): Homebrew's gnubin dirs go first in PATH. Sourcing fails when they are
# missing, so the caller can stop with the install command instead of a wrong result.

if [ -z "${AGENT_SYNC_OS:-}" ]; then
  case "${AGENT_SYNC_UNAME:-$(uname -s 2>/dev/null)}" in
    Darwin) AGENT_SYNC_OS=darwin ;;
    *)
      if grep -qi microsoft "${AGENT_SYNC_PROC_VERSION:-/proc/version}" 2>/dev/null; then
        AGENT_SYNC_OS=wsl
      else
        AGENT_SYNC_OS=linux
      fi ;;
  esac
fi
export AGENT_SYNC_OS

if [ "$AGENT_SYNC_OS" = darwin ]; then
  # brew --prefix costs ~0.1 s per hook call; the two standard places are checked first
  _cp_prefix="${HOMEBREW_PREFIX:-}"
  if [ -z "$_cp_prefix" ]; then
    for _cp_dir in ${AGENT_SYNC_BREW_DIRS:-/opt/homebrew /usr/local}; do
      [ -x "$_cp_dir/bin/brew" ] && { _cp_prefix="$_cp_dir"; break; }
    done
  fi
  [ -n "$_cp_prefix" ] || _cp_prefix="$(brew --prefix 2>/dev/null)"
  _cp_missing=''
  for _cp_pkg in coreutils gnu-sed findutils; do
    [ -d "$_cp_prefix/opt/$_cp_pkg/libexec/gnubin" ] || _cp_missing="$_cp_missing $_cp_pkg"
  done
  # without it there is no re-exec below, and mapfile / declare -A fail under /bin/bash 3.2
  [ -x "$_cp_prefix/bin/bash" ] || _cp_missing="$_cp_missing bash"
  if [ -z "$_cp_prefix" ] || [ -n "$_cp_missing" ]; then
    printf 'agent-sync on macOS needs Homebrew (https://brew.sh) and GNU tools: brew install bash coreutils gnu-sed findutils\n' >&2
    unset _cp_prefix _cp_missing _cp_pkg
    return 1 2>/dev/null || exit 1
  fi
  # bin first for Homebrew bash, then gnubin dirs, so they win over the BSD tools
  for _cp_dir in "$_cp_prefix/bin" "$_cp_prefix/opt/coreutils/libexec/gnubin" \
                 "$_cp_prefix/opt/gnu-sed/libexec/gnubin" "$_cp_prefix/opt/findutils/libexec/gnubin"; do
    case ":$PATH:" in *":$_cp_dir:"*) ;; *) PATH="$_cp_dir:$PATH" ;; esac
  done
  export PATH
  # macOS /bin/bash is 3.2 (no declare -A, mapfile). A hook or launchd job may start
  # the script with it; run it again with Homebrew bash, once.
  if [ "${AGENT_SYNC_BASH_MAJOR:-${BASH_VERSINFO[0]:-0}}" -lt 4 ] && [ -z "${AGENT_SYNC_REEXEC:-}" ] &&
     [ -x "$_cp_prefix/bin/bash" ]; then
    export AGENT_SYNC_REEXEC=1
    exec "$_cp_prefix/bin/bash" "$0" "$@"
  fi
  unset _cp_prefix _cp_missing _cp_pkg _cp_dir
fi

# agent_sync_notify <title> <body>: desktop notification if the machine has one, else nothing.
agent_sync_notify() {
  if [ "$AGENT_SYNC_OS" = darwin ]; then
    # text goes in as arguments: quoting it into the script breaks on a quote in the body
    command -v osascript >/dev/null 2>&1 &&
      osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
        -e 'end run' "$1" "$2" >/dev/null 2>&1
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send -u critical "$1" "$2" 2>/dev/null
  fi
  return 0
}

# agent_sync_power: prints "ac [percent]", "battery <percent>" or "unknown" (no data).
# The percent is there when the machine has a battery.
agent_sync_power() {
  local on_ac='' cap='' found=''
  if [ "$AGENT_SYNC_OS" = darwin ]; then
    local out
    out="$("${AGENT_SYNC_PMSET:-pmset}" -g batt 2>/dev/null)" || { echo unknown; return 0; }
    case "$out" in
      *"'AC Power'"*) on_ac=1; found=1 ;;
      *"'Battery Power'"*) found=1 ;;
    esac
    cap="$(printf '%s\n' "$out" | sed -n 's/.*[[:space:]]\([0-9][0-9]*\)%;.*/\1/p' | head -1)"
  else
    local dir="${POWER_SUPPLY_DIR:-/sys/class/power_supply}" ps
    for ps in "$dir"/*/; do
      [ -d "$ps" ] || continue
      case "$(cat "$ps/type" 2>/dev/null)" in
        Mains)   found=1; [ "$(cat "$ps/online" 2>/dev/null)" = 1 ] && on_ac=1 ;;
        Battery) found=1; [ -n "$cap" ] || cap="$(cat "$ps/capacity" 2>/dev/null)" ;;
      esac
    done
  fi
  case "$cap" in *[!0-9]*) cap='' ;; esac
  if [ -z "$found" ]; then echo unknown
  elif [ -n "$on_ac" ]; then echo "ac${cap:+ $cap}"
  elif [ -n "$cap" ]; then echo "battery $cap"
  else echo unknown
  fi
}

# agent_sync_xml_escape <text>: for strings in a launchd plist
agent_sync_xml_escape() {
  local s="$1"
  # \& : in bash 5.2 a bare & in the replacement means the matched text
  s="${s//&/\&amp;}"; s="${s//</\&lt;}"; s="${s//>/\&gt;}"
  printf '%s' "$s"
}
