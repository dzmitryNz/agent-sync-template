#!/usr/bin/env bash
# Tests for project-worktree-via-wt-new.sh. Run: ./project-worktree-via-wt-new.test.sh
set -uo pipefail

HOOK="$(dirname "$(readlink -f "$0")")/project-worktree-via-wt-new.sh"
fail=0

export PROJECT_ROOT=/srv/proj
PROJ=$PROJECT_ROOT
SVC="$PROJ/svc-a"

run_claude() { # $1=cwd $2=command [$3=tool_name] [$4=path for EnterWorktree]
  local tool="${3:-Bash}"
  if [[ "$tool" == "EnterWorktree" ]]; then
    if [[ -n "${4:-}" ]]; then
      jq -n --arg d "$1" --arg t "$tool" --arg p "$4" \
        '{tool_name:$t,cwd:$d,tool_input:{path:$p}}' | "$HOOK"
    else
      jq -n --arg d "$1" --arg t "$tool" '{tool_name:$t,cwd:$d,tool_input:{}}' | "$HOOK"
    fi
  else
    jq -n --arg c "$2" --arg d "$1" --arg t "$tool" \
      '{tool_name:$t,cwd:$d,tool_input:{command:$c}}' | "$HOOK"
  fi
}

run_cursor() { # $1=cwd $2=command
  jq -n --arg c "$2" --arg d "$1" '{command:$c,cwd:$d}' | "$HOOK"
}

claude_decision() {
  jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$1" 2>/dev/null
}

cursor_permission() {
  jq -r '.permission // empty' <<<"$1" 2>/dev/null
}

expect_claude() { # $1=deny|allow $2=name $3=cwd $4=command [$5=tool] [$6=path]
  local out; out="$(run_claude "$3" "$4" "${5:-Bash}" "${6:-}")"
  local got=allow
  [[ "$(claude_decision "$out")" == deny ]] && got=deny
  if [[ "$got" == "$1" ]]; then echo "ok   $2"; else echo "FAIL $2 (expected $1, got $got) $out"; fail=1; fi
}

expect_cursor() { # $1=deny|allow $2=name $3=cwd $4=command
  local out; out="$(run_cursor "$3" "$4")"
  local got=allow
  [[ "$(cursor_permission "$out")" == deny ]] && got=deny
  if [[ "$got" == "$1" ]]; then echo "ok   $2"; else echo "FAIL $2 (expected $1, got $got) $out"; fail=1; fi
}

expect_claude_deny_shape() { # name cwd command — Claude deny must not stop the agent
  local out; out="$(run_claude "$2" "$3")"
  local ok=1
  [[ "$(claude_decision "$out")" == deny ]] || ok=0
  [[ "$(jq -r '.continue // empty' <<<"$out")" == "" ]] || ok=0
  [[ "$(jq -r '.stopReason // empty' <<<"$out")" == "" ]] || ok=0
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<<"$out")" != "" ]] || ok=0
  if [[ "$ok" -eq 1 ]]; then echo "ok   $1"; else echo "FAIL $1 (bad deny shape) $out"; fail=1; fi
}

# 1 — cwd in project repo, relative worktree add
expect_claude deny "1 cwd git worktree add" "$SVC" "git worktree add ../x -b feat/x"

# 2 — any cwd, git -C project worktree add
expect_claude deny "2 git -C project worktree add" /tmp \
  "git -C $SVC worktree add /tmp/r origin/pr"

# 3 — worktree move in project
expect_claude deny "3 git worktree move" "$SVC" "git worktree move a b"

# 4 — non-project repo allowed
expect_claude allow "4 non-project worktree add" /tmp/other-repo "git worktree add /tmp/foo"

# 5 — list / remove / wt-new allowed in project
expect_claude allow "5a worktree list" "$SVC" "git worktree list"
expect_claude allow "5b worktree remove" "$SVC" "git worktree remove /tmp/x"
expect_claude allow "5c wt-new" "$SVC" "wt-new svc x --branch y"

# 6 — Cursor format of case 2
expect_cursor deny "6 Cursor git -C worktree add" /tmp \
  "git -C $SVC worktree add /tmp/r origin/pr"

# 7 — EnterWorktree: deny only without path (create); with path — allow (enter)
expect_claude deny "7 EnterWorktree create in project" "$SVC" "" "EnterWorktree"
expect_claude allow "7b EnterWorktree outside project" /tmp/elsewhere "" "EnterWorktree"
expect_claude allow "7c EnterWorktree with path in project" "$SVC" "" "EnterWorktree" \
  "$PROJ/.worktrees/api-x"

# deny shape for Claude — no continue/stopReason
expect_claude_deny_shape "deny shape Claude" "$SVC" "git worktree add ../x -b feat/x"

# Quoted / narrative mentions must not deny
expect_claude allow "quote commit -m" "$SVC" \
  'git commit -m "block git worktree add under project"'
expect_claude allow "quote echo" "$SVC" 'echo "git worktree add ../x"'
expect_claude allow "quote heredoc" "$SVC" \
  "cat <<'EOF'
git worktree add ../x
EOF"

# Global git options
expect_claude deny "git --no-pager worktree add" "$SVC" \
  "git --no-pager worktree add ../x -b feat/x"
expect_claude deny "git -c -C worktree add" /tmp \
  "git -c foo=bar -C $SVC worktree add /tmp/r origin/pr"

# Last cd in chain
expect_claude deny "cd chain last project" /tmp \
  "cd /tmp/other && cd $SVC && git worktree add ../x -b feat/x"
expect_claude allow "cd chain last non-project" /tmp \
  "cd $SVC && cd /tmp/other && git worktree add /tmp/foo"

# cd after mutation must not override cwd — Review 2
expect_claude deny "cd after worktree add ignored" "$SVC" \
  "git worktree add /tmp/wt-x -b x && cd /tmp/wt-x"

exit $fail
