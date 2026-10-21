#!/usr/bin/env bash
# Denies `git commit` when the diff being committed carries secrets, a .env file
# or a node_modules path (worktree symlink). Adapted from claude-ops
# ops-prevent-secret-commit. Tests: prevent-secret-commit.test.sh
set -uo pipefail
for _compat in "$(dirname "$(readlink -f "$0")")/../../../bin/lib/compat.sh" "${SYNC_HOME:-$HOME/.agent-sync}/bin/lib/compat.sh"; do [ -f "$_compat" ] && { . "$_compat" || exit 1; break; }; done

MODE=hook
if [ "${1:-}" = --cached ]; then
  MODE=cached
  dir="${2:-}"
  [ -n "$dir" ] || { echo "usage: prevent-secret-commit.sh --cached DIR" >&2; exit 2; }
  add_chain=0
  all_flag=0
  g() { git -C "$dir" "$@" 2>/dev/null; }
else
input="$(cat)"
cmd="$(jq -r '.tool_input.command // empty' <<<"$input")"
cwd="$(jq -r '.cwd // empty' <<<"$input")"
[[ -z "$cmd" ]] && exit 0
[[ -z "$cwd" ]] && cwd="$PWD"

GITOPTS='([[:space:]]+-[Cc][[:space:]]+[^[:space:];&|]+)*'
grep -qE "(^|[;&|(]|[[:space:]])git${GITOPTS}[[:space:]]+commit([[:space:]]|$)" <<<"$cmd" || exit 0

strip_quotes() { sed -E "s/^['\"]//; s/['\"]$//" <<<"$1"; }
dir="$(grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:];&|]+' <<<"$cmd" | head -1 | awk '{print $3}')"
[[ -z "$dir" ]] && dir="$(grep -oE '(^|[;&|(][[:space:]]*)cd[[:space:]]+[^[:space:];&|]+' <<<"$cmd" | head -1 | awk '{print $NF}')"
dir="$(strip_quotes "${dir:-.}")"
dir="${dir/#\~/$HOME}"
[[ "$dir" != /* ]] && dir="$cwd/$dir"
command -v git >/dev/null 2>&1 || exit 0
git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
g() { git -C "$dir" "$@" 2>/dev/null; }

add_chain=0; all_flag=0
fi

if [ "$MODE" = hook ]; then
grep -qE "git${GITOPTS}[[:space:]]+add([[:space:]]|$)" <<<"$cmd" && add_chain=1
grep -qE 'commit[^;&|]*[[:space:]](-[a-zA-Z]*a[a-zA-Z]*|--all)([[:space:]]|$)' <<<"$cmd" && all_flag=1
fi

# "path<TAB>added line" for everything that would land in the commit.
added_lines() {
  local diffs; diffs="$(g diff --cached --no-color -U0 --src-prefix=a/ --dst-prefix=b/)"
  (( add_chain || all_flag )) && diffs+=$'\n'"$(g diff --no-color -U0 --src-prefix=a/ --dst-prefix=b/)"
  awk '/^\+\+\+ b\//{f=substr($0,7);next} /^\+\+\+ /{f="";next} /^\+/&&f!=""{print f"\t"substr($0,2)}' <<<"$diffs"
  if (( add_chain )); then
    g ls-files -o --exclude-standard | head -n 2000 | while IFS= read -r f; do
      local p="$dir/$f"
      [[ -f "$p" && ! -L "$p" ]] || continue
      (( $(stat -c %s "$p") <= 524288 )) || continue
      grep -Iq . "$p" 2>/dev/null || continue
      awk -v f="$f" '{print f"\t"$0}' "$p"
    done
  fi
}

paths() {
  g diff --cached --name-only --diff-filter=ACMR
  if (( add_chain )); then g diff --name-only --diff-filter=ACMR; g ls-files -o --exclude-standard | head -n 2000; fi
}

hits=()
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  base="${p##*/}"
  if [[ "/$p/" == */node_modules/* ]]; then hits+=("node_modules path: $p"); continue; fi
  if [[ "$base" =~ ^\.env($|\.) && ! "$base" =~ \.(example|sample|template|dist)$ ]]; then hits+=(".env file: $p"); fi
done < <(paths | sort -u)

LINES="$(added_lines)"
TEST_PATH='(^|/)(tests?|__tests__|__mocks__|fixtures|spec)/|[.](test|spec)[.][a-zA-Z]+$'
PATTERNS=(
  "all|AWS access key|AKIA[0-9A-Z]{16}"
  "all|GitHub token|gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{60,}"
  "all|Slack token|xox[abposr]-[A-Za-z0-9-]{10,}"
  "all|Stripe key|[sr]k_(live|test)_[A-Za-z0-9]{24,}"
  "all|Anthropic API key|sk-ant-[A-Za-z0-9_-]{20,}"
  "all|OpenAI API key|sk-(proj-)?[A-Za-z0-9]{32,}"
  "all|Private key|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----"
  "src|JWT|eyJ[A-Za-z0-9_=-]{8,}[.]eyJ[A-Za-z0-9_=-]{8,}[.][A-Za-z0-9_=-]*"
  "src|Hardcoded password|(^|[^A-Za-z_-])([Pp]ass(word|wd)|PASS(WORD|WD)|pwd|PWD)[\"']?[[:space:]]*[:=][[:space:]]*['\"][^'\"[:space:]\${]{8,}['\"]"
)
if [[ -n "$LINES" ]]; then
  for entry in "${PATTERNS[@]}"; do
    scope="${entry%%|*}"; rest="${entry#*|}"; label="${rest%%|*}"; regex="${rest#*|}"
    # grep -E, not awk: mawk (Debian default) has no {n} repetition. The tab before the line acts as ^.
    files="$(awk -F'\t' -v tp="$TEST_PATH" -v scope="$scope" 'scope=="src" && $1 ~ tp { next } { print }' <<<"$LINES" \
      | grep -E -- "$regex" | cut -f1 | sort -u | head -5 | paste -sd, -)"
    [[ -n "$files" ]] && hits+=("$label in $files")
  done
fi

if [ "$MODE" = cached ]; then
  (( ${#hits[@]} == 0 )) && exit 0
  printf '%s\n' "${hits[@]}"
  exit 1
fi

(( ${#hits[@]} == 0 )) && exit 0
reason="Blocked git commit: $(IFS=';'; echo "${hits[*]}"). Unstage it (git restore --staged <path>), move the value to a gitignored .env or a creds folder outside the repo, rotate it if it was real. False positive → ask the user to commit it themselves."
jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
