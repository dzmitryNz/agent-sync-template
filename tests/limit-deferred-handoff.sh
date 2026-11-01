#!/usr/bin/env bash
# JSONL queue must keep newlines across drain + enqueue.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/limit-deferred-handoff.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "not satisfied: $*"; fi; }

setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/run"
  export DEFERRED_HANDOFF_DIR="$TMP/deferred"
  export AGENT_SYNC_BIN="$TMP/bin"
  export HANDOFF_HOOKS_DIR="$TMP/hooks"
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR/claude-herdr-meta" "$TMP/bin" "$TMP/hooks" "$DEFERRED_HANDOFF_DIR"
  # schedule no-ops so enqueue/drain do not need systemd
  cat > "$TMP/bin/limit-schedule.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  wake-epoch) echo $(($(date +%s) + 3600)) ;;
  schedule-job|cancel-pane|sanitize-limits) ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$TMP/bin/limit-schedule.sh"
  # handoff records each delivery; always succeeds
  cat > "$TMP/hooks/herdr-handoff.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/handoff.log"
exit 0
EOF
  chmod +x "$TMP/hooks/herdr-handoff.sh"
  # send is optional
  cat > "$TMP/hooks/herdr-pane-send.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TMP/hooks/herdr-pane-send.sh"
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

qfile() { printf '%s/%s.jsonl' "$DEFERRED_HANDOFF_DIR" "${1//[^A-Za-z0-9]/_}"; }

t_jsonl_roundtrip() {
  local pane=w1:p2 q
  q=$(qfile "$pane")
  bash "$BIN" --enqueue --target "$pane" --skill agent-developer \
    --message $'From: w0:p0\n[DEV REQUEST] one' >/dev/null
  bash "$BIN" --enqueue --target "$pane" --skill agent-developer \
    --message $'From: w0:p0\n[DEV REQUEST] two' >/dev/null
  check "two lines after enqueue" test "$(wc -l <"$q" | tr -d ' ')" -eq 2
  check "line1 parses" bash -c 'jq -e . >/dev/null <<<"$(sed -n "1p" "$1")"' _ "$q"
  check "line2 parses" bash -c 'jq -e . >/dev/null <<<"$(sed -n "2p" "$1")"' _ "$q"

  bash "$BIN" --drain --target "$pane" >/dev/null
  check "one line left after drain" test "$(wc -l <"$q" | tr -d ' ')" -eq 1
  check "remaining line parses" bash -c 'jq -e . >/dev/null <<<"$(cat "$1")"' _ "$q"
  check "first handoff delivered" grep -q '\[DEV REQUEST\] one' "$TMP/handoff.log"

  bash "$BIN" --enqueue --target "$pane" --skill agent-developer \
    --message $'From: w0:p0\n[DEV REQUEST] three' >/dev/null
  check "two lines after re-enqueue" test "$(wc -l <"$q" | tr -d ' ')" -eq 2
  check "re-enqueue line1 parses" bash -c 'jq -e . >/dev/null <<<"$(sed -n "1p" "$1")"' _ "$q"
  check "re-enqueue line2 parses" bash -c 'jq -e . >/dev/null <<<"$(sed -n "2p" "$1")"' _ "$q"
  check "no glued JSON on one line" \
    test "$(jq -c . <"$q" | wc -l | tr -d ' ')" -eq 2

  bash "$BIN" --drain --target "$pane" >/dev/null
  bash "$BIN" --drain --target "$pane" >/dev/null
  check "queue empty after two drains" test ! -s "$q"
  check "all three delivered" test "$(grep -c 'DEV REQUEST' "$TMP/handoff.log")" -eq 3
}

t_notify_date_fallback() {
  # wake_epoch that date -d cannot parse must not trip set -e via `|| wake_human`
  export DEFERRED_HANDOFF_DIR="$TMP/deferred"
  # Force a bad epoch path: empty wake from schedule
  cat > "$TMP/bin/limit-schedule.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in wake-epoch) exit 1 ;; *) exit 0 ;; esac
EOF
  chmod +x "$TMP/bin/limit-schedule.sh"
  bash "$BIN" --enqueue --target w9:p9 --skill agent-pm \
    --message $'From: w0:p0\n[PM REQUEST] x' >/dev/null
  check "enqueue with no wake-epoch exits 0" test -s "$(qfile w9:p9)"
}

run_test "jsonl survives drain then enqueue" t_jsonl_roundtrip
run_test "enqueue tolerates missing wake-epoch" t_notify_date_fallback

printf '\ntotal: %d ok, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
