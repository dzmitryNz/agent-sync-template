#!/usr/bin/env bash
# Tests for herdr-pane-reply.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/herdr-pane-reply.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "failed: $*"; fi; }
not() { ! "$@"; }

setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/herdr" <<EOF
#!/usr/bin/env bash
cat "$TMP/screen"
EOF
  chmod +x "$TMP/bin/herdr"
  export PATH="$TMP/bin:$PATH"
}

teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

t_extracts_last_result() {
  cat > "$TMP/screen" <<'EOF'
noise before
[DEV RESULT] old stuff
more noise
[REVIEW RESULT] Plan: x.md

PR: https://example/1
Worktree: .worktrees/x
EOF
  local out rc
  out="$("$SCRIPT" w1:p1)"; rc=$?
  check "exit 0" [ "$rc" -eq 0 ]
  check "starts with the marker" grep -q '^\[REVIEW RESULT\]' <<<"$out"
  check "contains the PR" grep -q 'https://example/1' <<<"$out"
  check "no old DEV RESULT" not grep -q '\[DEV RESULT\]' <<<"$out"
}

t_claude_prefix() {
  # Real Claude-pane chrome: prompt glyph / status before the marker
  cat > "$TMP/screen" <<'EOF'
● Thinking…
❯ [DEV RESULT] Plan: y.md

PR: https://example/2
EOF
  local out rc
  out="$("$SCRIPT" w1:p1)"; rc=$?
  check "prefix — exit 0" [ "$rc" -eq 0 ]
  check "prefix — block with RESULT" grep -q '\[DEV RESULT\]' <<<"$out"
  check "prefix — PR" grep -q 'https://example/2' <<<"$out"
}

t_no_marker() {
  printf 'just chatter\nno marker here\n' > "$TMP/screen"
  local out rc
  out="$("$SCRIPT" w1:p1 2>/dev/null)"; rc=$?
  check "no marker — exit 1" [ "$rc" -eq 1 ]
  check "empty stdout" [ -z "$out" ]
}

run_test "last RESULT" t_extracts_last_result
run_test "Claude prefix" t_claude_prefix
run_test "no marker" t_no_marker

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
