#!/usr/bin/env bash
# Fast-forward every primary checkout under PROJECT_ROOT onto origin/$PROJECT_BASE_BRANCH.
# Skips a repo with uncommitted tracked edits, a diverged local base branch, or no origin/<branch>.
# A detached HEAD that holds commits not on any branch is skipped: checkout would leave them in the reflog only.
# Usage: project-develop [--dry-run] [repo...]   no repo = every git repo in $PROJECT_ROOT
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/project-env.sh" || exit 1
root="${PROJECT_ROOT%/}"
base="${PROJECT_BASE_BRANCH:-main}"
usage() { echo "usage: project-develop [--dry-run] [repo...]" >&2; exit 2; }

dry=0
repos=()
for a in "$@"; do
  case "$a" in
    -n|--dry-run) dry=1 ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) repos+=("${a%/}") ;;
  esac
done

if [ ${#repos[@]} -eq 0 ]; then
  # a .git directory, not a file: worktrees under .worktrees/ are left alone
  for d in "$root"/*/; do
    [ -d "$d.git" ] && repos+=("$(basename "$d")")
  done
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for r in "${repos[@]}"; do
  if [ ! -d "$root/$r/.git" ]; then
    echo "not a primary checkout" >"$tmp/$r.err"
    continue
  fi
  ( git -C "$root/$r" fetch -q origin "$base" 2>"$tmp/$r.err" && rm -f "$tmp/$r.err" ) &
done
wait

failed=0
row() { printf '%-28s %-8s %s\n' "$1" "$2" "$3"; }
skip() { row "$1" SKIP "$2"; failed=1; }

for r in "${repos[@]}"; do
  dir="$root/$r"
  g() { git -C "$dir" "$@"; }

  if [ -f "$tmp/$r.err" ]; then
    skip "$r" "fetch: $(head -1 "$tmp/$r.err")"
    continue
  fi
  if ! g rev-parse -q --verify "origin/$base" >/dev/null; then
    skip "$r" "no origin/$base"
    continue
  fi

  branch="$(g symbolic-ref --short -q HEAD || echo DETACHED)"
  if [ -n "$(g status --porcelain -uno)" ]; then
    skip "$r" "uncommitted changes on $branch"
    continue
  fi
  if g rev-parse -q --verify "refs/heads/$base" >/dev/null \
     && ! g merge-base --is-ancestor "$base" "origin/$base"; then
    skip "$r" "local $base diverged: $(g rev-list --count "origin/$base".."$base") commits not on origin"
    continue
  fi

  behind="$(g rev-list --count HEAD.."origin/$base")"
  note=""
  if [ "$branch" = DETACHED ] && [ "$(g rev-list --count HEAD --not --remotes --branches)" -gt 0 ]; then
    skip "$r" "detached HEAD with commits not in any branch"
    continue
  fi
  if [ "$branch" != "$base" ]; then
    unpushed="$(g rev-list --count HEAD --not --remotes)"
    note="from $branch"
    [ "$unpushed" -gt 0 ] && note="$note ($unpushed unpushed, kept in branch)"
  fi

  # base branch checked out in another worktree: git will not check it out twice.
  # A clean worktree is removed so the branch lives in the primary checkout.
  holder="$(g worktree list --porcelain | awk -v b="branch refs/heads/$base" '/^worktree /{p=substr($0,10)} $0==b{print p}')"
  if [ -n "$holder" ] && [ "$holder" != "$dir" ]; then
    if [ -n "$(git -C "$holder" status --porcelain -uno)" ]; then
      skip "$r" "$base is held by ${holder#"$root"/} with uncommitted changes"
      continue
    fi
    note="$note; removes worktree ${holder#"$root"/}"
    if [ "$dry" -eq 0 ] && ! out="$(g worktree remove "$holder" 2>&1)"; then
      skip "$r" "worktree remove ${holder#"$root"/}: $(head -1 <<<"$out")"
      continue
    fi
  fi

  if [ "$dry" -eq 1 ]; then
    row "$r" PLAN "+$behind ${note#; }"
    continue
  fi

  before="$(g rev-parse HEAD)"
  if [ "$branch" != "$base" ]; then
    if g rev-parse -q --verify "refs/heads/$base" >/dev/null; then
      out="$(g checkout -q "$base" 2>&1)"
    else
      out="$(g checkout -q -b "$base" --track "origin/$base" 2>&1)"
    fi
    if [ $? -ne 0 ]; then
      skip "$r" "checkout $base: $(head -1 <<<"$out")"
      continue
    fi
  fi
  if ! out="$(g merge -q --ff-only "origin/$base" 2>&1)"; then
    skip "$r" "ff-only: $(head -1 <<<"$out")"
    continue
  fi

  changed="$(g diff --name-only "$before" HEAD)"
  grep -qE '(^|/)(package\.json|pnpm-lock\.yaml|package-lock\.json|composer\.(json|lock))$' <<<"$changed" \
    && note="$note; deps changed — reinstall"
  grep -qE '(^|/)migrations/' <<<"$changed" && note="$note; new migrations"
  row "$r" OK "+$(g rev-list --count "$before"..HEAD) ${note#; }"
done

exit "$failed"
