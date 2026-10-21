#!/usr/bin/env bash
# Tests of the session registry: the recording hook and the search/resume CLI.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/bin/session-record.sh"
CLI="$ROOT/bin/agent-sessions.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "not met: $*"; fi; }

setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  export SESSIONS_DIR="$HOME/.agent-sync/sessions"
  export SESSIONS_HOST=machine-a
  mkdir -p "$HOME/.claude/projects"
  unset HERDR_WORKSPACE_ID HERDR_PANE_ID HERDR_TAB_ID
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

# Sends the hook an event, the way Claude Code does
event() { # event <hook_event_name> <session_id> <cwd> [prompt]
  jq -nc --arg e "$1" --arg s "$2" --arg c "$3" --arg p "${4:-}" \
    '{hook_event_name:$e, session_id:$s, cwd:$c, prompt:$p,
      transcript_path:("/tmp/"+$s+".jsonl")}' | "$HOOK" >/dev/null 2>&1
}

# PostToolUse event: the agent wrote a file
tool_event() { # tool_event <session_id> <cwd> <tool> <file>
  jq -nc --arg s "$1" --arg c "$2" --arg n "$3" --arg f "$4" \
    '{hook_event_name:"PostToolUse", session_id:$s, cwd:$c,
      tool_name:$n, tool_input:{file_path:$f}}' | "$HOOK" >/dev/null 2>&1
}

rec() { # path to the record
  printf '%s/%s/%s.json' "$SESSIONS_DIR" "${2:-$SESSIONS_HOST}" "$1"
}

field() { jq -r "$2" "$(rec "$1" "${3:-$SESSIONS_HOST}")" 2>/dev/null; }

# --- agent: claude by default, overridden by a variable ----------------------
# The registry is shared by Claude and Cursor, so the agent is not a constant. Old records
# without the variable must stay claude, otherwise we rewrite history retroactively.
t_agent_default() {
  event UserPromptSubmit sess-1 /home/me/proj "ordinary session"
  check "claude by default" test "$(field sess-1 .agent)" = claude
}

t_agent_override() {
  AGENT=cursor event UserPromptSubmit sess-cur /home/me/proj "session of cursor"
  check "agent from the variable" test "$(field sess-cur .agent)" = cursor
  check "the rest is in place"  test "$(field sess-cur .cwd)" = /home/me/proj
}

# Cursor calls both the adapter (AGENT=cursor) and the hook from ~/.claude/settings.json
# without the variable. The second call must not roll the agent back to claude.
t_agent_not_clobbered() {
  AGENT=cursor event UserPromptSubmit sess-mix /home/me/proj "session of cursor"
  event UserPromptSubmit sess-mix /home/me/proj "another prompt"
  check "a repeat without AGENT does not overwrite cursor" test "$(field sess-mix .agent)" = cursor
  check "prompt updated" test "$(field sess-mix .last_prompt)" = "another prompt"
}

# A live Cursor payload sometimes goes straight to session-record.sh (without the adapter):
# the transcript is in ~/.cursor/.../agent-transcripts/.
t_agent_from_cursor_transcript() {
  jq -nc '{hook_event_name:"UserPromptSubmit", session_id:"sess-tr",
           cwd:"/home/me/proj", prompt:"a prompt",
           transcript_path:"/home/x/.cursor/projects/p/agent-transcripts/sess-tr/sess-tr.jsonl"}' \
    | "$HOOK" >/dev/null 2>&1
  check "agent from the transcript path" test "$(field sess-tr .agent)" = cursor
}

t_agent_from_cursor_payload() {
  jq -nc '{hook_event_name:"beforeSubmitPrompt", conversation_id:"sess-pl",
           workspace_roots:["/home/me/proj"], prompt:"test hooks"}' \
    | "$HOOK" >/dev/null 2>&1
  check "record by conversation_id" test -f "$(rec sess-pl)"
  check "agent from Cursor fields"     test "$(field sess-pl .agent)" = cursor
  check "directory from workspace_roots" test "$(field sess-pl .cwd)" = /home/me/proj
}

