#!/usr/bin/env bash
# Tests for prevent-secret-commit.sh. Run: ~/.claude/hooks/prevent-secret-commit.test.sh
set -uo pipefail

HOOK="$(dirname "$(readlink -f "$0")")/prevent-secret-commit.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

# Fake secrets assembled at runtime so this file itself never matches.
AWS="AKIA""ABCDEFGHIJKLMNOP"
GHP="ghp_""$(printf 'a%.0s' {1..36})"
JWT="eyJ""hbGciOiJIUzI1NiJ9.eyJ""zdWIiOiIxIn0.sig"
PEM="-----BEGIN RSA PRIVATE ""KEY-----"

new_repo() {
  local d="$TMP/$1"
  git init -q "$d"
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  echo base >"$d/README"; git -C "$d" add README; git -C "$d" commit -qm init
  echo "$d"
}

run_hook() { # $1=cwd $2=command
  jq -n --arg c "$2" --arg d "$1" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | "$HOOK"
}

expect() { # $1=deny|allow $2=name $3=cwd $4=command
  local out; out="$(run_hook "$3" "$4")"
  local got=allow
  [[ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)" == deny ]] && got=deny
  if [[ "$got" == "$1" ]]; then echo "ok   $2"; else echo "FAIL $2 (expected $1, got $got) $out"; fail=1; fi
}

r="$(new_repo clean)"; echo 'const x = 1' >"$r/a.ts"; git -C "$r" add a.ts
expect allow "clean diff" "$r" "git commit -m x"
expect allow "non-commit command" "$r" "git status"

r="$(new_repo aws)"; echo "key = '$AWS'" >"$r/a.ts"; git -C "$r" add a.ts
expect deny "AWS key" "$r" "git commit -m x"
expect allow "git log mentioning commit is not a commit" "$r" "git log --grep commit"

r="$(new_repo ghp)"; echo "token: $GHP" >"$r/cfg.yml"; git -C "$r" add cfg.yml
expect deny "GitHub PAT" "$r" "git commit -m x"

r="$(new_repo pem)"; echo "$PEM" >"$r/k.txt"; git -C "$r" add k.txt
expect deny "private key" "$r" "git commit -m x"

r="$(new_repo jwt)"; echo "auth = '$JWT'" >"$r/a.ts"; git -C "$r" add a.ts
expect deny "JWT in source" "$r" "git commit -m x"

r="$(new_repo jwt_test)"; mkdir -p "$r/tests"; echo "auth = '$JWT'" >"$r/tests/a.spec.ts"; git -C "$r" add tests
expect allow "JWT in test fixture" "$r" "git commit -m x"

r="$(new_repo pw)"; echo "password = 'Sup3rS3cretValue'" >"$r/a.js"; git -C "$r" add a.js
expect deny "hardcoded password in source" "$r" "git commit -m x"

r="$(new_repo pw_test)"; echo "password = 'Sup3rS3cretValue'" >"$r/a.test.js"; git -C "$r" add a.test.js
expect allow "hardcoded password in test" "$r" "git commit -m x"

r="$(new_repo envf)"; echo "DB_PASS=x" >"$r/.env.develop"; git -C "$r" add -f .env.develop
expect deny "staged .env.develop" "$r" "git commit -m x"

r="$(new_repo envex)"; echo "DB_PASS=" >"$r/.env.example"; git -C "$r" add .env.example
expect allow "staged .env.example" "$r" "git commit -m x"

r="$(new_repo nm)"; mkdir -p "$TMP/real_nm"; ln -s "$TMP/real_nm" "$r/node_modules"; git -C "$r" add node_modules
expect deny "node_modules symlink" "$r" "git commit -m x"

r="$(new_repo nm_nested)"; mkdir -p "$r/pkg"; ln -s "$TMP/real_nm" "$r/pkg/node_modules"; git -C "$r" add pkg/node_modules
expect deny "nested node_modules symlink" "$r" "git commit -m x"

r="$(new_repo removal)"; echo "k='$AWS'" >"$r/a.ts"; git -C "$r" add a.ts; git -C "$r" commit -qm s
echo "k=process.env.K" >"$r/a.ts"; git -C "$r" add a.ts
expect allow "removing a secret" "$r" "git commit -m x"

r="$(new_repo dashc)"; echo "key = '$AWS'" >"$r/a.ts"; git -C "$r" add a.ts
expect deny "git -C <repo> from other cwd" "$TMP" "git -C $r commit -m x"
expect deny "cd <repo> && git commit" "$TMP" "cd $r && git add -A && git commit -m x"
expect deny "SKIP_SIMPLE_GIT_HOOKS=1 prefix" "$r" "SKIP_SIMPLE_GIT_HOOKS=1 git commit -m x"

r="$(new_repo am)"; echo 'x' >"$r/a.ts"; git -C "$r" add a.ts; git -C "$r" commit -qm a
echo "key = '$AWS'" >"$r/a.ts"
expect deny "git commit -am with unstaged tracked secret" "$r" "git commit -am x"
expect allow "unstaged secret without -a" "$r" "git commit -m x"

r="$(new_repo addchain)"; echo "key = '$AWS'" >"$r/new.ts"
expect deny "git add && git commit with untracked secret" "$r" "git add new.ts && git commit -m x"
mkdir -p "$TMP/real_nm2"; r="$(new_repo addnm)"; ln -s "$TMP/real_nm2" "$r/node_modules"
expect deny "git add -A && git commit picks up node_modules symlink" "$r" "git add -A && git commit -m x"

expect allow "outside a repo" "$TMP" "git commit -m x"

r="$(new_repo cached)"; echo "key = '$AWS'" >"$r/a.ts"; git -C "$r" add a.ts
if "$HOOK" --cached "$r" >/dev/null 2>&1; then
  echo "FAIL --cached allows a staged key"; fail=1
else
  echo "ok   --cached refuses a staged key"
fi

exit $fail
