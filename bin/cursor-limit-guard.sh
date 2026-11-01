#!/usr/bin/env bash
# Cursor has its own quota. limit-guard.sh reads the Claude subscription cache,
# so this hook stays silent instead of feeding those numbers to a Cursor agent.
set -u
cat >/dev/null
exit 0
