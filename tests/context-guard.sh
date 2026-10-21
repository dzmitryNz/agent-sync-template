#!/usr/bin/env bash
# Tests for context-guard.sh, the hook that warns the AGENT about a large context,
# so it records progress in the plan and offers /compact or a new session.
set -uo pipefail

GUARD="$(cd "$(dirname "$0")/.." && pwd)/bin/context-guard.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "not satisfied: $*"; fi; }

setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  export CONTEXT_STATE_DIR="$TMP/state"
  export CONTEXT_WARN_TOKENS=150000
  export CONTEXT_REWARN_STEP=50000
  mkdir -p "$HOME/.claude/plans"
  TRANSCRIPT="$TMP/t.jsonl"
  : > "$TRANSCRIPT"
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

turn() { # turn <cache_read> [sidechain] appends an assistant reply to the transcript
  jq -nc --argjson r "$1" --argjson sc "${2:-false}" \
    '{type:"assistant", isSidechain:$sc, message:{usage:{input_tokens:5,
      cache_read_input_tokens:$r, cache_creation_input_tokens:1000}}}' >> "$TRANSCRIPT"
}

fire() { # fire [session_id] [transcript] -> hook stdout
  jq -nc --arg s "${1:-sess-1}" --arg t "${2:-$TRANSCRIPT}" \
    '{hook_event_name:"UserPromptSubmit", session_id:$s, transcript_path:$t}' \
    | "$GUARD" 2>/dev/null
}

t_quiet_below() {
  turn 80000
  local out; out="$(fire)"
  check "silent below the threshold" test -z "$out"
}

t_warn_above() {
  turn 80000; turn 160000
  local out; out="$(fire)"
  check "warning issued"        test -n "$out"
  check "context size shown"    grep -q '161k' <<<"$out"
  check "plan is mentioned"    grep -q '.claude/plans' <<<"$out"
  check "/compact is mentioned" grep -q '/compact' <<<"$out"
}

t_last_turn_counts() {
  turn 170000; turn 40000
  local out; out="$(fire)"
  check "silent after compaction" test -z "$out"
}

t_sidechain_ignored() {
  turn 50000; turn 190000 true
  local out; out="$(fire)"
  check "subagent context does not count" test -z "$out"
}

t_once_per_step() {
  turn 160000
  fire >/dev/null
  local out; out="$(fire)"
  check "silent on repeat at the same level" test -z "$out"
  turn 215000
  out="$(fire)"
  check "grew by a step: warns again" test -n "$out"
}

t_sessions_independent() {
  turn 160000
  fire sess-a >/dev/null
  local out; out="$(fire sess-b)"
  check "another session is warned by its own marker" test -n "$out"
}

t_no_transcript() {
  local out rc
  out="$(fire sess-1 "$TMP/missing.jsonl")"; rc=$?
  check "no transcript: silent" test -z "$out"
  check "exit 0"                  test "$rc" -eq 0
}

t_garbage() {
  printf 'not json\n' > "$TRANSCRIPT"
  local out rc
  out="$(fire)"; rc=$?
  check "garbage: silent" test -z "$out"
  check "exit 0"        test "$rc" -eq 0
}

run_test "1. below the threshold"                  t_quiet_below
run_test "2. above the threshold"                  t_warn_above
run_test "3. the last turn counts"                 t_last_turn_counts
run_test "4. subagent sidechain does not count"    t_sidechain_ignored
run_test "5. one warning per growth step"          t_once_per_step
run_test "6. markers per session"                  t_sessions_independent
run_test "7. no transcript"                        t_no_transcript
run_test "8. garbage in the transcript"            t_garbage

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
