#!/usr/bin/env bash
# Tests for herdr-handoff.sh: no /clear when the agent has not sent a result yet
# (pending marker from role-clear.sh Stop hook).
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/store/.claude/hooks/herdr-handoff.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "failed: $*"; fi; }

setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home" HANDOFF_SETTLE_START=0 HANDOFF_POLL=0
  MARKER="$HOME/.cache/agent-roles/pending-w1_p2"
  mkdir -p "$TMP/bin" "$HOME/.claude/hooks" "$HOME/.cache/agent-roles"
  # fake herdr: claude pane, always idle; pane read returns sent lines
  cat > "$TMP/bin/herdr" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "agent get")  echo '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}' ;;
  "pane read")  cat "$TMP/sent.log" 2>/dev/null ;;
esac
EOF
  cat > "$HOME/.claude/hooks/herdr-pane-send.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$2" >> "$TMP/sent.log"
EOF
  chmod +x "$TMP/bin/herdr" "$HOME/.claude/hooks/herdr-pane-send.sh"
  export PATH="$TMP/bin:$PATH"
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

handoff() { timeout 20 "$SCRIPT" "$@" >/dev/null 2>"$TMP/err"; }

t_free_pane() {
  handoff w1:p2 agent-review "[REVIEW REQUEST] PR #2"; local rc=$?
  check "exit 0"           test "$rc" -eq 0
  check "/clear sent"  grep -qx /clear "$TMP/sent.log"
  check "sent"  grep -q 'REVIEW REQUEST' "$TMP/sent.log"
}

t_pending_pane() {
  echo REVIEW > "$MARKER"
  handoff w1:p2 agent-review "[REVIEW REQUEST] PR #2"; local rc=$?
  check "exit 2 (busy)"           test "$rc" -eq 2
  check "nothing not sent"       bash -c "! test -s '$TMP/sent.log'"
  check "in stderr — waiting reply"     grep -q 'REVIEW RESULT' "$TMP/err"
}

t_stale_marker() {
  echo REVIEW > "$MARKER"; touch -d '4 hours ago' "$MARKER"
  handoff w1:p2 agent-review "[REVIEW REQUEST] PR #2"; local rc=$?
  check "stale marker not blocks" test "$rc" -eq 0
  check "/clear sent"           grep -qx /clear "$TMP/sent.log"
}

t_no_clear_continues() {
  echo DEV > "$MARKER"
  handoff --no-clear w1:p2 agent-developer "[DEV REQUEST] fix review"; local rc=$?
  check "--no-clear not" test "$rc" -eq 0
  check "without /clear"                bash -c "! grep -qx /clear '$TMP/sent.log'"
}

run_test "1. free pane"            t_free_pane
run_test "2. still not sent"    t_pending_pane
run_test "3. marker older 3 hours"     t_stale_marker
run_test "4. --no-clear continues"     t_no_clear_continues

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
