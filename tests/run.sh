#!/usr/bin/env bash
# Tests for agent-sync.sh. Everything runs on a fake HOME and a local bare repo,
# the home server and the network are not needed.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/bin/agent-sync.sh"
PASS=0; FAIL=0

# Isolation from user settings: own git identity and no ~/.gitconfig
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }

check() { # check <description> <condition...>
  local d="$1"; shift
  if "$@"; then ok "$d"; else fail "$d" "condition not met: $*"; fi
}

# Clean world: a fake HOME and a bare repo in the role of the home server.
setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  export SYNC_HOME="$HOME/.agent-sync"
  export REMOTE="$TMP/remote.git"
  mkdir -p "$HOME"
  git init --bare -q -b main "$REMOTE"
}

teardown() { rm -rf "$TMP"; }

# Second machine: a separate clone of the same bare repo
second_machine() { git clone -q "$REMOTE" "$TMP/other"; }

# Writes sync.conf into the repo (lines are passed as arguments)
conf() {
  mkdir -p "$SYNC_HOME"
  printf '%s\n' "$@" > "$SYNC_HOME/sync.conf"
}

run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

# --- 1. the default config is created by itself ------------------------------
t_default_conf() {
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  check "sync.conf created" test -f "$SYNC_HOME/sync.conf"
  check "it has the claude path" \
    grep -q '^\.claude/' "$SYNC_HOME/sync.conf"
  check "the config is in the repository (it will reach the second machine)" \
    git -C "$SYNC_HOME" ls-files --error-unmatch sync.conf >/dev/null 2>&1
}

# --- 2. install adopts what the config lists ----------------------------------
t_install_adopts() {
  mkdir -p "$HOME/.claude/hooks"
  printf 'my rules\n' > "$HOME/.claude/CLAUDE.md"
  printf 'hook\n'        > "$HOME/.claude/hooks/h.sh"
  conf '.claude/CLAUDE.md' '.claude/hooks'

  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1

  check "file became a symlink" test -L "$HOME/.claude/CLAUDE.md"
  check "content survived" grep -qx 'my rules' "$HOME/.claude/CLAUDE.md"
  check "path in the repo repeats the path in HOME" \
    test -f "$SYNC_HOME/store/.claude/CLAUDE.md"
  check "directory became a symlink" test -L "$HOME/.claude/hooks"
  check "directory content survived" test -f "$HOME/.claude/hooks/h.sh"
}

# --- 3. no tie to Claude: any agent from the config ---------------------------
t_any_agent() {
  mkdir -p "$HOME/.cursor/rules" "$HOME/.config/mimo"
  printf 'rule\n' > "$HOME/.cursor/rules/r.md"
  printf 'cfg\n'  > "$HOME/.config/mimo/config.json"
  conf '.cursor/rules' '.config/mimo/config.json'

  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1

  check "cursor adopted" test -L "$HOME/.cursor/rules"
  check "mimo adopted"   test -L "$HOME/.config/mimo/config.json"
  check "both are in the repository" \
    test -f "$SYNC_HOME/store/.cursor/rules/r.md" -a \
         -f "$SYNC_HOME/store/.config/mimo/config.json"
}

# --- 4. glob expands to all matches ------------------------------------------
t_glob() {
  mkdir -p "$HOME/.claude/projects/-proj-a/memory" \
           "$HOME/.claude/projects/-proj-b/memory"
  printf 'a\n' > "$HOME/.claude/projects/-proj-a/memory/MEMORY.md"
  printf 'b\n' > "$HOME/.claude/projects/-proj-b/memory/MEMORY.md"
  conf '.claude/projects/*/memory'

  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1

  check "first project adopted" test -L "$HOME/.claude/projects/-proj-a/memory"
  check "second project adopted" test -L "$HOME/.claude/projects/-proj-b/memory"
  check "memory is readable through the symlink" \
    grep -qx 'b' "$HOME/.claude/projects/-proj-b/memory/MEMORY.md"
  check "extra things from projects/ are not synced" \
    test ! -e "$SYNC_HOME/store/.claude/projects/-proj-a/session.jsonl"
}