# --- 1. the hook creates a session record ------------------------------------
t_records() {
  event UserPromptSubmit sess-1 /home/me/proj "first task"
  check "record created" test -f "$(rec sess-1)"
  check "id saved"   test "$(field sess-1 .session_id)" = sess-1
  check "directory saved" test "$(field sess-1 .cwd)" = /home/me/proj
  check "host saved" test "$(field sess-1 .host)" = machine-a
}

# --- 2. the first prompt becomes the description, later ones update last -----
t_prompts() {
  event SessionStart      sess-1 /home/me/proj
  event UserPromptSubmit  sess-1 /home/me/proj "fixing memory sync"
  event UserPromptSubmit  sess-1 /home/me/proj "now add tests"

  check "first prompt saved"  \
    test "$(field sess-1 .first_prompt)" = "fixing memory sync"
  check "last prompt updated" \
    test "$(field sess-1 .last_prompt)" = "now add tests"
  check "start time not overwritten" \
    test -n "$(field sess-1 .started_at)"
}

# --- 3. the herdr workspace goes into the record -----------------------------
t_herdr() {
  export HERDR_WORKSPACE_ID=w25 HERDR_PANE_ID=w25:p1 HERDR_TAB_ID=w25:t1
  event UserPromptSubmit sess-1 /home/me/proj "work in herdr"
  check "workspace recorded" test "$(field sess-1 .herdr.workspace)" = w25
  check "pane recorded"      test "$(field sess-1 .herdr.pane)" = w25:p1
}

# --- 4. broken input does not crash the hook ---------------------------------
# The hook runs on every prompt: it must not fail on any data.
t_bad_input() {
  printf 'not json' | "$HOOK" >/dev/null 2>&1
  check "garbage input: exit 0" test $? -eq 0
  printf '{}' | "$HOOK" >/dev/null 2>&1
  check "empty json: exit 0" test $? -eq 0
  check "no garbage records appeared" \
    test -z "$(ls -A "$SESSIONS_DIR/$SESSIONS_HOST" 2>/dev/null)"
}

# --- 5. list shows sessions of all machines, newest first --------------------
t_list() {
  event SessionStart     sess-old /home/me/a
  event UserPromptSubmit sess-old /home/me/a "old task"
  # The hook sets last_seen to the second: without an explicit shift both records
  # get the same stamp, and "newest first" would check the order of find, not the sort
  jq -c '.last_seen = "2026-09-05T09:00:00Z"' "$(rec sess-old)" > "$(rec sess-old).x" \
    && mv "$(rec sess-old).x" "$(rec sess-old)"
  # a record from another machine arrives through sync as a normal file
  mkdir -p "$SESSIONS_DIR/machine-b"
  jq -nc '{session_id:"sess-b", host:"machine-b", cwd:"/home/me/b",
           started_at:"2026-09-05T10:00:00Z", last_seen:"2026-09-05T23:00:00Z",
           first_prompt:"task from the second machine"}' \
    > "$SESSIONS_DIR/machine-b/sess-b.json"
  event UserPromptSubmit sess-new /home/me/c "fresh task"

  out="$("$CLI" list 2>&1)"
  check "own session in the list"    grep -q 'old task'          <<<"$out"
  check "other session in the list"   grep -q 'task from the second machine' <<<"$out"
  check "the host of the other session is visible" grep -q 'machine-b'              <<<"$out"
  check "the newest on top" \
    test "$(grep -n 'fresh task' <<<"$out" | cut -d: -f1)" -lt \
         "$(grep -n 'old task' <<<"$out" | cut -d: -f1)"
  check "a non-empty list is not reported as empty" \
    test -z "$(grep -i 'registry is empty' <<<"$out")"
}

