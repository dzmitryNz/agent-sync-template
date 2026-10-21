#!/usr/bin/env bash
# Tests for history-sync.sh. A local directory plays the server, ssh is not needed.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/bin/history-sync.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }

check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "not met: $*"; fi; }

setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  export HISTORY_SRC="$HOME/.claude/projects"
  export HISTORY_REMOTE="$TMP/server/claude"
  mkdir -p "$HISTORY_SRC" "$HISTORY_REMOTE"
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

# Puts a transcript with the given age in days
transcript() { # transcript <root> <relative path> <content> [age in days]
  local root="$1" rel="$2" body="$3" age="${4:-0}"
  mkdir -p "$root/$(dirname -- "$rel")"
  printf '%s\n' "$body" > "$root/$rel"
  [ "$age" -gt 0 ] && touch -d "$age days ago" "$root/$rel"
  return 0
}

# --- 1. fresh transcripts go to the server -----------------------------------
t_push() {
  transcript "$HISTORY_SRC" "-proj-a/session1.jsonl" '{"m":1}'
  "$SCRIPT" >/dev/null 2>&1
  check "file on the server" test -f "$HISTORY_REMOTE/-proj-a/session1.jsonl"
  check "content matches" \
    grep -q '"m":1' "$HISTORY_REMOTE/-proj-a/session1.jsonl"
}

# --- 2. a foreign session arrives from the server -----------------------------
t_pull() {
  transcript "$HISTORY_REMOTE" "-proj-b/session2.jsonl" '{"from":"second machine"}'
  "$SCRIPT" >/dev/null 2>&1
  check "file arrived" test -f "$HISTORY_SRC/-proj-b/session2.jsonl"
}

# --- 3. old files that Claude cleaned do not come back ------------------------
# Claude deletes transcripts older than 30 days by itself. If we pulled everything
# from the server, the deleted files would come back on the next sync.
t_no_resurrect() {
  transcript "$HISTORY_REMOTE" "-proj-c/ancient.jsonl" '{"old":1}' 60
  "$SCRIPT" >/dev/null 2>&1
  check "old file did not come back to the machine" test ! -e "$HISTORY_SRC/-proj-c/ancient.jsonl"
  check "but it stayed on the server" test -f "$HISTORY_REMOTE/-proj-c/ancient.jsonl"
}

# --- 4. appended data of an active session arrives ----------------------------
t_append() {
  transcript "$HISTORY_SRC" "-proj-a/live.jsonl" '{"m":1}'
  "$SCRIPT" >/dev/null 2>&1
  printf '%s\n' '{"m":2}' >> "$HISTORY_SRC/-proj-a/live.jsonl"
  "$SCRIPT" >/dev/null 2>&1
  check "server got the appended data" \
    grep -q '"m":2' "$HISTORY_REMOTE/-proj-a/live.jsonl"
}

# --- 5. a newer local version is not overwritten by the server one ------------
t_newer_local_wins() {
  transcript "$HISTORY_REMOTE" "-proj-a/s.jsonl" '{"version":"server"}' 3
  transcript "$HISTORY_SRC"    "-proj-a/s.jsonl" '{"version":"local"}'
  "$SCRIPT" >/dev/null 2>&1
  check "local version intact" \
    grep -q 'local' "$HISTORY_SRC/-proj-a/s.jsonl"
  check "the local one went to the server" \
    grep -q 'local' "$HISTORY_REMOTE/-proj-a/s.jsonl"
}

# --- 6. nothing is deleted on either side -------------------------------------
t_never_deletes() {
  transcript "$HISTORY_SRC"    "-proj-a/only-local.jsonl"  '{"l":1}'
  transcript "$HISTORY_REMOTE" "-proj-a/only-remote.jsonl" '{"r":1}'
  "$SCRIPT" >/dev/null 2>&1
  check "local file in place"  test -f "$HISTORY_SRC/-proj-a/only-local.jsonl"
  check "server file in place"  test -f "$HISTORY_REMOTE/-proj-a/only-remote.jsonl"
}

# --- 7. only transcripts are synced -------------------------------------------
t_only_jsonl() {
  transcript "$HISTORY_SRC" "-proj-a/s.jsonl" '{"m":1}'
  mkdir -p "$HISTORY_SRC/-proj-a/memory"
  printf 'fact\n' > "$HISTORY_SRC/-proj-a/memory/MEMORY.md"

  "$SCRIPT" >/dev/null 2>&1

  check "transcript went up" test -f "$HISTORY_REMOTE/-proj-a/s.jsonl"
  check "memory is not duplicated here (it is in git)" \
    test ! -e "$HISTORY_REMOTE/-proj-a/memory"
}

# --- 8. server unreachable: no error and no losses -----------------------------
t_offline() {
  transcript "$HISTORY_SRC" "-proj-a/s.jsonl" '{"m":1}'
  export HISTORY_REMOTE="no-such-host.invalid:agent-history/claude"
  export SSH_TIMEOUT=3

  "$SCRIPT" >/dev/null 2>&1
  local rc=$?

  check "exit without error (timer does not spam)" test "$rc" -eq 0
  check "local data intact" test -f "$HISTORY_SRC/-proj-a/s.jsonl"
}

# --- 0. no server set: quietly do nothing -------------------------------------
t_no_server() {
  transcript "$HISTORY_SRC" "-proj-a/s.jsonl" '{"m":1}'
  export HISTORY_REMOTE=""
  unset SYNC_SERVER
  mkdir -p "$TMP/bin"   # ssh and rsync stubs: record the call, never touch a network
  for c in ssh rsync; do printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\nexit 1\n' "$c" "$TMP/net.log" > "$TMP/bin/$c"; chmod +x "$TMP/bin/$c"; done
  local out rc
  out="$(PATH="$TMP/bin:$PATH" "$SCRIPT" 2>&1)"; rc=$?
  check "ssh/rsync were not called"      test ! -s "$TMP/net.log"
  check "without a server exit 0"          test "$rc" -eq 0
  check "without a server no output"       test -z "$out"
  check "local data intact"        test -f "$HISTORY_SRC/-proj-a/s.jsonl"
}

run_test "no server set: exit quietly"           t_no_server
run_test "fresh transcripts go to the server"      t_push
run_test "a foreign session arrives from the server"           t_pull
run_test "old cleaned files do not come back"           t_no_resurrect
run_test "appended data of an active session arrives"          t_append
run_test "a newer local version is not overwritten"       t_newer_local_wins
run_test "nothing is deleted"                        t_never_deletes
run_test "only transcripts are synced"        t_only_jsonl
run_test "offline: no error and no losses"            t_offline

printf '\ntotal: %d ok, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
