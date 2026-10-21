#!/usr/bin/env bash
# Tests for herdr-notify.sh: a Telegram message when an agent waits for an answer (herdr status blocked) too long.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/bin/herdr-notify.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "failed: $*"; fi; }

setup() {
  TMP="$(mktemp -d)"
  export XDG_RUNTIME_DIR="$TMP/run"
  export HERDR_AGENTS_FILE="$TMP/agents.json"
  export HERDR_NOTIFY_ENV="$TMP/notify.env"
  printf 'TELEGRAM_BOT_TOKEN=tok-123\nTELEGRAM_CHAT_ID=42\n' > "$HERDR_NOTIFY_ENV"
  unset HERDR_NOTIFY_BLOCKED_SEC
  mkdir -p "$XDG_RUNTIME_DIR" "$TMP/bin"
  # curl stub: writes its arguments to "sent"; fails if the file "down" exists
  cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
[ -e "$TMP/down" ] && exit 7
cfg=""; prev=""
for a in "\$@"; do [ "\$prev" = -K ] && cfg=\$(cat "\$a"); prev=\$a; done
printf '%s | %s | %s\n' "\$*" "\$cfg" "\$(cat)" >> "$TMP/sent"
EOF
  chmod +x "$TMP/bin/curl"
  export PATH="$TMP/bin:$PATH"
  : > "$TMP/sent"
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

agents() { # agents <pane:status>... -> agents.json in the format of "herdr agent list"
  local items=() a
  for a in "$@"; do
    items+=("$(jq -nc --arg p "${a%:*}" --arg s "${a##*:}" \
      '{pane_id:$p, agent:"claude", agent_status:$s, terminal_title_stripped:("Task " + $p), cwd:"/home/me/proj"}')")
  done
  printf '%s\n' "${items[@]}" | jq -sc '{result:{agents:.}}' > "$HERDR_AGENTS_FILE"
}
run_at() { HERDR_NOTIFY_NOW="$1" "$SCRIPT"; }   # run_at <epoch>
sent() { grep -c . "$TMP/sent"; }

# --- 1. waits less than the threshold: stay quiet -----------------------------
t_below() {
  agents w1:p1:blocked
  run_at 1000; run_at 1599
  check "nothing was sent" test "$(sent)" -eq 0
}

# --- 2. waits 10 minutes: one message, with the task title and the address ----
t_after_threshold() {
  agents w1:p1:blocked
  run_at 1000; run_at 1600
  check "one message" test "$(sent)" -eq 1
  check "Telegram sendMessage with the token" grep -q 'api.telegram.org/bottok-123/sendMessage' "$TMP/sent"
  check "sent to the chat from the config" grep -q '"chat_id":"42"' "$TMP/sent"
  check "the task title is in the message" grep -q 'Task w1:p1' "$TMP/sent"
}

# --- 3. still waiting: no repeat ----------------------------------------------
t_no_repeat() {
  agents w1:p1:blocked
  run_at 1000; run_at 1600; run_at 2200; run_at 5000
  check "only one message" test "$(sent)" -eq 1
}

# --- 4. answered, then waits again: a new period ------------------------------
t_new_period() {
  agents w1:p1:blocked;  run_at 1000; run_at 1600
  agents w1:p1:working;  run_at 1700
  agents w1:p1:blocked;  run_at 1800; run_at 2300
  check "no second message yet" test "$(sent)" -eq 1
  run_at 2400
  check "the second message" test "$(sent)" -eq 2
}

# --- 5. other statuses (done, idle) send nothing ------------------------------
t_other_status() {
  agents w1:p1:done w2:p1:idle w3:p1:working
  run_at 1000; run_at 5000
  check "nothing was sent" test "$(sent)" -eq 0
}

# --- 6. Telegram is down: no error, retry on the next run ---------------------
t_ntfy_down() {
  agents w1:p1:blocked
  run_at 1000
  touch "$TMP/down"
  check "the script does not fail" run_at 1600
  rm "$TMP/down"
  run_at 1660
  check "sent after Telegram is back" test "$(sent)" -eq 1
}

# --- 7. the threshold is configurable -----------------------------------------
t_custom_threshold() {
  export HERDR_NOTIFY_BLOCKED_SEC=60
  agents w1:p1:blocked
  run_at 1000; run_at 1060
  check "sent after 60 s" test "$(sent)" -eq 1
}

# --- 8. agents are counted separately; a vanished agent is forgotten ----------
t_per_agent() {
  agents w1:p1:blocked w2:p1:working; run_at 1000
  agents w1:p1:blocked w2:p1:blocked; run_at 1300
  run_at 1600
  check "only the first" test "$(sent)" -eq 1
  agents w2:p1:blocked;   run_at 1900
  check "then the second" test "$(sent)" -eq 2
  check "the first is forgotten" bash -c "! grep -q 'w1:p1' '$XDG_RUNTIME_DIR/herdr-notify.state'"
}

# --- 9. the token is not visible in the process list (not in the curl argv) ---
t_token_not_in_args() {
  agents w1:p1:blocked
  run_at 1000; run_at 1600
  check "no token in argv" bash -c "! cut -d'|' -f1 '$TMP/sent' | grep -q tok-123"
}

# --- 10. no token file: send nothing and do not fail --------------------------
t_no_env() {
  rm "$HERDR_NOTIFY_ENV"
  agents w1:p1:blocked
  run_at 1000
  check "the script does not fail" run_at 1600
  check "nothing was sent" test "$(sent)" -eq 0
}

run_test "below the threshold: quiet"     t_below
run_test "after the threshold: one message" t_after_threshold
run_test "no repeat"                      t_no_repeat
run_test "new period after a reply"       t_new_period
run_test "done/idle/working send nothing" t_other_status
run_test "Telegram is down"               t_ntfy_down
run_test "threshold from the environment" t_custom_threshold
run_test "agents are counted separately"  t_per_agent
run_test "token is not in the curl arguments" t_token_not_in_args
run_test "no token file: quiet"           t_no_env

printf '\ntotal: %d ok, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