# --- 21. one session — one line ---------------------------------------------
# A session picked up on a second machine lies in the registry twice: each machine
# where it ran keeps a record. In the list these are two lines about the same thing —
# out of 20 lines of output, three went to duplicates.
t_list_dedup() {
  mkrec sess-dup 2026-09-06T08:00:00Z "pick up session" /home/me/proj machine-a
  mkdir -p "$SESSIONS_DIR/machine-b"
  jq -nc '{session_id:"sess-dup", agent:"claude", host:"machine-b", home:"/home/me",
           cwd:"/home/me/proj", started_at:"2026-09-06T09:00:00Z",
           last_seen:"2026-09-06T15:00:00Z", first_prompt:"pick up session",
           plan:"/home/me/.claude/plans/shared-task.md",
           herdr:{workspace:"w3",tab:"",pane:""}}' > "$SESSIONS_DIR/machine-b/sess-dup.json"

  out="$("$CLI" list 2>&1)"
  check "the session is shown once"  test "$(grep -c 'pick up session' <<<"$out")" -eq 1
  check "the counter counts sessions, not records" grep -q 'of 1' <<<"$out"
  check "both machines are listed"    grep -qE 'machine-b,machine-a|machine-a,machine-b' <<<"$out"
  check "the fresh machine first"      grep -q 'machine-b,machine-a' <<<"$out"
  check "herdr from the fresh record"    grep -q 'w3' <<<"$out"
  check "plan from the fresh record"     grep -q 'shared-task' <<<"$out"
}

t_list_dedup_host_filter() {
  mkrec sess-dup 2026-09-06T08:00:00Z "shared session" /home/me/proj machine-a
  mkdir -p "$SESSIONS_DIR/machine-b"
  jq -nc '{session_id:"sess-dup", host:"machine-b", home:"/home/me", cwd:"/home/me/proj",
           last_seen:"2026-09-06T15:00:00Z", first_prompt:"shared session"}' \
    > "$SESSIONS_DIR/machine-b/sess-dup.json"
  mkrec sess-solo 2026-09-06T10:00:00Z "only here" /home/me/proj machine-a

  check "--host finds by a non-primary machine" \
    grep -q 'shared session' <<<"$("$CLI" list --host machine-a 2>&1)"
  check "--host finds by the fresh machine" \
    grep -q 'shared session' <<<"$("$CLI" list --host machine-b 2>&1)"
  check "another machine does not pull extra" \
    test -z "$(grep 'only here' <<<"$("$CLI" list --host machine-b 2>&1)")"
}

# Numbering in list and in resume must be counted over the same list:
# if duplicates are merged in the list, resume must count the same way.
t_list_dedup_numbering() {
  mkrec sess-dup 2026-09-06T08:00:00Z "first" /home/me/proj machine-a
  mkdir -p "$SESSIONS_DIR/machine-b"
  jq -nc '{session_id:"sess-dup", host:"machine-b", home:"/home/me", cwd:"/home/me/proj",
           last_seen:"2026-09-06T15:00:00Z", first_prompt:"first"}' \
    > "$SESSIONS_DIR/machine-b/sess-dup.json"
  mkrec sess-two 2026-09-05T10:00:00Z "second" /home/me/proj machine-a

  out="$("$CLI" list 2>&1)"
  check "the second session has number 2" grep -qE '^2 .*second' <<<"$out"
  check "resume 2 leads to it"       grep -q 'sess-two' <<<"$("$CLI" resume 2 --print 2>&1)"
}

# --- 6. resume prints a command with a cd into the directory ----------------
t_cursor_in_list() {
  event UserPromptSubmit sess-cl /home/me/proj "session of claude"
  AGENT=cursor event UserPromptSubmit cur-l /home/me/proj "session of cursor"
  out="$("$CLI" list 2>&1)"
  check "there is an agent column"   grep -qi 'agent' <<<"$out"
  check "cursor is marked"        grep -q 'cursor' <<<"$out"
  check "claude is marked"          grep -q 'claude' <<<"$out"
  check "both sessions are in the list"   test "$(grep -c 'session ' <<<"$out")" -eq 2
}

