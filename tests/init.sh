#!/usr/bin/env bash
# Tests for `agent-sync.sh init`: renders {{PROJECT_*}} placeholders under store/.
# The template is copied into a fake HOME, so the real checkout is never touched.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "not true: $*"; fi; }
not() { ! "$@"; }

setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home" SYNC_HOME="$TMP/home/.agent-sync"
  mkdir -p "$HOME"
  # copy the template without .git; commit it so `git status` shows what init changed
  mkdir -p "$SYNC_HOME"
  (cd "$ROOT" && tar --exclude=.git -cf - .) | (cd "$SYNC_HOME" && tar -xf -)
  git -C "$SYNC_HOME" init -q -b main
  git -C "$SYNC_HOME" add -A
  git -C "$SYNC_HOME" commit -qm base
  SCRIPT="$SYNC_HOME/bin/agent-sync.sh"
  unset PROJECT_NAME PROJECT_ROOT PROJECT_GIT_ORG PROJECT_CREDS_DIR PROJECT_BASE_BRANCH SYNC_SERVER HISTORY_REMOTE USER_LANGUAGE STAND_DB_HOST
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

known_left() { # known placeholders that remain under store/ (CLICKUP_* are not counted)
  grep -rIl --exclude-dir=.git -E '\{\{(PROJECT_[A-Z_]+|SYNC_SERVER)\}\}' "$SYNC_HOME/store" 2>/dev/null
}
renamed_path_left() { find "$SYNC_HOME/store" -name '*{{PROJECT_*' | grep -q .; }

init_acme() { "$SCRIPT" init --name acme --root /srv/acme --org acme-gh --server '' --user-language Polish >"$TMP/out" 2>&1; }

t_renders_everything() {
  init_acme
  check "init exits 0" test "$?" -eq 0
  check "no known placeholder left" not known_left
  check "no path with a placeholder left" not renamed_path_left
  check "settings.json is valid JSON" jq -e . "$SYNC_HOME/store/.claude/settings.json" >/dev/null
  check "settings default mode is default" \
    jq -e '.permissions.defaultMode == "default"' "$SYNC_HOME/store/.claude/settings.json" >/dev/null
  check "skill dir renamed" test -d "$SYNC_HOME/store/.claude/skills/acme-recipes"
  check "skill name rendered" \
    grep -q '^name: acme-recipes$' "$SYNC_HOME/store/.claude/skills/acme-recipes/SKILL.md"
  check "memory dir uses PROJECT_KEY" test -f "$SYNC_HOME/store/.claude/projects/-srv-acme/memory/MEMORY.md"
  check "agent-sync.env written" grep -Eq '^PROJECT_NAME="acme"' "$SYNC_HOME/agent-sync.env"
  check "env has the root" grep -Eq '^PROJECT_ROOT="/srv/acme"' "$SYNC_HOME/agent-sync.env"
}

t_idempotent() {
  init_acme
  git -C "$SYNC_HOME" add -A; git -C "$SYNC_HOME" commit -qm rendered
  "$SCRIPT" init --name acme --root /srv/acme --org acme-gh --server '' --user-language Polish >"$TMP/out2" 2>&1
  check "second run exits 0" test "$?" -eq 0
  check "second run changes nothing" test -z "$(git -C "$SYNC_HOME" status --porcelain)"
}

t_idempotent_from_env_file() {
  init_acme
  git -C "$SYNC_HOME" add -A; git -C "$SYNC_HOME" commit -qm rendered
  "$SCRIPT" init >"$TMP/out2" 2>&1
  check "run without flags uses agent-sync.env" test "$?" -eq 0
  check "and changes nothing" test -z "$(git -C "$SYNC_HOME" status --porcelain)"
}

t_missing_value() {
  "$SCRIPT" init --name acme </dev/null >"$TMP/out" 2>&1
  check "missing root non-interactively fails" test "$?" -ne 0
  check "nothing changed" test -z "$(git -C "$SYNC_HOME" status --porcelain)"
  check "error names the missing value" grep -qi 'root' "$TMP/out"
}

t_user_language() {
  local a="$SYNC_HOME/store/.claude/AGENTS.md" c="$SYNC_HOME/store/.claude/skills/acme-clickup-docs/SKILL.md"
  init_acme
  check "AGENTS.md names the language" grep -q "native language is Polish" "$a"
  check "AGENTS.md names only the chosen language" grep -c 'native language is Polish' "$a" | grep -qx 1
  check "AGENTS.md has no Russian" not grep -q Russian "$a"
  check "AGENTS.md has no placeholder left" not grep -q '{{USER_LANGUAGE}}' "$a"
  check "clickup-docs skill has no Russian" not grep -q Russian "$c"
  check "clickup-docs skill uses the language" grep -q 'chat with the user is in Polish' "$c"
  check "language stored in env" grep -Eq '^USER_LANGUAGE="Polish"' "$SYNC_HOME/agent-sync.env"
}

