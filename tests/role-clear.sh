#!/usr/bin/env bash
# Tests for role-clear.sh — a Stop hook that sends /clear to the pane of a standing herdr agent
# when it has finished a request and its context has grown.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/bin/role-clear.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "failed: $*"; fi; }

setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  export ROLE_CLEAR_TOKENS=100000 ROLE_CLEAR_DELAY=0 ROLE_SKILL_DELAY=0
  export HERDR_PANE_ID="w1:p2"
  mkdir -p "$TMP/bin" "$HOME"
  # fake herdr writes calls to a log
  cat > "$TMP/bin/herdr" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/herdr.log"
EOF
  chmod +x "$TMP/bin/herdr"
  export PATH="$TMP/bin:$PATH"
  TRANSCRIPT="$TMP/t.jsonl"
  : > "$TRANSCRIPT"
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

prompt() { jq -nc --arg p "$1" '{type:"user", message:{role:"user", content:$p}}' >> "$TRANSCRIPT"; }
tool_result() { jq -nc --arg p "$1" '{type:"user", message:{role:"user",
  content:[{type:"tool_result", content:$p}]}}' >> "$TRANSCRIPT"; }
turn() { jq -nc --argjson r "$1" '{type:"assistant", message:{id:"m\($r)",
  usage:{input_tokens:1, cache_read_input_tokens:$r, cache_creation_input_tokens:0}}}' >> "$TRANSCRIPT"; }
bash_call() { jq -nc --arg c "$1" '{type:"assistant", message:{role:"assistant",
  content:[{type:"tool_use", name:"Bash", input:{command:$c}}]}}' >> "$TRANSCRIPT"; }
answer() { bash_call "~/.claude/hooks/herdr-pane-send.sh w9:p1 \"[$1 RESULT] done\""; }

fire() {
  jq -nc --arg t "$TRANSCRIPT" '{hook_event_name:"Stop", session_id:"s1", transcript_path:$t}' \
    | "$HOOK" >/dev/null 2>&1
  local i; for i in $(seq 20); do [ -f "$TMP/herdr.log" ] && break; sleep 0.05; done
  sleep 0.3
}
sent() { [ -f "$TMP/herdr.log" ]; }

t_role_big() {
  prompt "[REVIEW REQUEST] PR #1"; answer REVIEW; turn 120000
  fire
  check "/clear sent"        grep -q 'send-text w1:p2 /clear' "$TMP/herdr.log"
  check "Enter pressed"             grep -q 'send-keys w1:p2 Enter' "$TMP/herdr.log"
  check "role skill after /clear" grep -q 'send-text w1:p2 /agent-review$' "$TMP/herdr.log"
  check "skill after /clear"   bash -c "grep -n send-text '$TMP/herdr.log' | tail -1 | grep -q /agent-review"
}

t_role_small() {
  prompt "[QA REQUEST] run tests"; turn 60000
  fire
  check "small context — leave alone" bash -c "! test -f '$TMP/herdr.log'"
}

t_not_role() {
  prompt "fix the bug in chat"; turn 200000
  fire
  check "ordinary session — leave alone" bash -c "! test -f '$TMP/herdr.log'"
}

t_request_in_tool_result() {
  prompt "send for review"; tool_result "[REVIEW REQUEST] PR #2"; turn 200000
  fire
  check "a request in tool output does not make the session a role session" bash -c "! test -f '$TMP/herdr.log'"
}

t_pasted_after_model() {
  prompt "<command-name>/model</command-name>
            <command-message>model</command-message>"
  prompt '  <pasted_content id="7197"> [DEV REQUEST] Plan: x </pasted_content id="7197">'
  answer DEV; turn 150000
  fire
  check "request in pasted_content after /model — role session" grep -q '/clear' "$TMP/herdr.log"
}

t_skill_command() {
  prompt "<command-name>/agent-review</command-name>
            <command-message>agent-review</command-message>"; turn 150000
  fire
  check "start via /agent-* — role session" grep -q '/clear' "$TMP/herdr.log"
}

t_no_herdr_pane() {
  unset HERDR_PANE_ID
  prompt "[DB REQUEST] q"; turn 200000
  fire
  check "outside herdr — leave alone" bash -c "! test -f '$TMP/herdr.log'"
}