t_cursor_resume() {
  AGENT=cursor event UserPromptSubmit cur-r /home/me/proj "fixing the queue"
  out="$("$CLI" resume cur-r --print 2>&1)"
  check "cd into the directory"     grep -q "cd '/home/me/proj'" <<<"$out"
  check "resume by cursor" grep -q 'cursor-agent --resume cur-r' <<<"$out"
  check "does not call claude"       bash -c "! grep -q 'claude --resume' <<<\"$out\""
}

t_resume() {
  event UserPromptSubmit sess-1 /home/me/proj "task"
  out="$("$CLI" resume sess-1 --print 2>&1)"
  check "there is a cd into the directory" grep -q "cd '/home/me/proj'" <<<"$out"
  check "there is a resume"     grep -q 'claude --resume sess-1' <<<"$out"
}

# --- 7. a foreign home directory is rewritten to our own ---------------------
# Another machine has a different $HOME, and the history lies under the path slug.
t_resume_foreign_home() {
  mkdir -p "$SESSIONS_DIR/machine-b"
  jq -nc '{session_id:"sess-b", host:"machine-b", cwd:"/home/other/DIY",
           home:"/home/other", started_at:"2026-09-05T10:00:00Z",
           last_seen:"2026-09-05T10:00:00Z", first_prompt:"its task"}' \
    > "$SESSIONS_DIR/machine-b/sess-b.json"

  out="$("$CLI" resume sess-b --print 2>&1)"
  check "foreign HOME replaced by our own" grep -q "cd '$HOME/DIY'" <<<"$out"
}

# --- 8. a warning if the transcript is not on this machine ------------------
t_resume_without_transcript() {
  mkdir -p "$SESSIONS_DIR/machine-b"
  jq -nc '{session_id:"sess-missing", host:"machine-b", cwd:"/home/me/proj",
           started_at:"2026-09-05T10:00:00Z", last_seen:"2026-09-05T10:00:00Z",
           first_prompt:"not arrived"}' \
    > "$SESSIONS_DIR/machine-b/sess-missing.json"

  out="$("$CLI" resume sess-missing --print 2>&1)"
  check "warning about history" grep -qi 'history' <<<"$out"
}

# --- 9. records older than the transcript lifetime are deleted --------------
# Claude cleans transcripts after 30 days; the registry must not offer what
# no longer exists.
t_prune() {
  mkdir -p "$SESSIONS_DIR/$SESSIONS_HOST"
  jq -nc '{session_id:"sess-ancient", host:"machine-a", cwd:"/home/me/a",
           started_at:"2026-01-01T00:00:00Z", last_seen:"2026-01-01T00:00:00Z",
           first_prompt:"ancient"}' \
    > "$SESSIONS_DIR/$SESSIONS_HOST/sess-ancient.json"
  touch -d "60 days ago" "$SESSIONS_DIR/$SESSIONS_HOST/sess-ancient.json"

  event UserPromptSubmit sess-fresh /home/me/a "fresh"

  check "ancient record deleted" test ! -e "$SESSIONS_DIR/$SESSIONS_HOST/sess-ancient.json"
  check "fresh record intact"     test -f "$(rec sess-fresh)"
}

# --- 10. list with no records does not fail ----------------------------------
t_empty_list() {
  out="$("$CLI" list 2>&1)"
  check "exit 0 on an empty registry" test $? -eq 0
  check "says it is empty" grep -qi 'empty\|no sessions' <<<"$out"
}

# --- 11. service sessions do not clutter the registry ------------------------
# The herdr hook runs `claude -p /usage` every 5 minutes for the limit percent.
# Such sessions live for seconds and only get in the way of "what did I do yesterday".
t_service_sessions_skipped() {
  event SessionStart sess-svc /home/me/proj
  check "a start without a prompt creates no record" test ! -f "$(rec sess-svc)"

  event UserPromptSubmit sess-usage /home/me/proj "/usage"
  check "service /usage not recorded" test ! -f "$(rec sess-usage)"

  event UserPromptSubmit sess-real /home/me/proj "fix sync"
  check "real work recorded" test -f "$(rec sess-real)"
}

