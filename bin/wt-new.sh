#!/usr/bin/env bash
# A worktree for a task with one command: fetch, path .worktrees/<short>-<task>, branch, dependencies.
# The last stdout line is the worktree path.
# Usage: wt-new <repo> <task> [--branch <name>] [--base <branch>] [--at <sha|ref>] [--env]
#   --branch  exists locally or on origin — it is used; otherwise a new one from origin/<base>
#             without --branch and --at — detached at origin/<base> (baseline, test runs)
#   --at      detached worktree at a commit/ref (after fetch). Incompatible with --branch
#   --env     copy .env* from the main checkout (a copied .env can point at a shared remote cache)
set -euo pipefail

here="$(dirname "$(readlink -f "$0")")"
. "$here/lib/project-env.sh" || exit 1
root="${PROJECT_ROOT%/}"
short_names_file="${WT_SHORT_NAMES_FILE:-$here/wt-short-names.conf}"
usage() { echo "usage: wt-new <repo> <task> [--branch <name>] [--base <default branch>] [--at <sha|ref>] [--env]" >&2; exit 2; }

[ $# -ge 2 ] || usage
repo_arg="$1" task="$2"; shift 2
branch="" base="$PROJECT_BASE_BRANCH" at_ref="" copy_env=0
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) [ $# -ge 2 ] || usage; branch="$2"; shift 2 ;;
    --base)   [ $# -ge 2 ] || usage; base="$2"; shift 2 ;;
    --at)     [ $# -ge 2 ] || usage; at_ref="$2"; shift 2 ;;
    --env)    copy_env=1; shift ;;
    *) usage ;;
  esac
done

if [ -n "$at_ref" ] && [ -n "$branch" ]; then
  usage
fi

case "$repo_arg" in /*) repo="$repo_arg" ;; *) repo="$root/$repo_arg" ;; esac
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
  || { echo "wt-new: $repo — not a git repository" >&2; exit 1; }

# Canonical paths for comparing worktree list entries to the primary checkout.
repo_real="$(cd "$repo" && pwd -P)"

name="$(basename "$repo")"
short=""
if [ -f "$short_names_file" ]; then
  short="$(sed -E -n "s/^[[:space:]]*$(printf %s "$name" | sed 's/[][\.*^$/]/\\&/g')[[:space:]]*=[[:space:]]*([^[:space:]#]+).*/\\1/p" "$short_names_file" | head -1)"
fi
short="${short:-$name}"
wt="$root/.worktrees/$short-$task"

fetch_for_at() {
  case "$at_ref" in
    refs/pull/*)
      git -C "$repo" fetch -q origin "+${at_ref}:${at_ref}"
      ;;
    *)
      git -C "$repo" fetch -q origin
      ;;
  esac
}

if git -C "$repo" worktree list --porcelain | grep -qxF "worktree $wt"; then
  if [ -n "$at_ref" ]; then
    fetch_for_at
    if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      echo "wt-new: $wt has a dirty worktree; clean it or remove the worktree before --at" >&2
      exit 1
    fi
    git -C "$wt" checkout -q --detach "$at_ref"
    echo "$wt"
    exit 0
  fi
  if [ -n "$branch" ]; then
    cur="$(git -C "$wt" branch --show-current 2>/dev/null || true)"
    if [ -n "$cur" ] && [ "$cur" != "$branch" ]; then
      echo "wt-new: $wt is on $cur, not $branch" >&2
    fi
  fi
  echo "$wt"
  exit 0
fi

# Branch already checked out elsewhere.
if [ -n "$branch" ]; then
  busy_path=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) busy_path="${line#worktree }" ;;
      "branch refs/heads/$branch")
        if [ -n "$busy_path" ] && [ "$busy_path" != "$wt" ]; then
          busy_real="$(cd "$busy_path" 2>/dev/null && pwd -P || echo "$busy_path")"
          if [ "$busy_real" = "$repo_real" ]; then
            echo "wt-new: branch $branch is checked out in the primary checkout ($busy_path)." >&2
            echo "wt-new: use --at <sha|refs/pull/N/head> for a detached review copy, not --branch." >&2
            exit 1
          fi
          echo "wt-new: branch $branch already checked out at $busy_path" >&2
          echo "$busy_path"
          exit 0
        fi
        ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain)
fi

if [ -n "$at_ref" ]; then
  fetch_for_at
else
  git -C "$repo" fetch -q origin
fi
mkdir -p "$root/.worktrees"
if [ -n "$at_ref" ]; then
  git -C "$repo" worktree add -q --detach "$wt" "$at_ref"
elif [ -z "$branch" ]; then
  git -C "$repo" show-ref -q --verify "refs/remotes/origin/$base" \
    || { echo "wt-new: origin/$base does not exist. set PROJECT_BASE_BRANCH in agent-sync.env" >&2; exit 1; }
  git -C "$repo" worktree add -q --detach "$wt" "origin/$base"
elif git -C "$repo" show-ref -q --verify "refs/heads/$branch"; then
  git -C "$repo" worktree add -q "$wt" "$branch"
elif git -C "$repo" show-ref -q --verify "refs/remotes/origin/$branch"; then
  git -C "$repo" worktree add -q --track -b "$branch" "$wt" "origin/$branch"
else
  git -C "$repo" show-ref -q --verify "refs/remotes/origin/$base" \
    || { echo "wt-new: origin/$base does not exist. set PROJECT_BASE_BRANCH in agent-sync.env" >&2; exit 1; }
  git -C "$repo" worktree add -q --no-track -b "$branch" "$wt" "origin/$base"
fi

if [ "$copy_env" = 1 ]; then
  for f in "$repo"/.env*; do
    [ -f "$f" ] || continue
    git -C "$repo" ls-files --error-unmatch "$(basename "$f")" >/dev/null 2>&1 && continue
    cp "$f" "$wt/"
  done
fi

# pnpm output is hundreds of lines in the agent context; it goes to a log, only the tail is shown on error
if [ -f "$wt/package.json" ]; then
  if [ ! -f "$wt/package-lock.json" ] && [ ! -f "$wt/pnpm-lock.yaml" ]; then
    echo "wt-new: no package-lock.json or pnpm-lock.yaml, skipped dependency install" >&2
  else
    log="$(git -C "$wt" rev-parse --absolute-git-dir)/wt-install.log"
    if ! "$(dirname "$(readlink -f "$0")")/wt-install.sh" "$wt" >"$log" 2>&1; then
      tail -20 "$log" >&2
      echo "wt-new: install failed, full log: $log" >&2
      exit 1
    fi
  fi
fi

echo "$wt"
