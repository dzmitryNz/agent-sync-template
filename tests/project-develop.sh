#!/usr/bin/env bash
# project-develop: fast-forward primary checkouts onto origin/$PROJECT_BASE_BRANCH.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/bin/project-develop.sh"
PASS=0; FAIL=0

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test
export PROJECT_NAME=acme PROJECT_BASE_BRANCH=develop PROJECT_GIT_ORG=acme

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "failed: $*"; fi; }

setup() { TMP="$(mktemp -d)"; export PROJECT_ROOT="$TMP/proj"; mkdir -p "$PROJECT_ROOT"; }
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

seed() { # seed <repo> — primary checkout one commit behind origin/develop, sitting on a feature branch
  local repo="$1" bare dir
  bare="$TMP/bare/$repo.git"
  dir="$PROJECT_ROOT/$repo"
  mkdir -p "$bare" "$dir"
  git init -q --bare -b develop "$bare"
  git init -q -b develop "$dir"
  git -C "$dir" remote add origin "$bare"
  git -C "$dir" commit -q --allow-empty -m base
  git -C "$dir" push -q origin develop
  git -C "$dir" checkout -q -b feature
  git -C "$dir" commit -q --allow-empty -m ahead-on-develop
  git -C "$dir" push -q origin HEAD:develop
}

t_ff_and_skip_dirty() {
  seed api
  seed web
  echo dirty > "$PROJECT_ROOT/web/dirty"
  git -C "$PROJECT_ROOT/web" add dirty

  out="$("$SCRIPT" --dry-run)"; rc=$?
  check "dry-run exit 1 (dirty skipped)" [ "$rc" -eq 1 ]
  check "api planned" grep -q 'api .*PLAN' <<<"$out"
  check "web skipped" grep -q 'web .*SKIP' <<<"$out"
  check "dry-run did not move api" [ "$(git -C "$PROJECT_ROOT/api" rev-parse --abbrev-ref HEAD)" = feature ]

  out="$("$SCRIPT" api)"; rc=$?
  check "api exit 0" [ "$rc" -eq 0 ]
  check "api on develop" [ "$(git -C "$PROJECT_ROOT/api" rev-parse --abbrev-ref HEAD)" = develop ]
  check "api matches origin" [ "$(git -C "$PROJECT_ROOT/api" rev-parse HEAD)" = "$(git -C "$PROJECT_ROOT/api" rev-parse origin/develop)" ]
  check "ok line" grep -q 'api .*OK' <<<"$out"
}

t_no_such_repo() {
  out="$("$SCRIPT" missing)"; rc=$?
  check "exit 1" [ "$rc" -eq 1 ]
  check "not a checkout" grep -q 'missing .*SKIP' <<<"$out"
}

run_test "fast-forward a clean repo, skip a dirty one" t_ff_and_skip_dirty
run_test "unknown name is a skip" t_no_such_repo

printf '\ntotal: %d ok, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
