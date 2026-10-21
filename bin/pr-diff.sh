#!/usr/bin/env bash
# PR diff in parts: without files — a list of +adds -dels path (generated skipped);
# with files — the full `gh pr diff`, sections of the needed files are cut out with awk
# (gh has no path filter: accepts at most 1 arg).
# Usage: pr-diff <repo> <n> [file…]
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

[ $# -ge 2 ] || { echo "usage: pr-diff <repo> <n> [file…]" >&2; exit 2; }
repo="$1" n="$2"; shift 2
if [[ "$repo" != */* ]]; then
  # shellcheck disable=SC1091
  . "$(dirname "$(readlink -f "$0")")/lib/project-env.sh" || exit 1
  repo="${PROJECT_GIT_ORG}/$repo"
fi

is_generated() {
  local p="$1" base="${1##*/}"
  case "$base" in
    package-lock.json|pnpm-lock.yaml|pnpm-lock.yml) return 0 ;;
  esac
  [[ "$base" == pnpm-lock* ]] && return 0
  [[ "$base" == new_schema*.sql ]] && return 0
  [[ "$p" == *__snapshots__* ]] && return 0
  [[ "$p" == dist/* || "$p" == */dist/* ]] && return 0
  return 1
}

if [ $# -eq 0 ]; then
  json="$(gh pr view "$n" --repo "$repo" --json files)"
  while IFS=$'\t' read -r adds dels path; do
    [ -z "$path" ] && continue
    if is_generated "$path"; then
      printf '+%s -%s %s (generated, skipped)\n' "$adds" "$dels" "$path"
    else
      printf '+%s -%s %s\n' "$adds" "$dels" "$path"
    fi
  done < <(jq -r '
    .files
    | map({path, additions:(.additions//0), deletions:(.deletions//0),
           size:((.additions//0)+(.deletions//0))})
    | sort_by(-.size)
    | .[]
    | [.additions, .deletions, .path]
    | @tsv' <<<"$json")
  exit 0
fi

want="$(mktemp)"
found="$(mktemp)"
trap 'rm -f "$want" "$found"' EXIT
printf '%s\n' "$@" >"$want"
: >"$found"

gh pr diff "$n" --repo "$repo" | awk -v foundf="$found" '
FNR == NR { want[$0] = 1; next }
/^diff --git / {
  keep = 0
  a = $3; sub(/^a\//, "", a)
  b = $4; sub(/^b\//, "", b)
  if (a in want) { keep = 1; print a >> foundf }
  if (b in want) { keep = 1; print b >> foundf }
}
keep { print }
' "$want" -

missing=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if ! grep -Fxq -- "$f" "$found"; then
    echo "pr-diff: no diff section for $f" >&2
    missing=1
  fi
done <"$want"
[ "$missing" -eq 0 ]