# --- 11a. herdr standing role agents do not enter the registry ---------------
# There are more of their sessions (Review/QA/DevOps/Logs/Developer/DB) than real ones,
# and they push real work out of the list.
t_role_agent_sessions_skipped() {
  local i=0 p en_prompt="you are agent-reviewer, follow the skill"
  for p in /agent-review /agent-developer /agent-devops /agent-qa /agent-logs /agent-db /agent-cleaner \
           "$en_prompt" \
           "[REVIEW REQUEST] PR acme/acme-api#98" \
           "[DEVOPS REQUEST] start the stand" "[CLEANER REQUEST] clean worktrees"; do
    i=$((i+1))
    event UserPromptSubmit "sess-role-$i" /home/me/proj "$p"
    check "role session not recorded: $p" test ! -f "$(rec "sess-role-$i")"
  done

  event UserPromptSubmit sess-agent-sync /home/me/proj "agent-sync is not syncing"
  check "similar user prompt recorded" test -f "$(rec sess-agent-sync)"
}

# --- 12. Stop updates a record, it does not create an empty one --------------
t_stop_updates_existing() {
  event UserPromptSubmit sess-1 /home/me/proj "working"
  event Stop             sess-1 /home/me/proj
  check "one record, with a description" \
    test "$(field sess-1 .first_prompt)" = "working"
  event Stop sess-2 /home/me/proj
  check "Stop without a prompt creates no record" test ! -f "$(rec sess-2)"
}

# --- 13. the plan being worked on goes into the record ----------------------
# A fresh session should pick up work from the plan, not from the transcript:
# a plan is kilobytes against hundreds of kilobytes.
t_plan_linked() {
  event UserPromptSubmit sess-1 /home/me/proj "big task"
  tool_event sess-1 /home/me/proj Write "$HOME/.claude/plans/proj-task.md"
  check "plan recorded" \
    test "$(field sess-1 .plan)" = "$HOME/.claude/plans/proj-task.md"
}

# --- 14. a plan in the repository counts too --------------------------------
t_plan_in_repo() {
  event UserPromptSubmit sess-1 /home/me/proj "team task"
  tool_event sess-1 /home/me/proj Edit "/home/me/proj/docs/plans/20260905-task.md"
  check "plan from docs/plans recorded" \
    test "$(field sess-1 .plan)" = "/home/me/proj/docs/plans/20260905-task.md"
}

# --- 15. ordinary edits do not count as a plan -------------------------------
t_plan_ignores_other_files() {
  event UserPromptSubmit sess-1 /home/me/proj "work"
  tool_event sess-1 /home/me/proj Edit "/home/me/proj/src/index.ts"
  check "the plan field is empty" test -z "$(field sess-1 .plan)"
}

# --- 16. editing a plan does not create a service-session record -------------
t_plan_no_orphan_record() {
  tool_event sess-ghost /home/me/proj Write "$HOME/.claude/plans/x.md"
  check "no record" test ! -f "$(rec sess-ghost)"
}

# --- 17. the list shows that a plan exists -----------------------------------
t_list_shows_plan() {
  event UserPromptSubmit sess-1 /home/me/proj "task with a plan"
  tool_event sess-1 /home/me/proj Write "$HOME/.claude/plans/proj-task.md"
  local out; out="$("$CLI" list 2>&1)"
  check "the plan name is visible" grep -q 'proj-task' <<<"$out"
}

