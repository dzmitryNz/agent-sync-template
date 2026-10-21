#!/usr/bin/env bash
# Tests for wt-install.sh — installing node_modules in a git worktree via pnpm.
# pnpm is replaced by a fake that writes calls to a log; no network needed.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/bin/wt-install.sh"
PASS=0; FAIL=0

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "failed: $*"; fi; }
not() { ! "$@"; }
real_dir() { [ -d "$1" ] && [ ! -L "$1" ]; }

setup() {
  TMP="$(cd "$(mktemp -d)" && pwd -P)"  # macOS: /var is a symlink to /private/var
  LOG="$TMP/pnpm.log"
  mkdir -p "$TMP/bin"
  # fake pnpm: a call log; import notes whether there was an old lock, and writes a new one
  cat > "$TMP/bin/pnpm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LOG"
case "\$1" in
  import)  [ -e pnpm-lock.yaml ] && echo "stale-lock-seen" >> "$LOG"; echo new > pnpm-lock.yaml ;;
  install) echo "token=\${NODE_AUTH_TOKEN:-none}" >> "$LOG"; mkdir -p node_modules ;;
esac
EOF
  chmod +x "$TMP/bin/pnpm"
  printf '#!/usr/bin/env bash\n[ "$*" = "auth token" ] && echo tok123\n' > "$TMP/bin/gh"
  chmod +x "$TMP/bin/gh"
  export HOME="$TMP/home"; mkdir -p "$HOME"
  unset NODE_AUTH_TOKEN
  export PATH="$TMP/bin:$PATH"

  MAIN="$TMP/repo"
  git init -q -b main "$MAIN"
  echo '{}' > "$MAIN/package.json"; echo '{}' > "$MAIN/package-lock.json"
  echo 'node_modules' > "$MAIN/.gitignore"
  git -C "$MAIN" add -A; git -C "$MAIN" commit -qm init
  mkdir -p "$MAIN/node_modules"
  WT="$TMP/wt"
  git -C "$MAIN" worktree add -q -b task "$WT"
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

run() { (cd "$WT" && "$SCRIPT" "$@") >"$TMP/out" 2>&1; }
pnpm_called() { [ -s "$LOG" ]; }
exclude_file() { printf '%s' "$(git -C "$MAIN" rev-parse --path-format=absolute --git-common-dir)/info/exclude"; }

t_not_git() {
  mkdir -p "$TMP/plain"; echo '{}' > "$TMP/plain/package-lock.json"
  "$SCRIPT" "$TMP/plain" >"$TMP/out" 2>&1; local rc=$?
  check "not git — non-zero exit"      [ "$rc" -ne 0 ]
  check "not git — pnpm not called"    not pnpm_called
}

t_no_lock() {
  rm "$WT/package-lock.json"
  run; local rc=$?
  check "no package-lock — error"   [ "$rc" -ne 0 ]
  check "no package-lock — pnpm not called" not pnpm_called
}

t_tracked_node_modules() {
  ln -s "$MAIN/node_modules" "$WT/node_modules"
  git -C "$WT" add -f node_modules; git -C "$WT" commit -qm 'tracked nm'
  run; local rc=$?
  check "tracked node_modules — exit 0"      [ "$rc" -eq 0 ]
  check "tracked node_modules — pnpm not called" not pnpm_called
  check "tracked node_modules — message"   grep -q 'node_modules' "$TMP/out"
  check "symlink untouched"                  [ -L "$WT/node_modules" ]
}

t_old_symlink() {
  touch "$MAIN/node_modules/keep"
  ln -s "$MAIN/node_modules" "$WT/node_modules"
  run
  check "symlink replaced by its own folder"   real_dir "$WT/node_modules"
  check "symlink target intact"             [ -f "$MAIN/node_modules/keep" ]
}

t_pnpm_calls() {
  run; local rc=$?
  check "exit 0"                          [ "$rc" -eq 0 ]
  check "pnpm import"                     grep -qx 'import' "$LOG"
  check "install --frozen-lockfile"       grep -q '^install .*--frozen-lockfile' "$LOG"
  check "node-linker=hoisted"             grep -q '^install .*node-linker=hoisted' "$LOG"
  check "import before install"           [ "$(grep -n '^import' "$LOG" | cut -d: -f1)" -lt "$(grep -n '^install' "$LOG" | cut -d: -f1)" ]
}

