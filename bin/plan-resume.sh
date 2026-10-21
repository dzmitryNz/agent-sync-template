#!/usr/bin/env bash
# SessionStart hook: after /clear it points the agent to its task plan. The plan is found by the
# line `**Herdr space:** <name>` — the name of the current herdr space where the session lives.
# Space names and plan file names do not match, so the plan declares its space itself.
set -u
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

PLANS_DIR="$HOME/.claude/plans"

payload="$(cat 2>/dev/null)"
[ "$(jq -r '.source // empty' <<<"$payload" 2>/dev/null)" = clear ] || exit 0
[ -n "${HERDR_WORKSPACE_ID:-}" ] || exit 0
command -v herdr >/dev/null 2>&1 || exit 0

label="$(herdr workspace list 2>/dev/null \
  | jq -r --arg id "$HERDR_WORKSPACE_ID" \
      '.result.workspaces[]? | select(.workspace_id == $id) | .label' 2>/dev/null)"
[ -n "$label" ] || exit 0

mapfile -t plans < <(grep -lxF -e "**Herdr space:** $label" -e "**Herdr space:** \`$label\`" \
  "$PLANS_DIR"/*.md 2>/dev/null)
[ "${#plans[@]}" -gt 0 ] || exit 0

if [ "${#plans[@]}" -eq 1 ]; then
  cat <<EOF
[agent-sync] Session cleared via /clear in herdr space "$label". Task plan:
${plans[0]}
Read it first: it has the status, PR, worktree and the next step.
EOF
else
  printf '[agent-sync] Session cleared via /clear in herdr space "%s". This space is named in several plans:\n' "$label"
  printf '%s\n' "${plans[@]}"
  printf 'Read the one with status "in progress", or ask the user which to continue.\n'
fi
exit 0
