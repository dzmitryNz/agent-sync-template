#!/usr/bin/env bash
# Cursor wrappers: JSON protocol over geo/limit/plan/awake.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEO="$ROOT/bin/cursor-geo-guard.sh"
LIMIT="$ROOT/bin/cursor-limit-guard.sh"
PLAN="$ROOT/bin/cursor-plan-resume.sh"
AWAKE="$ROOT/bin/cursor-awake-hook.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "not satisfied: $*"; fi; }

setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  export XDG_RUNTIME_DIR="$TMP/run"
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$TMP/bin"
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

prompt() { # prompt <hook> <json> -> OUT, RC
  local hook="$1" json="$2"
  OUT="$(printf '%s\n' "$json" | "$hook" 2>/dev/null)"
  RC=$?
}

# --- geo ---------------------------------------------------------------------
geo_env() {
  export GEO_STATE_DIR="$XDG_RUNTIME_DIR/claude-geo-guard"
  export GEO_IP_TTL=0
  export GEO_IPS_FILE="$TMP/allowed-ips"
  export FAKE_NET="$TMP/net"
  mkdir -p "$TMP/net"
  cat > "$TMP/bin/curl" <<'CURL_EOF'
#!/usr/bin/env bash
url=''
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  *icanhazip.com*) name=ip1 ;;
  *ipinfo.io*)     name=geo1 ;;
  *) exit 6 ;;
esac
[ -e "$FAKE_NET/$name" ] || exit 22
cat "$FAKE_NET/$name"
CURL_EOF
  chmod +x "$TMP/bin/curl"
  export PATH="$TMP/bin:$PATH"
  printf '%s' '203.0.113.7' > "$TMP/net/ip1"
}

t_geo_allow() {
  geo_env
  export GEO_ALLOWED=PL
  printf '%s' 'PL' > "$TMP/net/geo1"
  prompt "$GEO" '{"hook_event_name":"beforeSubmitPrompt","conversation_id":"c1","prompt":"hi"}'
  check "exit 0" test "$RC" -eq 0
  check "allowed country answers continue:true (empty reply under failClosed is an error)" \
    test "$(printf '%s' "$OUT" | jq -r '.continue' 2>/dev/null)" = "true"
}

t_geo_block() {
  geo_env
  export GEO_ALLOWED=PL
  printf '%s' 'BY' > "$TMP/net/geo1"
  prompt "$GEO" '{"hook_event_name":"beforeSubmitPrompt","conversation_id":"c1","prompt":"hi"}'
  check "exit 0 (block is JSON, not exit 2)" test "$RC" -eq 0
  check "continue false" test "$(jq -r .continue <<<"$OUT")" = false
  check "country in user_message" grep -q 'BY' <<<"$(jq -r .user_message <<<"$OUT")"
}

# --- limit -------------------------------------------------------------------
t_limit_silent() {
  export LIMIT_STATE_DIR="$XDG_RUNTIME_DIR/claude-herdr-meta"
  mkdir -p "$LIMIT_STATE_DIR" "$HOME/.claude/plans"
  printf 'SHARED_SESSION_PCT=92\nSHARED_WEEK_PCT=99\n' > "$LIMIT_STATE_DIR/usage-limits"
  prompt "$LIMIT" '{"hook_event_name":"beforeSubmitPrompt","conversation_id":"c1","prompt":"hi"}'
  check "exit 0" test "$RC" -eq 0
  check "Claude quota does not enter Cursor context" test -z "$OUT"
}

# --- plan --------------------------------------------------------------------
t_plan_once() {
  export CURSOR_PLAN_STATE_DIR="$XDG_RUNTIME_DIR/cursor-plan-resume"
  export HERDR_WORKSPACE_ID=w2
  mkdir -p "$HOME/.claude/plans"
  printf '**Herdr space:** demo-space\n' > "$HOME/.claude/plans/task.md"
  cat > "$TMP/bin/herdr" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "workspace list" ] || exit 1
echo '{"result":{"workspaces":[{"workspace_id":"w2","label":"demo-space"}]}}'
EOF
  chmod +x "$TMP/bin/herdr"
  export PATH="$TMP/bin:$PATH"
  prompt "$PLAN" '{"hook_event_name":"beforeSubmitPrompt","conversation_id":"c1","prompt":"hi"}'
  check "plan in context" grep -q 'task.md' <<<"$(jq -r .additional_context <<<"$OUT")"
  check "continue true" test "$(jq -r .continue <<<"$OUT")" = true
  prompt "$PLAN" '{"hook_event_name":"beforeSubmitPrompt","conversation_id":"c1","prompt":"next"}'
  check "second prompt of the same session stays quiet" test -z "$OUT"
  prompt "$PLAN" '{"hook_event_name":"sessionStart","conversation_id":"c2"}'
  check "non-beforeSubmitPrompt stays quiet" test -z "$OUT"
}

t_plan_no_space() {
  unset HERDR_WORKSPACE_ID
  prompt "$PLAN" '{"hook_event_name":"beforeSubmitPrompt","conversation_id":"c1"}'
  check "without herdr space stays quiet" test -z "$OUT"
  check "exit 0" test "$RC" -eq 0
}

# --- awake -------------------------------------------------------------------
t_awake() {
  export AWAKE_STATE_DIR="$TMP/awake"
  export POWER_SUPPLY_DIR="$TMP/power" AGENT_SYNC_OS=linux
  export INHIBIT_BIN="$TMP/bin/systemd-inhibit"
  mkdir -p "$AWAKE_STATE_DIR" "$POWER_SUPPLY_DIR/BAT0"
  printf 'Battery\n' > "$POWER_SUPPLY_DIR/BAT0/type"
  printf '40\n' > "$POWER_SUPPLY_DIR/BAT0/capacity"
  cat > "$INHIBIT_BIN" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/inhibit.log"
exec sleep 300
EOF
  chmod +x "$INHIBIT_BIN"
  prompt "$AWAKE" '{"hook_event_name":"beforeSubmitPrompt","conversation_id":"c1","prompt":"hi"}'
  check "acquire stays quiet" test -z "$OUT"
  check "lock taken" test -f "$AWAKE_STATE_DIR/awake-c1.pid"
  pid="$(cat "$AWAKE_STATE_DIR/awake-c1.pid")"
  prompt "$AWAKE" '{"hook_event_name":"stop","conversation_id":"c1","status":"completed"}'
  check "release stays quiet" test -z "$OUT"
  check "lock released" test ! -f "$AWAKE_STATE_DIR/awake-c1.pid"
  kill "$pid" 2>/dev/null || true
  prompt "$AWAKE" '{"hook_event_name":"beforeShellExecution","conversation_id":"c1"}'
  check "foreign event stays quiet" test -z "$OUT"
}

run_test "geo: allowed country"              t_geo_allow
run_test "geo: blocked country"              t_geo_block
run_test "limit: Claude quota stays out"     t_limit_silent
run_test "plan: once per session"            t_plan_once
run_test "plan: without herdr space"         t_plan_no_space
run_test "awake: acquire and release"        t_awake

printf '\ntotal: %d ok, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