# --- 18. brief: a cheap digest instead of a megabyte transcript -------------
# When no plan was kept, a fresh agent still needs a place to start.
t_brief() {
  local dir="$HOME/.claude/projects/-home-me-proj"
  mkdir -p "$dir"
  local f="$dir/sess-b.jsonl"
  jq -nc --arg c /home/me/proj '{type:"user", cwd:$c, message:{role:"user", content:"cache fix"}}'  > "$f"
  jq -nc '{type:"assistant", message:{role:"assistant", content:[
      {type:"tool_use", name:"Edit",  input:{file_path:"/home/me/proj/src/cache.ts"}},
      {type:"tool_use", name:"Bash",  input:{command:"npm test -- cache"}}]}}' >> "$f"
  jq -nc '{type:"user", message:{role:"user", content:"now add a boundary test plus a long sentence that is deliberately longer than one hundred characters so the digest cuts by characters"}}' >> "$f"

  out="$("$CLI" brief sess-b 2>&1)"
  check "user prompts are present"  grep -q 'cache fix'          <<<"$out"
  check "the last request is present"     grep -q 'boundary test'  <<<"$out"
  check "changed files are named"   grep -q 'cache.ts'               <<<"$out"
  check "commands are named"            grep -q 'npm test'               <<<"$out"
  check "the digest is compact"          test "$(wc -c <<<"$out")" -lt 4000
  check "the digest is not truncated mid-character" test -z "$(grep -c $'\ufffd' <<<"$out" | grep -v '^0$')"
}

# --- 19. brief of a non-existent session does not fail -----------------------
t_brief_missing() {
  local rc; "$CLI" brief no-such >/dev/null 2>&1; rc=$?
  check "says it was not found" test "$rc" -ne 0
}

# The description is cut by characters: GNU cut -c cuts bytes and can split a multibyte character.
t_prompt_trim_utf8() {
  local long; long="$(printf 'é%.0s' {1..150})"
  event UserPromptSubmit sess-long /home/me/proj "$long"
  local got; got="$(field sess-long .first_prompt)"
  check "record is valid json"      jq -e . "$(rec sess-long)" >/dev/null
  check "description is at most 120"     test "$(printf '%s' "$got" | wc -m)" -le 120
  check "and not cut in half"          test "$(printf '%s' "$got" | wc -m)" -ge 100
}

# --- 20. search, date filters and pagination in list -------------------------
# After backfill the registry is hundreds of records for a month. Without search and pages
# a week-old session is in the list, but it cannot be found.

# Puts a ready record: tests need arbitrary dates, and the hook sets "now".
mkrec() { # mkrec <id> <last_seen> <prompt> [cwd] [host] [agent] [plan]
  local host="${5:-$SESSIONS_HOST}"
  mkdir -p "$SESSIONS_DIR/$host"
  jq -nc --arg id "$1" --arg ts "$2" --arg p "$3" --arg cwd "${4:-/home/me/proj}" \
         --arg host "$host" --arg agent "${6:-claude}" --arg plan "${7:-}" \
    '{session_id:$id, agent:$agent, host:$host, home:"/home/me", cwd:$cwd,
      started_at:$ts, last_seen:$ts, first_prompt:$p, last_prompt:$p, plan:$plan,
      herdr:{workspace:"",tab:"",pane:""}}' > "$SESSIONS_DIR/$host/$1.json"
}

t_list_search() {
  mkrec sess-cache 2026-09-04T10:00:00Z "cache fix"
  mkrec sess-chat  2026-09-05T10:00:00Z "chat does not return history"
  mkrec sess-plan  2026-09-05T11:00:00Z "ordinary task" /home/me/proj \
        "$SESSIONS_HOST" claude /home/me/.claude/plans/api-cache.md
  mkrec sess-cwd   2026-09-05T12:00:00Z "review fixes" /home/me/acme-api

  out="$("$CLI" list cache 2>&1)"
  check "search finds by prompt"     grep -qi 'cache fix' <<<"$out"
  check "the rest is filtered out"         test -z "$(grep -i 'does not return history' <<<"$out")"

  out="$("$CLI" list api-cache 2>&1)"
  check "search by plan name"         grep -q 'ordinary task' <<<"$out"

  out="$("$CLI" list acme-api 2>&1)"
  check "search by directory"            grep -q 'review fixes' <<<"$out"
}

t_list_search_no_match() {
  mkrec sess-1 2026-09-05T10:00:00Z "some task"
  local rc; out="$("$CLI" list reserved-no-such 2>&1)"; rc=$?
  check "exit 0 when nothing is found" test "$rc" -eq 0
  check "says nothing was found"   grep -qi 'nothing found\|not found' <<<"$out"
}

