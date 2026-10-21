#!/usr/bin/env bash
# Sync of Claude Code session history between machines through the home server.
#
# Transcripts are append-only and unique by session uuid, so rsync in both
# directions without deletion is enough; a separate sync daemon is not needed.
# They do not go into git: git would store every version of a file in full.
set -uo pipefail

SRC="${HISTORY_SRC:-$HOME/.claude/projects}"
. "$(dirname "$(readlink -f "$0")")/lib/project-env.sh" || exit 1
REMOTE="$HISTORY_REMOTE"
# No server configured (SYNC_SERVER empty): history stays local, nothing to do.
[ -n "$REMOTE" ] || exit 0
# Claude cleans transcripts older than 30 days by itself. We pull from the server only what
# falls into this window, otherwise deleted files would come back on every sync.
MAX_AGE="${HISTORY_MAX_AGE_DAYS:-30}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"

warn() { printf '%s\n' "$*" >&2; }

# host:path is a server over ssh; anything else is treated as a local directory
remote_host=''; remote_path="$REMOTE"
if [[ "$REMOTE" == *:* ]]; then
  remote_host="${REMOTE%%:*}"
  remote_path="${REMOTE#*:}"
fi

ssh_() { ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$remote_host" "$@"; }

# Prepares the receiver and also checks that the server is reachable at all
ensure_remote() {
  if [ -n "$remote_host" ]; then
    ssh_ "mkdir -p '$remote_path'" 2>/dev/null
  else
    mkdir -p "$remote_path" 2>/dev/null
  fi
}

# List of transcripts on the server that fall into the MAX_AGE window (relative paths)
remote_recent() {
  local find_cmd="find '$remote_path' -type f -name '*.jsonl' -mtime -$MAX_AGE -printf '%P\n'"
  if [ -n "$remote_host" ]; then ssh_ "$find_cmd" 2>/dev/null
  else eval "$find_cmd" 2>/dev/null; fi
}

mkdir -p "$SRC"

if ! ensure_remote; then
  warn "history server unreachable, sync skipped"
  exit 0
fi

# Up: everything local. --update keeps the newer version on the receiver,
# no --delete guarantees that nothing disappears on either side.
rsync -a --update --timeout=60 \
  --include='*/' --include='*.jsonl' --exclude='*' \
  --prune-empty-dirs \
  ${remote_host:+-e "ssh -o BatchMode=yes -o ConnectTimeout=$SSH_TIMEOUT"} \
  "$SRC/" "$REMOTE/" 2>/dev/null \
  || warn "could not send the history to the server"

# Down: only what is younger than MAX_AGE, otherwise old files that Claude cleaned would come back
list="$(mktemp)"
remote_recent > "$list"
if [ -s "$list" ]; then
  rsync -a --update --timeout=60 --files-from="$list" \
    ${remote_host:+-e "ssh -o BatchMode=yes -o ConnectTimeout=$SSH_TIMEOUT"} \
    "$REMOTE/" "$SRC/" 2>/dev/null \
    || warn "could not fetch the history from the server"
fi
rm -f "$list"

exit 0
