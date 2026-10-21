#!/usr/bin/env bash
# Denies direct `git worktree add|move` (and Claude EnterWorktree create) when the
# effective repo is under $PROJECT_ROOT (agent-sync.env). Agents must use `wt-new`.
# Tests: project-worktree-via-wt-new.test.sh
set -euo pipefail
for _compat in "$(dirname "$(readlink -f "$0")")/../../../bin/lib/compat.sh" "${SYNC_HOME:-$HOME/.agent-sync}/bin/lib/compat.sh"; do [ -f "$_compat" ] && { . "$_compat" || exit 1; break; }; done

_here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
for _l in "$_here/../../../bin/lib/project-env.sh" "$HOME/.agent-sync/bin/lib/project-env.sh"; do
  [ -f "$_l" ] && { . "$_l"; break; }
done
PROJECT_PREFIX="${PROJECT_ROOT%/}"
REASON='Use `wt-new <repo> <task> --branch <branch>` — it creates the worktree under '"$PROJECT_PREFIX"'/.worktrees/ and prints its path'

input="$(cat)"

tool_name="$(jq -r '.tool_name // empty' <<<"$input")"
# Claude: tool_input.command; Cursor beforeShellExecution: top-level command
command="$(jq -r '.tool_input.command // .command // empty' <<<"$input")"
cwd="$(jq -r '.cwd // empty' <<<"$input")"
[ -z "$cwd" ] && cwd="$PWD"

is_project_path() {
  case "$1" in
    "$PROJECT_PREFIX"|"$PROJECT_PREFIX"/*) return 0 ;;
    *) return 1 ;;
  esac
}

deny() {
  # Cursor beforeShellExecution (top-level command, no tool_input)
  if jq -e 'has("command") and (has("tool_input") | not)' >/dev/null 2>&1 <<<"$input"; then
    jq -n --arg r "$REASON" '{permission:"deny",user_message:$r,agent_message:$r}'
  else
    # Claude PreToolUse: deny permission only — no continue/stopReason (agent should retry with wt-new)
    jq -n --arg r "$REASON" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  fi
  exit 0
}

if [[ "$tool_name" == "EnterWorktree" ]]; then
  path="$(jq -r '.tool_input.path // empty' <<<"$input")"
  # With path — entering an existing worktree (e.g. after wt-new). Without — Claude creates one.
  if [[ -z "$path" ]] && is_project_path "$cwd"; then
    deny
  fi
  exit 0
fi

[ -z "$command" ] && exit 0

strip_quotes() { sed -E "s/^['\"]//; s/['\"]$//" <<<"$1"; }

# Drop heredoc bodies so phrases inside them are not treated as commands.
command_scan="$(python3 -c '
import re, sys
s = sys.stdin.read()
print(re.sub(r"<<-?\s*([\"'\'']?)(\w+)\1\n.*?\n\2\s*(?:\n|$)", "\n", s, flags=re.S))
' <<<"$command")"

# True if a shell segment starts with git … worktree add|move (global opts allowed).
# Ignores the phrase inside quotes / heredoc bodies that are not their own segment start.
segment_is_wt_mutation() {
  local seg="$1"
  # Drop leading env assignments and optional `env …`
  while [[ "$seg" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*[[:space:]]+|env[[:space:]]+[^[:space:];&|]+[[:space:]]+) ]]; do
    seg="${seg#"${BASH_REMATCH[0]}"}"
  done
  seg="${seg#"${seg%%[![:space:]]*}"}"
  [[ "$seg" == git[[:space:]]* ]] || return 1
  # git [global-opts…] worktree add|move
  grep -qE '^git([[:space:]]+(-c[[:space:]]+[^[:space:]]+|-C[[:space:]]+[^[:space:]]+|--[a-z][a-z0-9-]*=[^[:space:]]+|--[a-z][a-z0-9-]*))*[[:space:]]+worktree[[:space:]]+(add|move)([[:space:]]|$)' <<<"$seg"
}

# Split on ; && || | and newlines — keep only top-level segments (rough).
# Prefix = segments before the first worktree add/move (cd after mutation is ignored).
has_mutation=0
mutation_seg=""
prefix=""
while IFS= read -r seg; do
  seg="${seg#"${seg%%[![:space:]]*}"}"  # ltrim
  [ -z "$seg" ] && continue
  if segment_is_wt_mutation "$seg"; then
    has_mutation=1
    mutation_seg="$seg"
    break
  fi
  prefix+="${seg}"$'\n'
done < <(printf '%s\n' "$command_scan" | sed -E 's/\&\&|\;|\|\||\|/\n/g')

[ "$has_mutation" -eq 1 ] || exit 0

# Effective dir: last git -C in the mutation segment, else last cd in prefix, else cwd
eff=""
while IFS= read -r d; do
  [ -n "$d" ] && eff="$d"
done < <(grep -oE -- '-C[[:space:]]+[^[:space:];&|]+' <<<"$mutation_seg" | awk '{print $2}' || true)

if [ -z "$eff" ]; then
  while IFS= read -r d; do
    [ -n "$d" ] && eff="$d"
  done < <(grep -oE -- '(^|[;&|(][[:space:]]*)cd[[:space:]]+[^[:space:];&|]+' <<<"$prefix" \
    | awk '{print $NF}' || true)
fi

eff="$(strip_quotes "${eff:-.}")"
eff="${eff/#\~/$HOME}"
[[ "$eff" != /* ]] && eff="$cwd/$eff"

if command -v realpath >/dev/null 2>&1; then
  eff="$(realpath -m "$eff" 2>/dev/null || echo "$eff")"
fi

if is_project_path "$eff"; then
  deny
fi

exit 0