# --- 5. a line with ! excludes a glob match ----------------------------------
t_exclude() {
  mkdir -p "$HOME/.claude/projects/-proj-a/memory" \
           "$HOME/.claude/projects/-secret/memory"
  printf 'a\n' > "$HOME/.claude/projects/-proj-a/memory/MEMORY.md"
  printf 's\n' > "$HOME/.claude/projects/-secret/memory/MEMORY.md"
  conf '.claude/projects/*/memory' '!.claude/projects/-secret/memory'

  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1

  check "regular project adopted" test -L "$HOME/.claude/projects/-proj-a/memory"
  check "excluded one untouched" \
    test ! -L "$HOME/.claude/projects/-secret/memory"
  check "excluded one is not in the repository" \
    test ! -e "$SYNC_HOME/store/.claude/projects/-secret"
}

# --- 6. a line added to the config is picked up without editing the script ----
t_conf_extended() {
  printf 'one\n' > "$HOME/.first"
  conf '.first'
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1

  printf 'two\n' > "$HOME/.second"
  printf '%s\n' '.second' >> "$SYNC_HOME/sync.conf"

  "$SCRIPT" sync >/dev/null 2>&1

  check "new entry adopted" test -L "$HOME/.second"
  check "and went to the server" \
    git --git-dir="$REMOTE" show 'HEAD:store/.second' >/dev/null 2>&1
}

# --- 7. new machine: in the repo, not local — a symlink is created -----------
t_new_machine() {
  printf 'from repo\n' > "$HOME/.claude-md-source"
  conf '.config/agent/rules.md'
  mkdir -p "$SYNC_HOME/store/.config/agent"
  printf 'arrived\n' > "$SYNC_HOME/store/.config/agent/rules.md"

  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1

  check "symlink created" test -L "$HOME/.config/agent/rules.md"
  check "parent directories created" test -d "$HOME/.config/agent"
  check "content from the repository" \
    grep -qx 'arrived' "$HOME/.config/agent/rules.md"
}

# --- 8. what is neither here nor there is skipped without empty stubs --------
t_missing_skipped() {
  conf '.nothing/here.json'
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  check "empty directory not created" test ! -e "$HOME/.nothing"
  check "no stub in the repository" test ! -e "$SYNC_HOME/store/.nothing"
}

# --- 9. push uploads the changes ---------------------------------------------
t_push() {
  printf 'v1\n' > "$HOME/.claude-cfg"
  conf '.claude-cfg'
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  printf 'v2\n' > "$HOME/.claude-cfg"

  "$SCRIPT" push >/dev/null 2>&1

  check "new version on the server" \
    test "$(git --git-dir="$REMOTE" show 'HEAD:store/.claude-cfg')" = v2
}

# --- 10. push without changes makes no empty commits --------------------------
t_push_noop() {
  printf 'v1\n' > "$HOME/.claude-cfg"
  conf '.claude-cfg'
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  "$SCRIPT" push >/dev/null 2>&1
  local before; before="$(git --git-dir="$REMOTE" rev-list --count HEAD)"
  "$SCRIPT" push >/dev/null 2>&1
  local after;  after="$(git --git-dir="$REMOTE" rev-list --count HEAD)"
  check "commit count did not grow" test "$before" = "$after"
}

# --- 11. pull fetches an edit from the second machine -------------------------
t_pull() {
  printf 'v1\n' > "$HOME/.claude-cfg"
  conf '.claude-cfg'
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  "$SCRIPT" push >/dev/null 2>&1

  second_machine
  printf 'from second machine\n' > "$TMP/other/store/.claude-cfg"
  git -C "$TMP/other" commit -qam "edit from second machine"
  git -C "$TMP/other" push -q origin HEAD

  "$SCRIPT" pull >/dev/null 2>&1

  check "edit is visible through the symlink" \
    grep -qx 'from second machine' "$HOME/.claude-cfg"
}