t_list_limit() {
  local i
  for i in $(seq -w 1 25); do mkrec "sess-$i" "2026-09-0${i:0:1}T$((10#${i:1:1}))0:00:00Z" "task $i"; done
  out="$("$CLI" list 2>&1)"
  check "by default at most 20 sessions" \
    test "$(grep -c 'task ' <<<"$out")" -eq 20
  out="$("$CLI" list -n 5 2>&1)"
  check "-n limits the output"  test "$(grep -c 'task ' <<<"$out")" -eq 5
  out="$("$CLI" list --all 2>&1)"
  check "--all removes the limit"    test "$(grep -c 'task ' <<<"$out")" -eq 25
}

t_list_page() {
  local i
  for i in 1 2 3 4 5 6; do mkrec "sess-$i" "2026-09-0${i}T10:00:00Z" "task $i"; done
  local p1 p2
  p1="$("$CLI" list -n 2 2>&1)"
  p2="$("$CLI" list -n 2 --page 2 2>&1)"
  # newest first: page 1 — tasks 6 and 5, page 2 — 4 and 3
  check "page 1 — the newest"   grep -q 'task 6' <<<"$p1"
  check "page 2 — the next ones"      grep -q 'task 4' <<<"$p2"
  check "pages do not overlap"    test -z "$(grep 'task 6' <<<"$p2")"
  check "the page has a limit too"      test "$(grep -c 'task ' <<<"$p2")" -eq 2
}

# The number in the list must be continuous: otherwise `resume 1` from the second page
# would lead to the first session of the registry, not the one visible on the screen.
t_list_page_numbering() {
  local i
  for i in 1 2 3 4; do mkrec "sess-$i" "2026-09-0${i}T10:00:00Z" "task $i"; done
  out="$("$CLI" list -n 2 --page 2 2>&1)"
  check "numbering is continuous, not from one" grep -qE '^ *3 ' <<<"$out"
  check "resume by this number — the same session" \
    grep -q 'sess-2' <<<"$("$CLI" resume 3 --print 2>&1)"
}

t_list_date_filters() {
  mkrec sess-thu 2026-09-03T15:00:00Z "thursday task"
  mkrec sess-fri 2026-09-04T15:00:00Z "friday task"
  mkrec sess-sat 2026-09-05T15:00:00Z "saturday task"

  out="$("$CLI" list --on 2026-09-04 2>&1)"
  check "--on takes only that day"  grep -q 'friday task' <<<"$out"
  check "--on cuts off the neighbor day"  test -z "$(grep 'saturday' <<<"$out")"

  out="$("$CLI" list --since 2026-09-04 2>&1)"
  check "--since includes the bound"     grep -q 'friday task' <<<"$out"
  check "--since cuts off earlier"      test -z "$(grep 'thursday' <<<"$out")"

  out="$("$CLI" list --until 2026-09-04 2>&1)"
  check "--until includes the bound"     grep -q 'friday task' <<<"$out"
  check "--until cuts off later"       test -z "$(grep 'saturday' <<<"$out")"
}

t_list_date_relative() {
  mkrec sess-now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "today task"
  mkrec sess-old 2020-01-01T10:00:00Z "ancient task"
  out="$("$CLI" list --since '2 days ago' 2>&1)"
  check "the relative date is understood" grep -q 'today task' <<<"$out"
  check "the old one is cut off"               test -z "$(grep 'ancient' <<<"$out")"
}

t_list_bad_date() {
  mkrec sess-1 2026-09-05T10:00:00Z "task"
  local rc; out="$("$CLI" list --since 'not-a-date' 2>&1)"; rc=$?
  check "an unclear date is an error"  test "$rc" -ne 0
  check "the error names the date"     grep -qi 'date' <<<"$out"
}

t_list_bad_flag() {
  local rc; out="$("$CLI" list --no-such-flag 2>&1)"; rc=$?
  check "an unknown flag is an error" test "$rc" -ne 0
  check "a hint is shown"        grep -qi 'list' <<<"$out"
}

