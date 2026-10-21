#!/usr/bin/env bash
# Tests for template-drift.sh — changes on main since the last template port.
# Temporary repo with local bare origin; no network.
set -uo pipefail

DRIFT="$(cd "$(dirname "$0")/.." && pwd)/bin/template-drift.sh"
PASS=0; FAIL=0

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "failed: $*"; fi; }

setup() {
  TMP="$(mktemp -d)"
  export SYNC_HOME="$TMP/repo"
  git init -q --bare "$TMP/origin.git"
  git init -q -b main "$SYNC_HOME"
  git -C "$SYNC_HOME" remote add origin "$TMP/origin.git"
  put bin/x.sh "v1"
  put store/.claude/plans/p.md "v1"
  base="$(commit_all base)"
  echo "$base" > "$SYNC_HOME/template.ported"
  git -C "$SYNC_HOME" add template.ported
  git -C "$SYNC_HOME" commit -qm marker
  git -C "$SYNC_HOME" push -q origin main
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

put() { mkdir -p "$(dirname "$SYNC_HOME/$1")"; printf '%s\n' "$2" > "$SYNC_HOME/$1"; }
commit_all() { git -C "$SYNC_HOME" add -A; git -C "$SYNC_HOME" commit -qm "$1"; git -C "$SYNC_HOME" rev-parse HEAD; }
publish() { git -C "$SYNC_HOME" push -q origin main; }
marker() { cat "$SYNC_HOME/template.ported"; }
drift() { OUT="$("$DRIFT" "$@" 2>&1)"; RC=$?; }

t_no_changes() {
  drift
  check "exit 0" [ "$RC" -eq 0 ]
  check "message up to date" grep -q 'template is up to date with main' <<<"$OUT"
}

t_change_in_bin() {
  put bin/x.sh "v2"; commit_all "touch x" >/dev/null; publish
  drift
  check "exit 1" [ "$RC" -eq 1 ]
  check "commit in list" grep -q 'touch x' <<<"$OUT"
  check "file in diff --stat" grep -q 'bin/x.sh' <<<"$OUT"
}

t_ignored_paths() {
  put store/.claude/plans/p.md "v2"
  put sessions/host-a/s.json "{}"
  put store/.claude/skills/synced/s/SKILL.md "x"
  put store/.claude/skills/typescript-magician/SKILL.md "x"
  put bin/cursor-session-record.sh "x"
  put bin/merge-cli-config.sh "x"
  commit_all "ignored only" >/dev/null; publish
  drift
  check "exit 0" [ "$RC" -eq 0 ]
  check "commit not shown" bash -c '! grep -q "ignored only" <<<"$1"' _ "$OUT"
}

t_diff_full() {
  put bin/x.sh "v2"; commit_all "touch x" >/dev/null; publish
  drift --diff
  check "diff" grep -q '^+v2' <<<"$OUT"
  put bin/y.sh "y"; commit_all "add y" >/dev/null; publish
  drift --diff bin/y.sh
  check "diff: only y" bash -c 'grep -q "bin/y.sh" <<<"$1" && ! grep -q "bin/x.sh" <<<"$1"' _ "$OUT"
}

t_mark_moves_marker() {
  put bin/x.sh "v2"; new="$(commit_all "touch x")"; publish
  drift --mark
  check "mark exit 0" [ "$RC" -eq 0 ]
  check "marker = origin/main" [ "$(marker)" = "$new" ]
  check "commit template: ported up to" bash -c 'git -C "$1" log -1 --format=%s | grep -q "^template: ported up to $2"' _ "$SYNC_HOME" "${new:0:7}"
  drift
  check "after mark exit 0" [ "$RC" -eq 0 ]
}

t_mark_non_ancestor() {
  git -C "$SYNC_HOME" checkout -q -b side
  put bin/z.sh "z"; stray="$(commit_all stray)"
  git -C "$SYNC_HOME" checkout -q main
  before="$(marker)"
  drift --mark "$stray"
  check "exit not 0" [ "$RC" -ne 0 ]
  check "marker not unchanged" [ "$(marker)" = "$before" ]
}

t_no_marker() {
  git -C "$SYNC_HOME" rm -q template.ported; git -C "$SYNC_HOME" commit -qm rm
  drift
  check "exit 2" [ "$RC" -eq 2 ]
  check "clear error" grep -q 'template.ported' <<<"$OUT"
}

t_invalid_marker() {
  echo "deadbeef" > "$SYNC_HOME/template.ported"
  drift
  check "exit 2" [ "$RC" -eq 2 ]
}

run_test "no"                      t_no_changes
run_test "change in bin/ visible, exit 1"       t_change_in_bin
run_test "plans/sessions/synced/ignored — no" t_ignored_paths
run_test "--diff full and by path"          t_diff_full
run_test "--mark moves marker"             t_mark_moves_marker
run_test "--mark not-ancestor rejected"         t_mark_non_ancestor
run_test "no → exit 2"              t_no_marker
run_test "invalid marker → exit 2"             t_invalid_marker

printf '\ntotal: %d ok, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
