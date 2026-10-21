#!/usr/bin/env bash
# Keeps the laptop awake while the agent works, but only on battery:
# on mains power the system is usually set up as the user wants, and an extra
# sleep lock is the kind of thing you hunt for half a day later.
#
#   keep-awake.sh acquire <session-id>   take the lock (agent is working)
#   keep-awake.sh release <session-id>   release it (agent waits for input)
#
# The holder is a background systemd-inhibit (caffeinate on macOS): the hook lives for seconds, but the
# lock must live as long as the work goes on.
set -u
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

STATE_DIR="${AWAKE_STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/claude-herdr-meta}"
TTL_MIN="${KEEP_AWAKE_TTL_MINUTES:-180}"
if [ "$AGENT_SYNC_OS" = darwin ]; then INHIBIT_BIN="${INHIBIT_BIN:-caffeinate}"
else INHIBIT_BIN="${INHIBIT_BIN:-systemd-inhibit}"; fi

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
pidfile() { printf '%s/awake-%s.pid' "$STATE_DIR" "${1//[^A-Za-z0-9-]/_}"; }

on_battery() {
  [ "${KEEP_AWAKE_ALWAYS:-}" = 1 ] && return 0
  case "$(agent_sync_power)" in battery*) return 0 ;; esac
  return 1
}

drop() { # drop <pid-file>
  local f="$1" pid
  [ -f "$f" ] || return 0
  pid="$(cat "$f" 2>/dev/null)"
  # only the PID from the file, never pkill by pattern
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  rm -f "$f"
}

# A session may die in an unclean way; an abandoned lock would keep the
# laptop awake forever.
sweep_stale() {
  local f
  for f in "$STATE_DIR"/awake-*.pid; do
    [ -f "$f" ] || continue
    if [ -n "$(find "$f" -mmin +"$TTL_MIN" 2>/dev/null)" ]; then
      drop "$f"
      continue
    fi
    kill -0 "$(cat "$f" 2>/dev/null)" 2>/dev/null || rm -f "$f"
  done
}

case "${1:-}" in
  acquire)
    sid="${2:?session id required}"
    sweep_stale
    on_battery || exit 0
    command -v "$INHIBIT_BIN" >/dev/null 2>&1 || exit 0
    f="$(pidfile "$sid")"
    if [ -f "$f" ] && kill -0 "$(cat "$f" 2>/dev/null)" 2>/dev/null; then
      exit 0                      # already held
    fi
    if [ "$AGENT_SYNC_OS" = darwin ]; then
      "$INHIBIT_BIN" -i >/dev/null 2>&1 &   # idle sleep; caffeinate runs until killed
    else
      "$INHIBIT_BIN" --what=idle:sleep --who="claude" \
        --why="agent is working, running on battery" --mode=block \
        sleep infinity >/dev/null 2>&1 &
    fi
    printf '%s\n' "$!" > "$f"
    ;;
  release)
    drop "$(pidfile "${2:?session id required}")"
    ;;
  *)
    echo "commands: acquire <id> | release <id>" >&2
    exit 2
    ;;
esac
exit 0
