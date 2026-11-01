#!/usr/bin/env bash
# Cursor pane metadata: same fields herdr-pane-meta.sh sets for Claude.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/bin/cursor-pane-meta.sh"
META="$ROOT/store/.claude/hooks/herdr-pane-meta.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "not satisfied: $*"; fi; }

setup() {
  TMP="$(mktemp -d)"
  export XDG_RUNTIME_DIR="$TMP/run"
  export HERDR_ENV=1 HERDR_PANE_ID="w9:p1" HERDR_TAB_ID="w9:t1" HERDR_WORKSPACE_ID=w9
  export HERDR_PANE_META="$META"
  export LIMIT_PACE_BIN="$ROOT/bin/limit-pace.sh"
  mkdir -p "$TMP/bin" "$XDG_RUNTIME_DIR/claude-herdr-meta"

  cat > "$TMP/bin/herdr" <<EOF
#!/usr/bin/env bash
if [ "\$1" = workspace ] && [ "\$2" = get ]; then
  printf '{"result":{"workspace":{"label":"demo-app"}}}'
  exit 0
fi
if [ "\$1" = agent ] && [ "\$2" = list ]; then
  printf '{"result":{"agents":[]}}'
  exit 0
fi
printf '%s' "\$1" >> "$TMP/herdr.log"
shift
for a in "\$@"; do printf '\t%s' "\$a" >> "$TMP/herdr.log"; done
printf '\n' >> "$TMP/herdr.log"
exit 0
EOF
  chmod +x "$TMP/bin/herdr"
  export PATH="$TMP/bin:$PATH"

  PROJ="$TMP/demo-app"
  mkdir -p "$PROJ"
  git -c init.defaultBranch=feat/chart init -q "$PROJ"
  git -C "$PROJ" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

  printf 'USAGE=%q\nLAST_SEQ=1\nLAST_USAGE_TS=%s\nTITLE=\nWORKING=\nBLOCKED=\n' \
    '37%' "$(date +%s)" > "$XDG_RUNTIME_DIR/claude-herdr-meta/w9_p1"
  printf 'SHARED_SESSION_PCT=25\nSHARED_WEEK_PCT=99\n' \
    > "$XDG_RUNTIME_DIR/claude-herdr-meta/usage-limits"
  printf 'SHARED_TS=%s\nSHARED_PCT=%q\n' "$(date +%s)" '↑25% · W ↓99%' \
    > "$XDG_RUNTIME_DIR/claude-herdr-meta/usage-shared"
  export CURSOR_USAGE_CACHE="$TMP/cursor-usage"
  export CURSOR_USAGE_JSON='{"planUsage":{"autoPercentUsed":16.06,"apiPercentUsed":1.755},"billingCycleStart":1,"billingCycleEnd":2}'
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

opt_value() { awk -F'\t' -v k="$1" '{for(i=1;i<NF;i++) if($i==k){print $(i+1); exit}}' "$TMP/herdr.log"; }

t_prompt() {
  jq -nc --arg c "$PROJ" '{hook_event_name:"beforeSubmitPrompt", conversation_id:"c1",
    workspace_roots:[$c], prompt:"fix the sidebar"}' | "$HOOK" >/dev/null
  local d; d="$(opt_value --display-agent)"
  check "agent is cursor"       grep -q 'cursor' <<<"$d"
  check "Auto percent"          grep -q 'Auto 16%' <<<"$d"
  check "API percent"           grep -q 'API 2%' <<<"$d"
  check "no Claude percent"     test -z "$(grep -oE '37%|25%|99%|!!!' <<<"$d")"
  check "not labeled claude"    test -z "$(grep -o 'claude' <<<"$d")"
  check "source cursor-hook"    test "$(opt_value --source)" = cursor-hook
  check "tab is the branch"     test "$(awk -F'\t' '$1=="tab" && $2=="rename" {print $4; exit}' "$TMP/herdr.log")" = feat/chart
  check "title is the prompt"   test "$(opt_value --title)" = "fix the sidebar"
  check "working is the prompt" grep -q 'working=fix the sidebar' "$TMP/herdr.log"
  check "idle with branch"      grep -q 'idle=ready · demo-app · feat/chart' "$TMP/herdr.log"
}

t_tool() {
  local out
  out="$(jq -nc --arg c "$PROJ" '{hook_event_name:"preToolUse", cwd:$c, tool_name:"Shell",
    tool_input:{command:"git status"}}' | "$HOOK" 2>/dev/null)"
  check "tool in working" grep -q 'working=Shell: git status' "$TMP/herdr.log"
  check "tool is allowed" test "$(jq -r .permission <<<"$out")" = allow
}

t_tool_path() {
  jq -nc --arg c "$PROJ" '{hook_event_name:"preToolUse", cwd:$c, tool_name:"Write",
    tool_input:{path:"src/main.go"}}' | "$HOOK" >/dev/null
  check "file name from path" grep -q 'working=Write: main.go' "$TMP/herdr.log"
}

t_session_end() {
  jq -nc --arg c "$PROJ" '{hook_event_name:"sessionEnd", workspace_roots:[$c], reason:"completed"}' \
    | "$HOOK" >/dev/null
  check "title cleared" grep -q -- '--clear-title' "$TMP/herdr.log"
  check "agent cleared" grep -q -- '--clear-display-agent' "$TMP/herdr.log"
}

t_start() {
  jq -nc --arg c "$PROJ" '{hook_event_name:"sessionStart", workspace_roots:[$c], session_id:"s1"}' \
    | "$HOOK" >/dev/null
  check "starting label" grep -q 'working=starting' "$TMP/herdr.log"
  check "title with branch" test "$(opt_value --title)" = "demo-app@feat/chart"
}

t_marker() {
  export CURSOR_USAGE_JSON='{"planUsage":{"autoPercentUsed":92,"apiPercentUsed":10}}'
  rm -f "$CURSOR_USAGE_CACHE"
  jq -nc --arg c "$PROJ" '{hook_event_name:"beforeSubmitPrompt", conversation_id:"c1",
    workspace_roots:[$c], prompt:"edge"}' | "$HOOK" >/dev/null
  check "mark at 92%" grep -q '!!! cursor' <<<"$(opt_value --display-agent)"
}

run_test "prompt: agent, limit, branch" t_prompt
run_test "mark at high Auto"            t_marker
run_test "tool and permission"          t_tool
run_test "file via path"                t_tool_path
run_test "session end clears the pane"  t_session_end
run_test "session start"                t_start

printf '\ntotal: %d ok, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
