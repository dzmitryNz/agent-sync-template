#!/usr/bin/env bash
# Tests for wt-new.sh — a worktree for a task with one command.
# origin is a local bare repo, pnpm and gh are replaced by fakes; no network needed.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/bin/wt-new.sh"
PASS=0; FAIL=0

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "failed: $*"; fi; }
not() { ! "$@"; }

setup() {
  TMP="$(cd "$(mktemp -d)" && pwd -P)"  # macOS: /var is a symlink to /private/var
  LOG="$TMP/pnpm.log"
  mkdir -p "$TMP/bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\necho pnpm-noise\n[ "$1" = install ] && mkdir -p node_modules\nexit 0\n' "$LOG" > "$TMP/bin/pnpm"
  printf '#!/usr/bin/env bash\necho tok\n' > "$TMP/bin/gh"
  chmod +x "$TMP/bin/pnpm" "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH" HOME="$TMP/home"
  mkdir -p "$HOME"

  export PROJECT_ROOT="$TMP/proj"
  export PROJECT_BASE_BRANCH=develop
  export WT_SHORT_NAMES_FILE="$TMP/short-names.conf"
  printf "# repo = short\nsvc-a = sa\n" > "$WT_SHORT_NAMES_FILE"
  ORIGIN="$TMP/origin.git"
  git init -q --bare -b develop "$ORIGIN"
  local seed="$TMP/seed"
  git clone -q "$ORIGIN" "$seed" 2>/dev/null
  echo '{}' > "$seed/package.json"; echo '{}' > "$seed/package-lock.json"
  printf 'node_modules\n.env\n' > "$seed/.gitignore"
  git -C "$seed" add -A; git -C "$seed" commit -qm init
  git -C "$seed" push -q origin develop
  git -C "$seed" checkout -q -b feat/pr-branch
  echo pr > "$seed/pr.txt"; git -C "$seed" add pr.txt; git -C "$seed" commit -qm pr
  git -C "$seed" push -q origin feat/pr-branch
  git -C "$seed" checkout -q develop

  REPO="$PROJECT_ROOT/svc-a"
  mkdir -p "$PROJECT_ROOT"
  git clone -q "$ORIGIN" "$REPO"
  echo SECRET=1 > "$REPO/.env"

  # develop on origin moved ahead after the clone — local develop is stale
  echo fresh > "$seed/fresh.txt"; git -C "$seed" add fresh.txt; git -C "$seed" commit -qm fresh
  git -C "$seed" push -q origin develop
  FRESH="$(git -C "$seed" rev-parse HEAD)"
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

run() { "$SCRIPT" "$@" >"$TMP/out" 2>"$TMP/err"; }
WT() { printf '%s' "$PROJECT_ROOT/.worktrees/sa-$1"; }

t_unknown_repo() {
  run no-such-repo t1; local rc=$?
  check "unknown repo — error"        [ "$rc" -ne 0 ]
  check "worktree not created"               [ ! -e "$PROJECT_ROOT/.worktrees" ]
}

t_new_branch() {
  run svc-a t1 --branch feat/new; local rc=$?
  check "exit 0"                            [ "$rc" -eq 0 ]
  check "path .worktrees/sa-t1"            [ -d "$(WT t1)" ]
  check "branch feat/new"                    [ "$(git -C "$(WT t1)" branch --show-current)" = feat/new ]
  check "from fresh origin/develop"         [ "$(git -C "$(WT t1)" rev-parse HEAD)" = "$FRESH" ]
  check "last stdout line is the path"    [ "$(tail -1 "$TMP/out")" = "$(WT t1)" ]
}

t_remote_branch() {
  run svc-a pr --branch feat/pr-branch
  check "on the PR branch"                       [ -f "$(WT pr)/pr.txt" ]
  check "upstream origin/feat/pr-branch"    [ "$(git -C "$(WT pr)" rev-parse --abbrev-ref '@{u}')" = origin/feat/pr-branch ]
}

t_detached() {
  run svc-a base
  check "detached HEAD"                     [ -z "$(git -C "$(WT base)" branch --show-current)" ]
  check "on fresh origin/develop"          [ "$(git -C "$(WT base)" rev-parse HEAD)" = "$FRESH" ]
}

t_base_flag() {
  run svc-a b2 --base feat/pr-branch
  check "--base takes another branch"         [ -f "$(WT b2)/pr.txt" ]
}

t_unknown_short() {
  git clone -q "$ORIGIN" "$PROJECT_ROOT/some-new-service"
  run some-new-service t1
  check "unknown repo — full name"      [ -d "$PROJECT_ROOT/.worktrees/some-new-service-t1" ]
}

t_rerun() {
  run svc-a t1 --branch feat/new
  run svc-a t1 --branch feat/new; local rc=$?
  check "repeat — exit 0"                   [ "$rc" -eq 0 ]
  check "repeat — same path"              [ "$(tail -1 "$TMP/out")" = "$(WT t1)" ]
  check "no second worktree"              [ "$(git -C "$REPO" worktree list | wc -l)" -eq 2 ]
}

t_env() {
  run svc-a noenv
  check "without --env .env is not copied"      [ ! -e "$(WT noenv)/.env" ]
  run svc-a withenv --env
  check "with --env .env is copied"           grep -qx SECRET=1 "$(WT withenv)/.env"
}

t_deps() {
  run svc-a t1
  check "wt-install called"                 grep -q '^install' "$LOG"
  check "node_modules in place"             [ -d "$(WT t1)/node_modules" ]
  : > "$LOG"
  git -C "$REPO" pull -q; git -C "$REPO" rm -q package.json; git -C "$REPO" commit -qm nopkg; git -C "$REPO" push -q origin HEAD:develop
  run svc-a t2
  check "without package.json pnpm is not called"   not grep -q . "$LOG"
}

t_quiet() {
  run svc-a q1
  check "success — output is only the path"         [ "$(cat "$TMP/out" "$TMP/err")" = "$(WT q1)" ]
  check "install log saved"            grep -q pnpm-noise "$(git -C "$(WT q1)" rev-parse --absolute-git-dir)/wt-install.log"
}

t_install_fail() {
  printf '#!/usr/bin/env bash\necho boom-line\nexit 1\n' > "$TMP/bin/pnpm"
  run svc-a f1; local rc=$?
  check "install error — non-zero exit"  [ "$rc" -ne 0 ]
  check "log tail in stderr"               grep -q boom-line "$TMP/err"
}

t_branch_busy() {
  run svc-a author --branch feat/shared
  run svc-a review-974 --branch feat/shared; local rc=$?
  check "busy branch — exit 0"            [ "$rc" -eq 0 ]
  check "busy branch — author path"       [ "$(tail -1 "$TMP/out")" = "$(WT author)" ]
  check "stderr says already checked out" \
    grep -q "already checked out at $(WT author)" "$TMP/err"
  check "no second worktree"              [ ! -e "$(WT review-974)" ]
}

t_at_sha() {
  local sha; sha="$(git -C "$REPO" rev-parse origin/feat/pr-branch)"
  run svc-a at1 --at "$sha"; local rc=$?
  check "--at — exit 0"                     [ "$rc" -eq 0 ]
  check "--at — HEAD = sha"                 [ "$(git -C "$(WT at1)" rev-parse HEAD)" = "$sha" ]
  check "--at — detached"                   not git -C "$(WT at1)" symbolic-ref -q HEAD
  run svc-a at2 --at "$sha" --branch feat/x; local rc2=$?
  check "--at with --branch — usage"           [ "$rc2" -eq 2 ]
}

t_existing_wrong_branch() {
  run svc-a t1 --branch feat/new
  run svc-a t1 --branch feat/other; local rc=$?
  check "existing wt — exit 0"          [ "$rc" -eq 0 ]
  check "existing wt — path"            [ "$(tail -1 "$TMP/out")" = "$(WT t1)" ]
  check "stderr — branch mismatch" \
    grep -q "$(WT t1) is on feat/new, not feat/other" "$TMP/err"
}

t_at_existing_checkout() {
  local sha1 sha2
  sha1="$(git -C "$REPO" rev-parse origin/develop)"
  run svc-a at1 --at "$sha1"
  sha2="$(git -C "$REPO" rev-parse origin/feat/pr-branch)"
  run svc-a at1 --at "$sha2"; local rc=$?
  check "--at repeat — exit 0"              [ "$rc" -eq 0 ]
  check "--at repeat — HEAD = new sha"    [ "$(git -C "$(WT at1)" rev-parse HEAD)" = "$sha2" ]
  # dirty tree → error
  echo dirty >"$(WT at1)/dirty.txt"
  run svc-a at1 --at "$sha1"; local rc2=$?
  check "--at on a dirty one — exit 1"          [ "$rc2" -eq 1 ]
  check "--at on a dirty one — stderr"          grep -qi dirty "$TMP/err"
}

t_branch_busy_primary() {
  # develop is checked out in primary REPO
  git -C "$REPO" checkout -q develop
  run svc-a review-dev --branch develop; local rc=$?
  check "branch in primary — exit 1"          [ "$rc" -eq 1 ]
  check "branch in primary — hint --at"  grep -q -- '--at' "$TMP/err"
  check "worktree not created"                [ ! -e "$(WT review-dev)" ]
}

t_at_pull_ref() {
  # Put refs/pull/1/head on the bare remote (PR head)
  local sha; sha="$(git -C "$REPO" rev-parse origin/feat/pr-branch)"
  git -C "$ORIGIN" update-ref refs/pull/1/head "$sha"
  run svc-a pr1 --at refs/pull/1/head; local rc=$?
  check "--at pull ref — exit 0"            [ "$rc" -eq 0 ]
  check "--at pull ref — HEAD"              [ "$(git -C "$(WT pr1)" rev-parse HEAD)" = "$sha" ]
  check "--at pull ref — detached"          not git -C "$(WT pr1)" symbolic-ref -q HEAD
}

t_base_from_env() {
  PROJECT_BASE_BRANCH=feat/pr-branch run svc-a benv
  check "PROJECT_BASE_BRANCH sets the base"   [ -f "$(WT benv)/pr.txt" ]
}

t_no_short_names_file() {
  WT_SHORT_NAMES_FILE="$TMP/missing.conf" run svc-a nf; local rc=$?
  check "without a short names file — exit 0"    [ "$rc" -eq 0 ]
  check "without a short names file — full name" [ -d "$PROJECT_ROOT/.worktrees/svc-a-nf" ]
}

run_test "unknown repo"         t_unknown_repo
run_test "new branch"              t_new_branch
run_test "PR branch from origin"        t_remote_branch
run_test "without --branch"             t_detached
run_test "--base"                   t_base_flag
run_test "default short name"  t_unknown_short
run_test "second run"         t_rerun
run_test "--env"                    t_env
run_test "dependencies"              t_deps
run_test "quiet output"              t_quiet
run_test "install error"         t_install_fail
run_test "branch busy"             t_branch_busy
run_test "--at sha"                 t_at_sha
run_test "wt on another branch"       t_existing_wrong_branch
run_test "--at on an existing wt"  t_at_existing_checkout
run_test "branch in primary"          t_branch_busy_primary
run_test "--at refs/pull"           t_at_pull_ref
run_test "base from PROJECT_BASE_BRANCH" t_base_from_env
run_test "no short names file"     t_no_short_names_file

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