t_garbage() {
  printf 'garbage\n' > "$TRANSCRIPT"
  local rc
  jq -nc --arg t "$TRANSCRIPT" '{transcript_path:$t}' | "$HOOK" >/dev/null 2>&1; rc=$?
  check "garbage — exit 0" test "$rc" -eq 0
}

t_role_by_tag() { # t_role_by_tag <prompt> <expected skill>
  prompt "$1"
  [[ "$1" =~ ^\[([A-Z]+)\ REQUEST\] ]] && answer "${BASH_REMATCH[1]}"
  turn 150000
  fire
  check "«$1» → $2" grep -qx "pane send-text w1:p2 $2" "$TMP/herdr.log"
}

t_result_not_sent() {
  prompt "[REVIEW REQUEST] PR #1"; bash_call "gh pr diff 1"; turn 150000
  fire
  check "no result sent — leave alone" bash -c "! test -f '$TMP/herdr.log'"
}

t_pending_marker() {
  local m="$HOME/.cache/agent-roles/pending-w1_p2"
  prompt "[REVIEW REQUEST] PR #1"; turn 20000
  fire
  check "no answer — pending marker" grep -qx REVIEW "$m"
  answer REVIEW; turn 20000
  fire
  check "answer sent — marker removed" bash -c "! test -e '$m'"
}

t_next_request_pending() {
  prompt "[REVIEW REQUEST] PR #1"; answer REVIEW
  prompt "[REVIEW REQUEST] PR #2"; turn 150000
  fire
  check "second request without answer — no clear" bash -c "! test -f '$TMP/herdr.log'"
}

t_other_tag_result() {
  prompt "[REVIEW REQUEST] PR #1"; answer QA; turn 150000
  fire
  check "wrong tag in result — not counted" bash -c "! test -f '$TMP/herdr.log'"
}

t_request_quoted_in_skill() {
  prompt "<command-name>/agent-review</command-name>"
  prompt "Base directory for this skill ... a [REVIEW REQUEST] arrives ..."; turn 150000
  fire
  check "tag inside skill text — not a request" grep -q '/clear' "$TMP/herdr.log"
}

t_user_followup_after_result() {
  prompt "[DB REQUEST] q"; answer DB; prompt "thanks"; turn 150000
  fire
  check "result sent, then normal prompt — clear" grep -q '/clear' "$TMP/herdr.log"
}
t_tag_db()      { t_role_by_tag "[DB REQUEST] q"          /agent-db; }
t_tag_dev()     { t_role_by_tag "[DEV REQUEST] Plan: x"   /agent-developer; }
t_tag_devops()  { t_role_by_tag "[DEVOPS REQUEST] up"     /agent-devops; }
t_tag_cleaner() { t_role_by_tag "[CLEANER REQUEST] all"   /agent-cleaner; }
t_you_are()     { t_role_by_tag "You are agent-logs in space Logs" /agent-logs; }
t_skill_qa()    { t_role_by_tag "<command-name>/agent-qa</command-name>" /agent-qa; }

run_test "1. role agent, big context" t_role_big
run_test "2. role agent, small context"   t_role_small
run_test "3. ordinary session"                  t_not_role
run_test "4. request tag in tool_result"       t_request_in_tool_result
run_test "5. start by skill /agent-review"    t_skill_command
run_test "5a. pasted_content after /model"    t_pasted_after_model
run_test "6. without HERDR_PANE_ID"               t_no_herdr_pane
run_test "7. garbage in the transcript"             t_garbage
run_test "8. DB REQUEST → /agent-db"          t_tag_db
run_test "9. DEV REQUEST → /agent-developer" t_tag_dev
run_test "10. DEVOPS REQUEST → /agent-devops" t_tag_devops
run_test "11. CLEANER REQUEST → /agent-cleaner" t_tag_cleaner
run_test "12. Russian role prompt → /agent-logs"  t_you_are
run_test "13. /agent-qa → /agent-qa"          t_skill_qa
run_test "14. result not sent yet"             t_result_not_sent
run_test "14a. pending marker for handoff"    t_pending_marker
run_test "15. new request without answer"        t_next_request_pending
run_test "16. result with wrong tag"            t_other_tag_result
run_test "17. tag quoted in skill body"            t_request_quoted_in_skill
run_test "18. user prompt after result"            t_user_followup_after_result

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