# --- 12. diverged machines are merged by rebase, both edits survive ----------
t_diverged_rebase() {
  mkdir -p "$HOME/.claude/projects/-proj-a/memory"
  printf 'shared\n' > "$HOME/.claude/projects/-proj-a/memory/MEMORY.md"
  conf '.claude/projects/*/memory'
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  "$SCRIPT" push >/dev/null 2>&1

  second_machine
  printf 'their fact\n' > "$TMP/other/store/.claude/projects/-proj-a/memory/theirs.md"
  git -C "$TMP/other" add -A
  git -C "$TMP/other" commit -qm "their fact"
  git -C "$TMP/other" push -q origin HEAD

  printf 'my fact\n' > "$HOME/.claude/projects/-proj-a/memory/mine.md"

  "$SCRIPT" sync >/dev/null 2>&1

  check "own edit in place" \
    test -f "$HOME/.claude/projects/-proj-a/memory/mine.md"
  check "their edit arrived" \
    test -f "$HOME/.claude/projects/-proj-a/memory/theirs.md"
  check "both went to the server" \
    git --git-dir="$REMOTE" show 'HEAD:store/.claude/projects/-proj-a/memory/mine.md' >/dev/null 2>&1
}

# --- 13. server unreachable: commit locally, exit without error --------------
t_offline() {
  printf 'v1\n' > "$HOME/.claude-cfg"
  conf '.claude-cfg'
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  "$SCRIPT" push >/dev/null 2>&1

  git -C "$SYNC_HOME" remote set-url origin "$TMP/no-such.git"
  printf 'offline-edit\n' > "$HOME/.claude-cfg"

  "$SCRIPT" sync >/dev/null 2>&1
  local rc=$?

  check "exit without error (timer does not spam)" test "$rc" -eq 0
  check "edit saved as a local commit" \
    test "$(git -C "$SYNC_HOME" show 'HEAD:store/.claude-cfg' 2>/dev/null)" = offline-edit
  check "edit not lost" grep -qx 'offline-edit' "$HOME/.claude-cfg"
}

# --- 14. a broken symlink is replaced by a working one ------------------------
t_broken_symlink() {
  ln -s "$TMP/no-file" "$HOME/.claude-cfg"
  conf '.claude-cfg'
  mkdir -p "$SYNC_HOME/store"
  printf 'from repo\n' > "$SYNC_HOME/store/.claude-cfg"

  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1

  check "target exists" test -e "$HOME/.claude-cfg"
  check "target leads into the repository" \
    test "$(readlink "$HOME/.claude-cfg")" = "$SYNC_HOME/store/.claude-cfg"
}

t_symlink_without_store() {
  ln -s "$TMP/keep-me" "$HOME/.claude-cfg"
  conf '.claude-cfg'
  mkdir -p "$SYNC_HOME/store"
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  check "user symlink kept" test -L "$HOME/.claude-cfg"
  check "user symlink target kept" test "$(readlink "$HOME/.claude-cfg")" = "$TMP/keep-me"
}

# --- 15. install is idempotent -------------------------------------------------
t_idempotent() {
  printf 'x\n' > "$HOME/.claude-cfg"
  conf '.claude-cfg'
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  check "symlink not broken" test -L "$HOME/.claude-cfg"
  check "content in place" grep -qx 'x' "$HOME/.claude-cfg"
  check "no nested duplicate" test ! -e "$SYNC_HOME/store/.claude-cfg/.claude-cfg"
}

