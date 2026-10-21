#!/usr/bin/env bash
# Tests for herdr-spaces.sh (the me subcommand and basic list).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/store/.claude/hooks/herdr-spaces.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "failed: $*"; fi; }

setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/herdr" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = workspace ] && [ "$2" = get ]; then
  cat <<'JSON'
{"result":{"workspace":{"label":"Developer","agent_status":"idle","workspace_id":"w9"}}}
JSON
  exit 0
fi
if [ "$1" = workspace ] && [ "$2" = list ]; then
  cat <<'JSON'
{"result":{"workspaces":[{"label":"Developer","agent_status":"idle","workspace_id":"w9"}]}}
JSON
  exit 0
fi
if [ "$1" = pane ] && [ "$2" = list ]; then
  cat <<'JSON'
{"result":{"panes":[{"pane_id":"w9:p1","workspace_id":"w9","agent":"claude"}]}}
JSON
  exit 0
fi
exit 0
EOF
  chmod +x "$TMP/bin/herdr"
  export PATH="$TMP/bin:$PATH"
  export HOME="$TMP/home"
  mkdir -p "$HOME"
  HOST="$(hostname)"
}

teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

t_me_outside() {
  unset HERDR_ENV HERDR_WORKSPACE_ID HERDR_PANE_ID
  local out rc
  out="$("$SCRIPT" me)"; rc=$?
  check "outside herdr — exit 0" [ "$rc" -eq 0 ]
  check "outside herdr — not in herdr" [ "$out" = "not in herdr" ]
}

t_me_inside() {
  export HERDR_ENV=1 HERDR_WORKSPACE_ID=w9 HERDR_PANE_ID=w9:p1
  local out rc
  out="$("$SCRIPT" me)"; rc=$?
  check "inside herdr — exit 0" [ "$rc" -eq 0 ]
  check "one line: host label pane status" \
    [ "$out" = "$(hostname)"$'\t'"Developer"$'\t'"w9:p1"$'\t'"idle" ]
}

run_test "me outside herdr" t_me_outside
run_test "me inside herdr" t_me_inside

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
