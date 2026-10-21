#!/usr/bin/env bash
# Prints the last block of a role reply from the pane screen: from the `[… RESULT]` marker
# to the end. No marker — empty stdout, exit 1.
# Usage: herdr-pane-reply <pane_id>   (local pane; not for remote)
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

[ $# -ge 1 ] || { echo "usage: herdr-pane-reply <pane_id>" >&2; exit 2; }
pane="$1"

[ "$AGENT_SYNC_OS" = darwin ] || export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
screen="$(herdr pane read "$pane" --source recent-unwrapped --lines 200 2>/dev/null || true)"

# A Claude pane may prefix the line (❯ / ● …"); allow up to 6 non-[ chars before marker.
marker_line="$(grep -nE '^[^[]{0,6}\[[A-Z][A-Z0-9_-]* RESULT\]' <<<"$screen" | tail -1 | cut -d: -f1 || true)"
if [ -z "${marker_line:-}" ]; then
  exit 1
fi
tail -n "+$marker_line" <<<"$screen"