# --- 17. install puts the commands into PATH ----------------------------------
# The README promises a bare `agent-sessions`, not a path to bin/, so install
# must create the symlinks itself, otherwise they are set by hand on every new machine.
t_cli_links() {
  conf '.claude-cfg'
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1

  check "agent-sessions in PATH" test -x "$HOME/.local/bin/agent-sessions"
  check "leads to the repository script" \
    test "$(readlink "$HOME/.local/bin/agent-sessions")" = "$(dirname "$SCRIPT")/agent-sessions.sh"
  check "the familiar name with .sh works too" test -x "$HOME/.local/bin/agent-sessions.sh"
  check "register-me in PATH" test -x "$HOME/.local/bin/register-me"
  check "check.sh does not take the generic name check" test ! -e "$HOME/.local/bin/check"
  check "check.sh is available under its own name" test -x "$HOME/.local/bin/agent-sync-check"
}

# --- 18. a repeated install does not break already created commands -----------
t_cli_links_idempotent() {
  conf '.claude-cfg'
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1

  check "symlink intact" test -x "$HOME/.local/bin/agent-sessions"
  check "no nested duplicate" test ! -e "$HOME/.local/bin/agent-sessions/agent-sessions"
}

# --- 19. a foreign file with the same name is not overwritten -----------------
# ~/.local/bin also holds unrelated programs: silently overwriting someone's
# binary means losing it without a trace.
t_cli_links_keep_foreign() {
  conf '.claude-cfg'
  mkdir -p "$HOME/.local/bin"
  printf 'foreign\n' > "$HOME/.local/bin/agent-sessions"

  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1

  check "foreign file in place" grep -qx 'foreign' "$HOME/.local/bin/agent-sessions"
}

# --- 20. commands work through a symlink, not only by the full path -----------
# Scripts look for their neighbors and the manifest relative to themselves. Through a symlink in
# ~/.local/bin "next to" is no longer the repository, so the path must be resolved.
t_cli_links_work() {
  conf '.claude-cfg'
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  local bin="$HOME/.local/bin"

  check "tools-check finds the manifest" \
    bash -c "! '$bin/tools-check' 2>&1 | grep -q 'no manifest'"

  # agent-sync through a symlink must link from the repository, not from ~/.local/bin
  rm -f "$bin/agent-sessions"
  "$bin/agent-sync" install >/dev/null 2>&1
  check "agent-sync through a symlink links from the repository" \
    test "$(readlink "$bin/agent-sessions")" = "$(dirname "$SCRIPT")/agent-sessions.sh"

  check "register-me through a symlink reaches session-record" \
    bash -c "! SESSIONS_DIR='$HOME/s' '$bin/register-me' --id abc 'probe' 2>&1 | grep -q 'session-record.sh'"
}

# --- 21. install does not sweep up someone's work in the repository ----------
# The tool itself lives in this same repository. `git add -A` on install carried off
# an uncommitted edit of bin/ or README into a nameless "sync <machine>" commit.
# Adopting configs is about store, so limit it to that.
t_install_commits_only_store() {
  printf 'x\n' > "$HOME/.claude-cfg"
  conf '.claude-cfg'
  mkdir -p "$SYNC_HOME"
  printf 'my uncommitted edit\n' > "$SYNC_HOME/README.md"

  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1

  check "adopted config is committed" \
    git -C "$SYNC_HOME" cat-file -e HEAD:store/.claude-cfg
  check "tool edit stayed with me" \
    grep -qx 'my uncommitted edit' "$SYNC_HOME/README.md"
  check "and was not pulled into the commit" \
    bash -c "! git -C '$SYNC_HOME' cat-file -e HEAD:README.md 2>/dev/null"
}