t_exclude_once() {
  run; run
  check "pnpm-lock.yaml in info/exclude"   grep -qx 'pnpm-lock.yaml' "$(exclude_file)"
  check "line is not duplicated"           [ "$(grep -cx 'pnpm-lock.yaml' "$(exclude_file)")" -eq 1 ]
  check "git status clean"               [ -z "$(git -C "$WT" status --porcelain)" ]
}

t_stale_lock() {
  echo old > "$WT/pnpm-lock.yaml"
  run
  check "existing pnpm lock is not deleted" grep -qx old "$WT/pnpm-lock.yaml"
  check "import is not used when a pnpm lock exists" not grep -qx import "$LOG"
  check "install still runs"               grep -q '^install ' "$LOG"
}

t_pnpm_lock_only() {
  rm "$WT/package-lock.json"
  echo 'lock: 1' > "$WT/pnpm-lock.yaml"
  run; local rc=$?
  check "pnpm lock alone — exit 0"        [ "$rc" -eq 0 ]
  check "pnpm lock alone — not deleted"   grep -qx 'lock: 1' "$WT/pnpm-lock.yaml"
  check "pnpm lock alone — install"       grep -q '^install ' "$LOG"
}

t_auth_from_gh() {
  run; run
  check "pnpm got the token from gh"       grep -qx 'token=tok123' "$LOG"
  check "placeholder in ~/.npmrc"          grep -qxF '//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}' "$HOME/.npmrc"
  check "one placeholder"                [ "$(grep -c npm.pkg.github.com "$HOME/.npmrc")" -eq 1 ]
  check "the token itself is not written to disk"    not grep -q tok123 "$HOME/.npmrc"
}

t_auth_env_kept() {
  NODE_AUTH_TOKEN=preset run
  check "a preset token is not overwritten"      grep -qx 'token=preset' "$LOG"
}

t_allow_builds() {
  run
  check "pnpm-workspace.yaml created"      grep -q '^allowBuilds:' "$WT/pnpm-workspace.yaml"
  check "esbuild allowed"                grep -qF '"esbuild": true' "$WT/pnpm-workspace.yaml"
  check "!pkg — explicit deny"             grep -qF '"core-js": false' "$WT/pnpm-workspace.yaml"
  check "list comments did not get in"    not grep -q '#' "$WT/pnpm-workspace.yaml"
  check "pnpm-workspace.yaml in exclude"   grep -qx 'pnpm-workspace.yaml' "$(exclude_file)"
  check "git status clean"               [ -z "$(git -C "$WT" status --porcelain)" ]
}

t_tracked_workspace() {
  echo "packages: []" > "$WT/pnpm-workspace.yaml"
  git -C "$WT" add pnpm-workspace.yaml; git -C "$WT" commit -qm ws
  run
  check "own pnpm-workspace.yaml untouched" grep -qx 'packages: \[\]' "$WT/pnpm-workspace.yaml"
}

run_test "not a git repository"       t_not_git
run_test "no package-lock.json"    t_no_lock
run_test "node_modules in git"       t_tracked_node_modules
run_test "old symlink"           t_old_symlink
run_test "pnpm calls"              t_pnpm_calls
run_test "info/exclude"             t_exclude_once
run_test "stale pnpm-lock"     t_stale_lock
run_test "pnpm-lock.yaml only"  t_pnpm_lock_only
run_test "token from gh"              t_auth_from_gh
run_test "token from the environment"       t_auth_env_kept
run_test "allowBuilds"              t_allow_builds
t_pnpm_missing() {
  local out rc=0
  # CI runners ship pnpm in /usr/bin or /bin; the case cannot be built there
  if PATH=/usr/bin:/bin command -v pnpm >/dev/null 2>&1; then ok "skip: pnpm is in /usr/bin:/bin"; return; fi
  out="$(NODE_AUTH_TOKEN=test PATH=/usr/bin:/bin "$SCRIPT" "$WT" 2>&1)" || rc=$?
  check "missing pnpm exits 1" [ "$rc" -eq 1 ]
  check "missing pnpm names tools-check" grep -q 'pnpm missing: run bin/tools-check.sh --install' <<<"$out"
}

run_test "pnpm-workspace in git"     t_tracked_workspace
run_test "pnpm missing"              t_pnpm_missing

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
