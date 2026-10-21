#!/usr/bin/env bash
# Tests for plan-resume.sh — a SessionStart hook that after /clear points the agent to
# the task plan by the current herdr space name (the line `**Herdr space:** <name>` in the plan).
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/bin/plan-resume.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "failed: $*"; fi; }

setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  PLANS="$HOME/.claude/plans"
  mkdir -p "$PLANS/completed" "$TMP/bin"
  # fake herdr: a list of spaces, the current one is w2 "api-rate-limit"
  cat > "$TMP/bin/herdr" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "workspace list" ] || exit 1
echo '{"result":{"workspaces":[{"workspace_id":"w1","label":"Review"},{"workspace_id":"w2","label":"api-rate-limit"}]}}'
EOF
  chmod +x "$TMP/bin/herdr"
  export PATH="$TMP/bin:$PATH"
  export HERDR_WORKSPACE_ID=w2
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

plan() { # plan <file> <space>
  printf '# Task\n\n**Date:** 2026-09-25\n**Herdr space:** %s\n' "$2" > "$PLANS/$1"
}

fire() { # fire [source] -> hook stdout
  jq -nc --arg s "${1:-clear}" '{hook_event_name:"SessionStart", source:$s, session_id:"s1"}' \
    | "$HOOK" 2>/dev/null
}

t_found() {
  plan api-cache.md api-rate-limit
  plan other.md Review
  local out; out="$(fire)"
  check "plan path given"    grep -q "$PLANS/api-cache.md" <<<"$out"
  check "other plan not given"   bash -c "! grep -q other.md <<<'$out'"
  check "told to read"     grep -qi 'read it first' <<<"$out"
}

t_backticks() {
  printf '**Herdr space:** `api-rate-limit`\n' > "$PLANS/p.md"
  local out; out="$(fire)"
  check "a name in backticks is matched too" grep -q "$PLANS/p.md" <<<"$out"
}

t_not_prefix() {
  plan p.md api-rate-limit-2
  local out; out="$(fire)"
  check "match only as a whole" test -z "$out"
}

t_completed_skipped() {
  plan ../plans/completed/done.md api-rate-limit
  local out; out="$(fire)"
  check "completed plans are skipped" test -z "$out"
}

t_several() {
  plan a.md api-rate-limit; plan b.md api-rate-limit
  local out; out="$(fire)"
  check "both plans listed" bash -c "grep -q a.md <<<'$out' && grep -q b.md <<<'$out'"
}

t_only_clear() {
  plan p.md api-rate-limit
  check "startup — silent" test -z "$(fire startup)"
  check "resume — silent"  test -z "$(fire resume)"
}

t_no_herdr() {
  plan p.md api-rate-limit
  unset HERDR_WORKSPACE_ID
  local out rc; out="$(fire)"; rc=$?
  check "silent outside herdr" test -z "$out"
  check "exit 0"          test "$rc" -eq 0
}

t_no_plan() {
  local out; out="$(fire)"
  check "no plan — silent" test -z "$out"
}

run_test "1. plan found by space"         t_found
run_test "2. space name in backticks"         t_backticks
run_test "3. name prefix is not a match"  t_not_prefix
run_test "4. completed/ is skipped"      t_completed_skipped
run_test "5. several plans"             t_several
run_test "6. only after /clear"          t_only_clear
run_test "7. outside herdr"                    t_no_herdr
run_test "8. no plan"                    t_no_plan

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