# --- 16. an edit outside store does not break the merge with the server ------
# The tool itself (bin/, tests/, README) lives in this same repository. If its
# edit is not committed, the tree stays dirty and rebase fails.
t_dirty_outside_store() {
  printf 'v1\n' > "$HOME/.claude-cfg"
  conf '.claude-cfg'
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  "$SCRIPT" push >/dev/null 2>&1

  # a foreign commit on the server means sync will really merge branches
  second_machine
  printf 'their edit\n' > "$TMP/other/store/.claude-cfg"
  git -C "$TMP/other" commit -qam "edit from second machine"
  git -C "$TMP/other" push -q origin HEAD

  # an uncommitted tool edit next to store
  printf 'docs\n' > "$SYNC_HOME/README.md"

  "$SCRIPT" sync >/dev/null 2>&1

  check "tree merged, nothing hangs" \
    test -z "$(git -C "$SYNC_HOME" status --porcelain)"
  check "their edit arrived" grep -qx 'their edit' "$HOME/.claude-cfg"
  check "tool edit not lost" \
    grep -qx 'docs' "$SYNC_HOME/README.md"
  check "tool edit went to the server" \
    git --git-dir="$REMOTE" show HEAD:README.md >/dev/null 2>&1
}

# --- 22. the app rewrote the symlink with its own file: we take the edit -----
# Cursor and similar apps write the config atomically (temp + rename) and so remove the symlink.
t_app_overwrites_symlink() {
  printf 'shared\n' > "$HOME/.cfg"
  conf '.cfg'
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  "$SCRIPT" install --adopt --remote "$REMOTE" >/dev/null 2>&1

  rm "$HOME/.cfg"
  printf 'app edit\n' > "$HOME/.cfg"   # a regular file over the symlink
  touch "$HOME/.cfg"

  "$SCRIPT" sync >/dev/null 2>&1

  check "symlink restored" test -L "$HOME/.cfg"
  check "app edit reached store" \
    grep -qx 'app edit' "$SYNC_HOME/store/.cfg"
  check "no .local-* copy is created" \
    test -z "$(find "$HOME" -maxdepth 1 -name '.cfg.local-*')"
  local on_server; on_server="$(git --git-dir="$REMOTE" show 'HEAD:store/.cfg' 2>/dev/null)"
  check "edit went to the server" test "$on_server" = 'app edit'
}

# --- 23. the version in the repository is newer than the local one: keep the local one ---
t_store_newer_keeps_local_copy() {
  printf 'local\n' > "$HOME/.cfg"
  conf '.cfg'
  mkdir -p "$SYNC_HOME/store"
  printf 'arrived from server\n' > "$SYNC_HOME/store/.cfg"
  touch "$SYNC_HOME/store/.cfg"          # store is newer than the local file

  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1

  check "local file left in place" test ! -L "$HOME/.cfg"
  check "local content kept" grep -qx 'local' "$HOME/.cfg"
  check "no .local copy" test -z "$(find "$HOME" -maxdepth 1 -name '.cfg.local-*')"
}

t_adopt_replaces_when_asked() {
  printf 'local\n' > "$HOME/.cfg"
  conf '.cfg'
  mkdir -p "$SYNC_HOME/store"
  printf 'arrived from server\n' > "$SYNC_HOME/store/.cfg"
  touch "$SYNC_HOME/store/.cfg"

  "$SCRIPT" install --adopt --remote "$REMOTE" >/dev/null 2>&1

  check "the repository version won" \
    grep -qx 'arrived from server' "$HOME/.cfg"
  check "local version set aside in .local-*" \
    test -n "$(find "$HOME" -maxdepth 1 -name '.cfg.local-*')"
}

# --- 24. same content: just a symlink, no copies ------------------------------
t_same_content_no_copy() {
  printf 'same content\n' > "$HOME/.cfg"
  conf '.cfg'
  mkdir -p "$SYNC_HOME/store"
  printf 'same content\n' > "$SYNC_HOME/store/.cfg"
  touch "$SYNC_HOME/store/.cfg"

  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1

  check "became a symlink" test -L "$HOME/.cfg"
  check "no copy created" \
    test -z "$(find "$HOME" -maxdepth 1 -name '.cfg.local-*')"
}