t_list_filters_host_agent() {
  mkrec sess-a 2026-09-05T10:00:00Z "own task"   /home/me/proj machine-a claude
  mkrec sess-b 2026-09-05T11:00:00Z "other task"  /home/me/proj machine-b claude
  mkrec sess-c 2026-09-05T12:00:00Z "cursor one"     /home/me/proj machine-a cursor

  out="$("$CLI" list --host machine-b 2>&1)"
  check "--host filters"   grep -q 'other task' <<<"$out"
  check "--host cuts off"    test -z "$(grep 'own task' <<<"$out")"

  out="$("$CLI" list --agent cursor 2>&1)"
  check "--agent filters"  grep -q 'cursor one' <<<"$out"
  check "--agent cuts off"   test -z "$(grep 'other task' <<<"$out")"
}

t_list_footer() {
  local i
  for i in 1 2 3 4 5; do mkrec "sess-$i" "2026-09-0${i}T10:00:00Z" "task $i"; done
  out="$("$CLI" list -n 2 2>&1)"
  check "the footer shows the total" grep -qE '(of|total)[^0-9]*5' <<<"$out"
  check "the footer mentions pages"   grep -qi 'page\|--page' <<<"$out"
}

run_test "brief gives a digest of the transcript"    t_brief
run_test "brief of a non-existent session"       t_brief_missing
run_test "the plan goes into the session record"        t_plan_linked
run_test "a plan from docs/plans too"              t_plan_in_repo
run_test "ordinary files do not count as a plan"    t_plan_ignores_other_files
run_test "editing a plan does not breed records"        t_plan_no_orphan_record
run_test "the list shows the plan"               t_list_shows_plan
run_test "service sessions do not clutter the registry"   t_service_sessions_skipped
run_test "role agents do not clutter the registry"     t_role_agent_sessions_skipped
run_test "Stop updates, it does not create an empty one"    t_stop_updates_existing
run_test "the default agent is claude"            t_agent_default
run_test "the agent is overridden by a variable"      t_agent_override
run_test "a repeated hook does not overwrite cursor"       t_agent_not_clobbered
run_test "agent from a Cursor transcript"            t_agent_from_cursor_transcript
run_test "agent from a Cursor payload without AGENT"      t_agent_from_cursor_payload
run_test "the hook creates a session record"           t_records
run_test "first and last prompt"              t_prompts
run_test "the herdr workspace goes into the record"      t_herdr
run_test "broken input does not crash the hook"               t_bad_input
run_test "list: all machines, newest first"       t_list
run_test "Cursor: visible in the list with an agent label" t_cursor_in_list
run_test "Cursor: resume calls cursor-agent"      t_cursor_resume
run_test "resume prints a command with cd"           t_resume
run_test "a foreign HOME is rewritten to our own"      t_resume_foreign_home
run_test "a warning without a transcript"         t_resume_without_transcript
run_test "old records are pruned"               t_prune
run_test "an empty registry does not break list"           t_empty_list
run_test "the description is cut by characters"           t_prompt_trim_utf8
run_test "list: search by substring"               t_list_search
run_test "list: search with no match"             t_list_search_no_match
run_test "list: limit and --all"                    t_list_limit
run_test "list: pages"                         t_list_page
run_test "list: continuous page numbering"       t_list_page_numbering
run_test "list: date filters"                  t_list_date_filters
run_test "list: relative date"               t_list_date_relative
run_test "list: unclear date"                  t_list_bad_date
run_test "list: unknown flag"                 t_list_bad_flag
run_test "list: filters by machine and agent"       t_list_filters_host_agent
run_test "list: footer with a counter"               t_list_footer
run_test "list: duplicates of one session are merged"     t_list_dedup
run_test "list: --host by any machine"          t_list_dedup_host_filter
run_test "list: numbering after merging"      t_list_dedup_numbering

printf '\ntotal: %d ok, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
