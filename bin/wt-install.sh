#!/usr/bin/env bash
# Own node_modules for a git worktree via pnpm. A pnpm-lock.yaml already in the
# tree is installed as-is. A package-lock.json without one is imported first.
# Replaces the symlink to the main checkout's node_modules.
# CI and the repo do not change: a generated pnpm-lock.yaml goes to info/exclude.
# Usage: wt-install [<worktree>]
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

dir="${1:-$PWD}"
cd "$dir"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "wt-install: $dir — not a git repository" >&2; exit 1; }
[ -f package-lock.json ] || [ -f pnpm-lock.yaml ] \
  || { echo "wt-install: no package-lock.json or pnpm-lock.yaml in $dir" >&2; exit 1; }

if git ls-files --error-unmatch node_modules >/dev/null 2>&1; then
  echo "wt-install: node_modules is tracked in git — skipping"
  exit 0
fi

[ -L node_modules ] && rm node_modules

exclude="$(git rev-parse --git-common-dir)/info/exclude"
mkdir -p "$(dirname "$exclude")"
for f in pnpm-lock.yaml pnpm-workspace.yaml; do
  grep -qxF "$f" "$exclude" 2>/dev/null || echo "$f" >> "$exclude"
done

# pnpm reads allowBuilds only from the project pnpm-workspace.yaml, not from the global config
if ! git ls-files --error-unmatch pnpm-workspace.yaml >/dev/null 2>&1; then
  allow="$(dirname "$(readlink -f "$0")")/pnpm-allow-builds.txt"
  { echo "allowBuilds:"
    grep -v -e '^#' -e '^$' "$allow" | sed -e 's/^!\(.*\)/  "\1": false/' -e 't' -e 's/.*/  "&": true/'
  } > pnpm-workspace.yaml
fi

# @${PROJECT_GIT_ORG}/* packages live in GitHub Packages: the token is taken from gh for the run time,
# ~/.npmrc has only a placeholder (gh needs the read:packages scope)
npmrc_line='//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}'
grep -qxF "$npmrc_line" "$HOME/.npmrc" 2>/dev/null || echo "$npmrc_line" >> "$HOME/.npmrc"
if [ -z "${NODE_AUTH_TOKEN:-}" ]; then
  NODE_AUTH_TOKEN="$(gh auth token 2>/dev/null)" \
    || { echo "wt-install: no token — gh auth refresh -h github.com -s read:packages" >&2; exit 1; }
  export NODE_AUTH_TOKEN
fi

# An existing pnpm-lock.yaml is the lock. Do not delete it.
# package-lock.json alone is imported into a new pnpm lock for this worktree.
if ! command -v pnpm >/dev/null 2>&1; then
  echo "pnpm missing: run bin/tools-check.sh --install" >&2
  exit 1
fi
if [ ! -f pnpm-lock.yaml ]; then
  pnpm import
fi
# hoisted — a flat node_modules like npm, otherwise what is green in CI fails locally
pnpm install --frozen-lockfile --config.node-linker=hoisted