# --- 25. sync is stuck: after three failures in a row we notify the desktop --
t_rebase_failure_notifies() {
  mkdir -p "$TMP/bin"
  local n  # notify-send on Linux, osascript on macOS
  for n in notify-send osascript; do
    cat > "$TMP/bin/$n" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$NOTIFY_LOG"
STUB
    chmod +x "$TMP/bin/$n"
  done
  export PATH="$TMP/bin:$PATH" NOTIFY_LOG="$TMP/notified"

  printf 'shared\n' > "$HOME/.cfg"
  conf '.cfg'
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  "$SCRIPT" push >/dev/null 2>&1

  # both sides edit one file differently — rebase cannot merge
  second_machine
  printf 'theirs\n' > "$TMP/other/store/.cfg"
  git -C "$TMP/other" commit -qam "their edit"
  git -C "$TMP/other" push -q origin HEAD
  printf 'mine\n' > "$HOME/.cfg"

  "$SCRIPT" sync >/dev/null 2>&1
  check "silent after the first failure" test ! -s "$TMP/notified"
  "$SCRIPT" sync >/dev/null 2>&1
  check "silent after the second too" test ! -s "$TMP/notified"
  "$SCRIPT" sync >/dev/null 2>&1
  check "notified after the third" test -s "$TMP/notified"

  local dirty; dirty="$(git -C "$SYNC_HOME" status --porcelain)"
  check "the counter does not go into the repository" \
    test -z "$(printf '%s' "$dirty" | grep -e 'rebase-fail' -e 'sync-fail')"
}

notify_stub() {
  mkdir -p "$TMP/bin"
  local n  # notify-send on Linux, osascript on macOS
  for n in notify-send osascript; do
    cat > "$TMP/bin/$n" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$NOTIFY_LOG"
STUB
    chmod +x "$TMP/bin/$n"
  done
  export PATH="$TMP/bin:$PATH" NOTIFY_LOG="$TMP/notified"
}

# --- 25b. a staged secret is not committed ------------------------------------
t_secret_blocks_commit() {
  notify_stub
  conf '.cfg'
  printf 'x\n' > "$HOME/.cfg"
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  local key="AKIA""ABCDEFGHIJKLMNOP"
  printf 'key=%s\n' "$key" > "$HOME/.cfg"
  "$SCRIPT" sync >"$TMP/out" 2>&1 || true
  if git -C "$SYNC_HOME" grep -q "$key" HEAD; then fail "secret not committed" "key is in HEAD"; else ok "secret not committed"; fi
  check "refusal is logged" grep -q 'refused commit' "$TMP/out"
  check "desktop notification" test -s "$TMP/notified"
}

# --- 26. push rejected by the server: three times in a row — notification ----
t_push_failure_notifies() {
  notify_stub
  printf 'v1\n' > "$HOME/.cfg"
  conf '.cfg'
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  "$SCRIPT" push >/dev/null 2>&1

  printf '#!/bin/sh\nexit 1\n' > "$REMOTE/hooks/pre-receive"
  chmod +x "$REMOTE/hooks/pre-receive"
  printf 'v2\n' > "$HOME/.cfg"

  "$SCRIPT" sync >/dev/null 2>&1
  "$SCRIPT" sync >/dev/null 2>&1
  check "silent after two push rejections" test ! -s "$TMP/notified"
  "$SCRIPT" sync >/dev/null 2>&1
  check "notified after the third push rejection" test -s "$TMP/notified"
}

# --- 27. fetch fails while the server is up: three times in a row — notification ---
t_fetch_failure_notifies() {
  notify_stub
  printf 'v1\n' > "$HOME/.cfg"
  conf '.cfg'
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  "$SCRIPT" push >/dev/null 2>&1

  second_machine
  printf 'v2\n' > "$TMP/other/store/.cfg"
  git -C "$TMP/other" commit -qam "their edit"
  git -C "$TMP/other" push -q origin HEAD

  # as in real life: the local commit turned into an empty file, ls-remote passes anyway
  local head obj
  head="$(git -C "$SYNC_HOME" rev-parse HEAD)"
  obj="$SYNC_HOME/.git/objects/${head:0:2}/${head:2}"
  chmod u+w "$obj"; : > "$obj"
  "$SCRIPT" sync >/dev/null 2>&1
  "$SCRIPT" sync >/dev/null 2>&1
  check "silent after two fetch failures" test ! -s "$TMP/notified"
  "$SCRIPT" sync >/dev/null 2>&1
  check "notified after the third fetch failure" test -s "$TMP/notified"
}