t_user_language_missing() {
  "$SCRIPT" init --name acme --root /srv/acme --org acme-gh --server '' </dev/null >"$TMP/out" 2>&1
  check "missing language non-interactively fails" test "$?" -ne 0
  check "nothing changed" test -z "$(git -C "$SYNC_HOME" status --porcelain)"
  check "error names the language" grep -qi 'language' "$TMP/out"
}

t_user_language_from_env_file() {
  init_acme
  git -C "$SYNC_HOME" add -A; git -C "$SYNC_HOME" commit -qm rendered
  "$SCRIPT" init </dev/null >"$TMP/out2" 2>&1
  check "rerun without flag reads the language from the env file" test "$?" -eq 0
}

t_project_key() {
  init_acme
  check "PROJECT_KEY of /srv/acme" test -d "$SYNC_HOME/store/.claude/projects/-srv-acme"
}

t_unknown_placeholder_kept() {
  printf 'x {{SOMETHING_ELSE}} y\n' > "$SYNC_HOME/store/.claude/skills/probe.md"
  init_acme
  check "unknown placeholder left as is" grep -q '{{SOMETHING_ELSE}}' "$SYNC_HOME/store/.claude/skills/probe.md"
  check "init still succeeds" test -f "$SYNC_HOME/agent-sync.env"
}

t_clickup_warns_only() {
  init_acme
  check "clickup placeholders do not fail init" test -d "$SYNC_HOME/store/.claude/skills/acme-clickup-docs"
  check "warning mentions CLICKUP" grep -q 'CLICKUP' "$TMP/out"
}

t_binary_untouched() {
  printf '\x00\x01{{PROJECT_NAME}}\x00' > "$SYNC_HOME/store/.claude/skills/blob.bin"
  local before; before="$(cksum < "$SYNC_HOME/store/.claude/skills/blob.bin")"
  init_acme
  check "binary file is not rewritten" test "$(cksum < "$SYNC_HOME/store/.claude/skills/blob.bin")" = "$before"
}

t_root_claude_md() {
  mkdir -p "$TMP/work"
  "$SCRIPT" init --name acme --root "$TMP/work" --org acme-gh --server '' --user-language Polish >"$TMP/out" 2>&1
  check "root CLAUDE.md created when the root exists" grep -q 'acme workspace' "$TMP/work/CLAUDE.md"
  printf 'mine\n' > "$TMP/work/CLAUDE.md"
  "$SCRIPT" init >"$TMP/out" 2>&1
  check "existing root CLAUDE.md is not overwritten" grep -qx mine "$TMP/work/CLAUDE.md"
}

t_server_rendered() {
  "$SCRIPT" init --name acme --root /srv/acme --org acme-gh --server nas --user-language Polish >"$TMP/out" 2>&1
  check "server stored in env" grep -Eq '^SYNC_SERVER="nas"' "$SYNC_HOME/agent-sync.env"
  check "settings do not name a sync server" not grep -q 'sync server' "$SYNC_HOME/store/.claude/settings.json"
}

t_base_branch_from_root() {
  git init -q -b develop "$TMP/proj"
  git -C "$TMP/proj" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
  "$SCRIPT" init --name acme --root "$TMP/proj" --org acme --server '' --user-language Polish >"$TMP/out" 2>&1
  check "base branch comes from the project root" \
    grep -Eq '^PROJECT_BASE_BRANCH="develop"' "$SYNC_HOME/agent-sync.env"
}

t_install_runs_init() {
  # install must not link a store that still has placeholders: it renders first
  PROJECT_NAME=acme PROJECT_ROOT=/srv/acme PROJECT_GIT_ORG=acme-gh USER_LANGUAGE=Polish \
    "$SCRIPT" install </dev/null >"$TMP/out" 2>&1
  check "install rendered the store" not known_left
}

for t in t_renders_everything t_idempotent t_idempotent_from_env_file t_missing_value \
         t_user_language t_user_language_missing t_user_language_from_env_file \
         t_project_key t_unknown_placeholder_kept t_clickup_warns_only t_binary_untouched \
         t_root_claude_md t_server_rendered t_base_branch_from_root t_install_runs_init; do
  run_test "$t" "$t"
done

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
