#!/usr/bin/env bash
# Blocks Edit/Write/NotebookEdit on tracked files sitting directly in a repo's
# PRIMARY checkout under $PROJECT_ROOT (the one whose .git is a real
# directory, not a worktree pointer file). Forces work into a git worktree
# instead, so a session never leaves uncommitted changes in a checkout other
# sessions treat as shared/clean.
set -euo pipefail
for _compat in "$(dirname "$(readlink -f "$0")")/../../../bin/lib/compat.sh" "${SYNC_HOME:-$HOME/.agent-sync}/bin/lib/compat.sh"; do [ -f "$_compat" ] && { . "$_compat" || exit 1; break; }; done

_here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
for _l in "$_here/../../../bin/lib/project-env.sh" "$HOME/.agent-sync/bin/lib/project-env.sh"; do
  [ -f "$_l" ] && { . "$_l"; break; }
done
PROJECT_PREFIX="${PROJECT_ROOT%/}"

input="$(cat)"
file_path="$(jq -r '.tool_input.file_path // empty' <<<"$input")"
[ -z "$file_path" ] && exit 0

case "$file_path" in
  "$PROJECT_PREFIX"/*) ;;
  *) exit 0 ;;
esac

# Find the repo root: first path component after $PROJECT_ROOT.
rel="${file_path#$PROJECT_PREFIX/}"
repo_dir="$PROJECT_PREFIX/${rel%%/*}"

git_marker="$repo_dir/.git"

# Not a git checkout at all (loose files, dumps, etc.) -> nothing to enforce.
[ -e "$git_marker" ] || exit 0

# A worktree's .git is a FILE pointing at the common gitdir; the primary
# checkout's .git is a real directory. Only block the primary checkout.
if [ -d "$git_marker" ]; then
  cat <<EOF
{
  "continue": false,
  "stopReason": "Editing tracked files directly in the primary checkout ($repo_dir) is blocked. This checkout is shared across sessions and left-over uncommitted changes there block everyone else's git checkout. Create a worktree first with wt-new, then edit inside that worktree.",
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Direct edit in primary checkout $repo_dir — use wt-new."
  }
}
EOF
  exit 0
fi

exit 0