# --- 28. the server is simply off: however many tries — no notification ------
t_offline_never_notifies() {
  notify_stub
  printf 'v1\n' > "$HOME/.cfg"
  conf '.cfg'
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  "$SCRIPT" push >/dev/null 2>&1

  git -C "$SYNC_HOME" remote set-url origin "$TMP/no-such.git"
  printf 'v2\n' > "$HOME/.cfg"
  local i; for i in 1 2 3 4; do "$SCRIPT" sync >/dev/null 2>&1; done
  check "a switched-off NAS is not a breakage" test ! -s "$TMP/notified"
}

# --- 29. a successful push resets the failure counter -------------------------
t_success_resets_failures() {
  notify_stub
  printf 'v1\n' > "$HOME/.cfg"
  conf '.cfg'
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  "$SCRIPT" push >/dev/null 2>&1

  printf '#!/bin/sh\nexit 1\n' > "$REMOTE/hooks/pre-receive"
  chmod +x "$REMOTE/hooks/pre-receive"
  printf 'v2\n' > "$HOME/.cfg"
  "$SCRIPT" sync >/dev/null 2>&1
  "$SCRIPT" sync >/dev/null 2>&1

  rm -f "$REMOTE/hooks/pre-receive"
  "$SCRIPT" sync >/dev/null 2>&1

  printf '#!/bin/sh\nexit 1\n' > "$REMOTE/hooks/pre-receive"
  chmod +x "$REMOTE/hooks/pre-receive"
  printf 'v3\n' > "$HOME/.cfg"
  "$SCRIPT" sync >/dev/null 2>&1
  "$SCRIPT" sync >/dev/null 2>&1
  check "two failures after a success — not yet a notification" test ! -s "$TMP/notified"
}

# --- 30. /model on two machines: the "model" conflict resolves itself ---------
t_model_conflict_resolved() {
  mkdir -p "$HOME/.claude"
  printf '{\n  "a": 1,\n  "model": "sonnet",\n  "b": 2\n}\n' > "$HOME/.claude/settings.json"
  conf '.claude/settings.json'
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  "$SCRIPT" push >/dev/null 2>&1

  second_machine
  printf '{\n  "a": 10,\n  "model": "opus",\n  "b": 2\n}\n' > "$TMP/other/store/.claude/settings.json"
  git -C "$TMP/other" commit -qam "other machine edit"
  git -C "$TMP/other" push -q origin HEAD

  printf '{\n  "a": 1,\n  "model": "fable",\n  "b": 2\n}\n' > "$HOME/.claude/settings.json"

  "$SCRIPT" sync >/dev/null 2>&1

  check "rebase is not stuck" test ! -d "$SYNC_HOME/.git/rebase-merge"
  check "model is the local one" grep -q '"model": "fable"' "$HOME/.claude/settings.json"
  check "the other machine's edit of another key arrived" grep -q '"a": 10' "$HOME/.claude/settings.json"
  check "the server also has the merged version" \
    sh -c "git --git-dir='$REMOTE' show HEAD:store/.claude/settings.json | grep -q '\"a\": 10'"
}

