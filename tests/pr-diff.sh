#!/usr/bin/env bash
# Tests for pr-diff.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/pr-diff.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "failed: $*"; fi; }
not() { ! "$@"; }

FIXTURE='diff --git a/src/a.ts b/src/a.ts
index 111..222 100644
--- a/src/a.ts
+++ b/src/a.ts
@@ -1 +1 @@
-old
+new
diff --git a/old.ts b/renamed.ts
similarity index 90%
rename from old.ts
rename to renamed.ts
index 333..444 100644
--- a/old.ts
+++ b/renamed.ts
@@ -1 +1 @@
-x
+y
diff --git a/gone.ts b/gone.ts
deleted file mode 100644
index 555..000
--- a/gone.ts
+++ /dev/null
@@ -1 +0,0 @@
-bye
'

setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/bin"
  printf '%s' "$FIXTURE" > "$TMP/fixture.diff"
  cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${GH_LOG:?}"
if [ "\$1" = pr ] && [ "\$2" = view ]; then
  cat <<'JSON'
{"files":[
  {"path":"src/a.ts","additions":10,"deletions":2},
  {"path":"package-lock.json","additions":500,"deletions":10},
  {"path":"db/new_schema_clean.sql","additions":100,"deletions":0},
  {"path":"src/b.ts","additions":3,"deletions":1}
]}
JSON
  exit 0
fi
if [ "\$1" = pr ] && [ "\$2" = diff ]; then
  # gh 2.102: pr diff <n> [--repo R] — path filters are rejected
  shift 2
  if [[ "\${1:-}" =~ ^[0-9]+$ ]]; then shift; fi
  while [ \$# -gt 0 ]; do
    case "\$1" in
      --repo) shift 2 ;;
      *)
        echo "accepts at most 1 arg(s)" >&2
        exit 2
        ;;
    esac
  done
  cat "$TMP/fixture.diff"
  exit 0
fi
exit 1
EOF
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh.log"
  : > "$GH_LOG"
}

teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

t_file_list() {
  local out
  out="$("$SCRIPT" acme/svc-a 970)"
  check "lock marked generated" grep -q 'package-lock.json (generated, skipped)' <<<"$out"
  check "schema marked generated" grep -q 'new_schema_clean.sql (generated, skipped)' <<<"$out"
  check "code without a mark" grep -qE '^\+10 -2 src/a\.ts$' <<<"$out"
  local first; first="$(head -1 <<<"$out")"
  check "first is the biggest (lock)" grep -q 'package-lock.json' <<<"$first"
  check "view called" grep -q 'pr view 970' "$GH_LOG"
  check "diff not called without files" not grep -q 'pr diff' "$GH_LOG"
}

t_specific_files() {
  local out
  out="$("$SCRIPT" acme/svc-a 1 src/a.ts renamed.ts gone.ts)"
  check "diff without path args" not grep -qE 'src/a\.ts' "$GH_LOG"
  check "diff called" grep -q 'pr diff 1 --repo acme/svc-a' "$GH_LOG"
  check "section a.ts" grep -q 'diff --git a/src/a.ts b/src/a.ts' <<<"$out"
  check "section rename" grep -q 'diff --git a/old.ts b/renamed.ts' <<<"$out"
  check "section delete" grep -q 'diff --git a/gone.ts b/gone.ts' <<<"$out"
  check "no extra files" not grep -q 'package-lock' <<<"$out"
}

t_missing_file_exits() {
  local out ec=0 err
  out="$("$SCRIPT" acme/svc-a 1 src/a.ts missing.ts 2>"$TMP/err")" || ec=$?
  err="$(cat "$TMP/err")"
  check "exit 1 on a missing file" test "$ec" -eq 1
  check "stderr lists missing.ts" grep -q 'missing.ts' <<<"$err"
  check "stdout still returned the found file" grep -q 'diff --git a/src/a.ts b/src/a.ts' <<<"$out"
}

# Mock must reject path args the way real gh does
t_gh_rejects_paths() {
  if gh pr diff 1 --repo x -- src/a.ts 2>/dev/null; then
    fail "gh mock must reject path args" "exit 0"
  else
    check "gh mock rejects path args" true
  fi
}

t_owner_default() {
  PROJECT_GIT_ORG=acme "$SCRIPT" svc-a 12 >/dev/null
  check "owner filled from PROJECT_GIT_ORG" grep -q 'acme/svc-a' "$GH_LOG"
}

run_test "file list" t_file_list
run_test "repo name gets PROJECT_GIT_ORG" t_owner_default
run_test "diff of chosen files from the full one" t_specific_files
run_test "file without a section → exit 1" t_missing_file_exits
run_test "mock like gh 2.102" t_gh_rejects_paths

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
