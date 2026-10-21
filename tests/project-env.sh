#!/usr/bin/env bash
# Tests for bin/lib/project-env.sh: defaults, agent-sync.env, env overrides, PROJECT_KEY.
set -uo pipefail

LIB="$(cd "$(dirname "$0")/.." && pwd)/bin/lib/project-env.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
eq()   { # eq <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/.agent-sync"

# run <vars to print> with a clean project environment; extra env via leading VAR=value args
run() { # run <var> [VAR=value ...]
  local var="$1"; shift
  env -i HOME="$TMP/home" PATH="$PATH" "$@" bash -c ". '$LIB'; printf '%s' \"\${$var-<unset>}\""
}

echo "no agent-sync.env: defaults, no error"
rm -f "$TMP/home/.agent-sync/agent-sync.env"
eq "exit 0 without file" 0 "$(env -i HOME="$TMP/home" PATH="$PATH" bash -c ". '$LIB'; echo \$?" | tail -1)"
eq "default PROJECT_NAME"        project                "$(run PROJECT_NAME)"
eq "default PROJECT_ROOT"        "$TMP/home/project"    "$(run PROJECT_ROOT)"
eq "default PROJECT_GIT_ORG"     project                "$(run PROJECT_GIT_ORG)"
eq "default PROJECT_CREDS_DIR"   "$TMP/home/project-creds" "$(run PROJECT_CREDS_DIR)"
eq "default PROJECT_BASE_BRANCH" main                   "$(cd "$TMP" && run PROJECT_BASE_BRANCH)"
git init -q -b trunk "$TMP/repo"
git -C "$TMP/repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
eq "branch from origin/HEAD" trunk "$(cd "$TMP/repo" && run PROJECT_BASE_BRANCH)"
eq "default SYNC_SERVER empty"   ""                     "$(run SYNC_SERVER)"
eq "default HISTORY_REMOTE empty" ""                    "$(run HISTORY_REMOTE)"
eq "default STAND_DB_HOST empty" ""                     "$(run STAND_DB_HOST)"

echo "agent-sync.env is read"
cat > "$TMP/home/.agent-sync/agent-sync.env" <<'EOF'
PROJECT_NAME=acme
PROJECT_ROOT=/srv/acme
PROJECT_GIT_ORG=acme-gh
PROJECT_BASE_BRANCH=main
SYNC_SERVER=nas
STAND_DB_HOST=203.0.113.5
EOF
eq "name from file"            acme                    "$(run PROJECT_NAME)"
eq "root from file"            /srv/acme               "$(run PROJECT_ROOT)"
eq "org from file"             acme-gh                 "$(run PROJECT_GIT_ORG)"
eq "branch from file"          main                    "$(run PROJECT_BASE_BRANCH)"
eq "creds derived from root"   /srv/acme-creds         "$(run PROJECT_CREDS_DIR)"
eq "history remote from server" nas:agent-history/claude "$(run HISTORY_REMOTE)"
eq "stand db host from file"   203.0.113.5                "$(run STAND_DB_HOST)"
eq "stand db host exported to children" 203.0.113.5 "$(env -i HOME="$TMP/home" PATH="$PATH" bash -c ". '$LIB'; bash -c 'printf %s \$STAND_DB_HOST'")"

echo "environment beats the file"
eq "env root wins"     /tmp/other      "$(run PROJECT_ROOT PROJECT_ROOT=/tmp/other)"
eq "creds follow env root" /tmp/other-creds "$(run PROJECT_CREDS_DIR PROJECT_ROOT=/tmp/other)"
eq "empty env server wins" ""          "$(run SYNC_SERVER SYNC_SERVER=)"
eq "empty server -> no history remote" "" "$(run HISTORY_REMOTE SYNC_SERVER=)"
eq "explicit HISTORY_REMOTE wins" me:x "$(run HISTORY_REMOTE HISTORY_REMOTE=me:x)"
eq "env stand db host wins" 203.0.113.9   "$(run STAND_DB_HOST STAND_DB_HOST=203.0.113.9)"
eq "empty env stand db host wins" ""   "$(run STAND_DB_HOST STAND_DB_HOST=)"

echo "SYNC_HOME relocates the file"
mkdir -p "$TMP/alt"; printf 'PROJECT_NAME=alt\n' > "$TMP/alt/agent-sync.env"
eq "name from SYNC_HOME" alt "$(run PROJECT_NAME SYNC_HOME="$TMP/alt")"

echo "PROJECT_KEY"
eq "plain path"           -srv-acme                     "$(run PROJECT_KEY)"
eq "dots become dashes"   -home-a-b-c                   "$(run PROJECT_KEY PROJECT_ROOT=/home/a.b/c)"
eq "deep path"            -home-me-org-proj            "$(run PROJECT_KEY PROJECT_ROOT=/home/me/org/proj)"
eq "trailing slash trimmed" -srv-acme                   "$(run PROJECT_KEY PROJECT_ROOT=/srv/acme/)"

echo "works under set -u and exports"
eq "set -u ok" ok "$(env -i HOME="$TMP/home" PATH="$PATH" bash -c "set -u; . '$LIB'; echo ok")"
eq "exported to children" /srv/acme "$(env -i HOME="$TMP/home" PATH="$PATH" bash -c ". '$LIB'; bash -c 'printf %s \$PROJECT_ROOT'")"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