run_test "an edit outside store does not break the merge"       t_dirty_outside_store
run_test "the default config is created by itself"            t_default_conf
run_test "install adopts the config entries"          t_install_adopts
run_test "works for any agent, not only Claude" t_any_agent
run_test "glob expands to all matches"      t_glob
run_test "a line with ! excludes a match"            t_exclude
run_test "an added config line is picked up"  t_conf_extended
run_test "new machine: symlink to what came from the repo" t_new_machine
run_test "a missing entry is skipped without stubs"    t_missing_skipped
run_test "push uploads the changes"                    t_push
run_test "push without changes does nothing"        t_push_noop
run_test "pull fetches a foreign edit"              t_pull
run_test "divergence is merged by rebase"             t_diverged_rebase
run_test "offline: commit locally, exit 0"           t_offline
run_test "a broken symlink is replaced by a working one"           t_broken_symlink
run_test "a symlink with nothing in the repo is kept"        t_symlink_without_store
run_test "install is idempotent"                       t_idempotent
run_test "install puts the commands into PATH"              t_cli_links
run_test "a repeated install does not break the commands"        t_cli_links_idempotent
run_test "a foreign file in ~/.local/bin is not overwritten"    t_cli_links_keep_foreign
run_test "commands work through a symlink"             t_cli_links_work
run_test "install commits only store"              t_install_commits_only_store
run_test "the app rewrote the symlink — we take the edit" t_app_overwrites_symlink
run_test "the repository version is newer — install leaves the local file" t_store_newer_keeps_local_copy
t_sync_waits_for_adopt() {
  printf 'local\n' > "$HOME/.cfg"
  conf '.cfg'
  mkdir -p "$SYNC_HOME/store"
  printf 'repo\n' > "$SYNC_HOME/store/.cfg"
  touch "$SYNC_HOME/store/.cfg"
  "$SCRIPT" install --remote "$REMOTE" >/dev/null 2>&1
  "$SCRIPT" sync >/dev/null 2>&1
  check "sync left the differing file" test ! -L "$HOME/.cfg"
  check "pending flag is set" test -f "$SYNC_HOME/.link-adopt-pending"
  "$SCRIPT" install --adopt --remote "$REMOTE" >/dev/null 2>&1
  check "adopt removed the pending flag" test ! -f "$SYNC_HOME/.link-adopt-pending"
  check "adopt recorded the opt-in" test -f "$SYNC_HOME/.link-adopt"
  check "repository version linked" grep -qx 'repo' "$HOME/.cfg"
  check "file is a symlink" test -L "$HOME/.cfg"
}

t_first_adopt_keeps_repo_when_local_is_newer() {
  printf 'local edit\n' > "$HOME/.cfg"
  conf '.cfg'
  mkdir -p "$SYNC_HOME/store"
  printf 'template\n' > "$SYNC_HOME/store/.cfg"
  touch "$HOME/.cfg"
  "$SCRIPT" install --adopt --remote "$REMOTE" >/dev/null 2>&1
  check "repo copy stayed in the store" grep -qx 'template' "$SYNC_HOME/store/.cfg"
  check "linked file is the repo copy" grep -qx 'template' "$HOME/.cfg"
  check "local edit was backed up" test -n "$(find "$HOME" -maxdepth 1 -name '.cfg.local-*')"
  check "backup has the local edit" grep -qx 'local edit' "$HOME"/.cfg.local-*
}

run_test "install --adopt switches to the repository copy" t_adopt_replaces_when_asked
run_test "first --adopt keeps a newer local file aside" t_first_adopt_keeps_repo_when_local_is_newer
run_test "sync does not adopt until install --adopt" t_sync_waits_for_adopt
run_test "same content — no copies"     t_same_content_no_copy
run_test "three merge failures in a row — notification"  t_rebase_failure_notifies
run_test "a staged secret is not committed"                 t_secret_blocks_commit
run_test "three push rejections in a row — notification"       t_push_failure_notifies
run_test "three fetch failures in a row — notification"     t_fetch_failure_notifies
run_test "a switched-off server does not notify"           t_offline_never_notifies
run_test "a successful push resets the counter"       t_success_resets_failures
run_test "a conflict on \"model\" in settings.json resolves itself" t_model_conflict_resolved

printf '\ntotal: %d ok, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
