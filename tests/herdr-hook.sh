#!/usr/bin/env bash
# Tests for what the herdr-pane-meta.sh hook puts into the Herdr sidebar.
# herdr itself is replaced by a shim that just records its arguments.
set -uo pipefail

HOOK="${HOOK_PATH:-$(cd "$(dirname "$0")/.." && pwd)/store/.claude/hooks/herdr-pane-meta.sh}"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "failed: $*"; fi; }

setup() {
  TMP="$(mktemp -d)"
  export XDG_RUNTIME_DIR="$TMP/run"
  export HERDR_ENV=1 HERDR_PANE_ID="w9:p1" HERDR_TAB_ID="w9:t1" HERDR_WORKSPACE_ID=w9
  mkdir -p "$TMP/bin" "$XDG_RUNTIME_DIR"

  # herdr shim: writes calls to a log
  # arguments are written with tabs: values contain hyphens and spaces,
  # and they cannot be parsed back from "$*"
  cat > "$TMP/bin/herdr" <<EOF
#!/usr/bin/env bash
if [ "\$1" = workspace ] && [ "\$2" = get ]; then
  label="\$(cat "$TMP/ws-label" 2>/dev/null)"
  printf '{"result":{"workspace":{"label":"%s"}}}' "\$label"
  exit 0
fi
if [ "\$1" = agent ] && [ "\$2" = list ]; then
  cat "$TMP/agent-list.json" 2>/dev/null || printf '{"result":{"agents":[]}}'
  exit 0
fi
printf '%s' "\$1" >> "$TMP/herdr.log"
shift
for a in "\$@"; do printf '\t%s' "\$a" >> "$TMP/herdr.log"; done
printf '\n' >> "$TMP/herdr.log"
exit 0
EOF
  chmod +x "$TMP/bin/herdr"

  # claude shim: answers like `claude -p /usage --output-format json`
  local pace_tz="${LIMIT_PACE_TZ:-}"
  if [ -z "$pace_tz" ]; then
    pace_tz=$(readlink -f /etc/localtime 2>/dev/null || true)
    pace_tz=${pace_tz#*/zoneinfo/}  # macOS: /var/db/timezone/zoneinfo/...
  fi
  cat > "$TMP/bin/claude" <<CLAUDE_EOF
#!/usr/bin/env bash
cat <<'JSON'
{"result":"You are currently using your subscription to power your Claude Code usage\n\nCurrent session: 24% used · resets Sep 6, 12:29am ($pace_tz)\nCurrent week (all models): 10% used · resets Sep 11, 1:59pm ($pace_tz)\n"}
JSON
CLAUDE_EOF
  chmod +x "$TMP/bin/claude"
  export PATH="$TMP/bin:$PATH"

  # a project with a branch
  PROJ="$TMP/web-login-redirect"
  mkdir -p "$PROJ"
  git -c init.defaultBranch=feat/chart init -q "$PROJ"
  git -C "$PROJ" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

  # the usage percent is put in through the hook state file
  local state_dir="$XDG_RUNTIME_DIR/claude-herdr-meta"
  mkdir -p "$state_dir"
  printf 'USAGE=%q\nLAST_SEQ=1\nLAST_USAGE_TS=%s\nTITLE=\nWORKING=\nBLOCKED=\n' \
    '37%' "$(date +%s)" > "$state_dir/w9_p1"
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

fire() { # fire <event> <dir> [prompt]
  jq -nc --arg e "$1" --arg c "$2" --arg p "${3:-}" \
    '{hook_event_name:$e, cwd:$c, prompt:$p}' | "$HOOK" >/dev/null 2>&1
}

# the option value = the field right after the option itself
opt_value() { awk -F'\t' -v k="$1" '{for(i=1;i<NF;i++) if($i==k){print $(i+1); exit}}' "$TMP/herdr.log"; }
display_agent() { opt_value --display-agent; }
tab_label()     { awk -F'\t' '$1=="tab" && $2=="rename" {print $4; exit}' "$TMP/herdr.log"; }

# --- 1. bottom (display_agent) — agent and percent, no project and branch ---
t_display_agent() {
  fire UserPromptSubmit "$PROJ" "fixing the sidebar"
  local d; d="$(display_agent)"
  check "agent name present"    grep -q 'claude'  <<<"$d"
  check "percent present"       grep -q '37%'     <<<"$d"
  check "no project name"  test -z "$(grep -o 'web-login-redirect' <<<"$d")"
  check "no branch"          test -z "$(grep -o 'feat/chart' <<<"$d")"
}

# --- 2. top (tab label) — only the branch ------------------------------------
# Spaces now shows the worktree name, no need to duplicate it here.
t_tab_label() {
  fire UserPromptSubmit "$PROJ" "fixing the sidebar"
  local t; t="$(tab_label)"
  check "branch in place"     test "$t" = 'feat/chart'
  check "no worktree name" test -z "$(grep -o 'web-login-redirect' <<<"$t")"
  check "no percent"       test -z "$(grep -o '37%' <<<"$t")"
}

# --- 3. the two sidebar lines do not repeat each other -----------------------
t_no_duplication() {
  fire UserPromptSubmit "$PROJ" "fixing the sidebar"
  check "top and bottom differ" test "$(display_agent)" != "$(tab_label)"
}

# --- 4. a directory without git: show just the name, no empty brackets -------
t_no_git() {
  local plain="$TMP/naïve-dir"; mkdir -p "$plain"
  fire UserPromptSubmit "$plain" "without git"
  local t; t="$(tab_label)"
  check "dir name in place" grep -q 'naïve-dir' <<<"$t"
  check "no empty brackets"     test -z "$(grep -o '()' <<<"$t")"
}

ws_rename() { awk -F'\t' '$1=="workspace" && $2=="rename" {print $4; exit}' "$TMP/herdr.log"; }

# The workspace name is taken from the shim: it answers workspace get
stub_workspace_label() { printf '%s' "$1" > "$TMP/ws-label"; }

# --- 5. the default Space name is replaced by the worktree name ---------------
# Three workspaces with the project name are indistinguishable; the worktree name separates them.
t_space_default_renamed() {
  local wt="$TMP/proj/.worktrees/web-login-redirect"
  mkdir -p "$wt"
  git -c init.defaultBranch=feat/chart init -q "$wt"
  git -C "$wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  stub_workspace_label proj

  fire UserPromptSubmit "$wt" "working in worktree"

  check "workspace renamed to the worktree name" \
    test "$(ws_rename)" = web-login-redirect
}

# --- 6. a Space name set by hand is left alone --------------------------------
t_space_manual_kept() {
  local wt="$TMP/proj/.worktrees/web-login-redirect"
  mkdir -p "$wt"
  stub_workspace_label Review

  fire UserPromptSubmit "$wt" "working in worktree"

  check "manual name not renamed" test -z "$(ws_rename)"
}

# --- 7. the name is already right — no extra calls ---------------------------
t_space_noop() {
  local wt="$TMP/proj/.worktrees/web-login-redirect"
  mkdir -p "$wt"
  stub_workspace_label web-login-redirect

  fire UserPromptSubmit "$wt" "working in worktree"

  check "no repeated rename" test -z "$(ws_rename)"
}

# --- 8. the weekly limit is visible next to the session one ------------------
# The weekly limit hurts more: the five-hour one is released by evening, the weekly one may
# run out on Wednesday. Both percents come in one /usage answer.
t_weekly_usage() {
  rm -f "$XDG_RUNTIME_DIR/claude-herdr-meta/usage-shared" "$XDG_RUNTIME_DIR/claude-herdr-meta/w9_p1"
  fire Stop "$PROJ"
  local d; d="$(display_agent)"
  check "session percent"  grep -q '24%'  <<<"$d"
  check "weekly percent"   grep -q '10%'  <<<"$d"
  check "weekly is labeled W" grep -q 'W'   <<<"$d"
}

# the charge is set through a fake sysfs
power() { # power <online> [capacity]
  export POWER_SUPPLY_DIR="$TMP/power" AGENT_SYNC_OS=linux  # fake /sys: also on a macOS runner
  mkdir -p "$POWER_SUPPLY_DIR/AC" "$POWER_SUPPLY_DIR/BAT0"
  printf 'Mains\n' > "$POWER_SUPPLY_DIR/AC/type"
  printf '%s\n' "$1" > "$POWER_SUPPLY_DIR/AC/online"
  printf 'Battery\n' > "$POWER_SUPPLY_DIR/BAT0/type"
  printf '%s\n' "${2:-100}" > "$POWER_SUPPLY_DIR/BAT0/capacity"
}

fresh_usage() { rm -f "$XDG_RUNTIME_DIR/claude-herdr-meta/usage-shared" \
                     "$XDG_RUNTIME_DIR/claude-herdr-meta/w9_p1"; }

# --- 9. the charge is visible on battery ---------------------------------------
# This is a laptop: work can stop not only at the limit but also at a flat battery.
t_battery_on_battery() {
  fresh_usage; power 0 37
  fire Stop "$PROJ"
  local d; d="$(display_agent)"
  check "charge shown"      grep -q '37' <<<"$d"
  check "labeled B"       grep -q 'B ' <<<"$d"
}

# --- 10. on mains the charge is still shown (AC) -----------------------------
t_battery_on_ac() {
  fresh_usage; power 1 37
  fire Stop "$PROJ"
  local d; d="$(display_agent)"
  check "charge shown"   grep -q '37' <<<"$d"
  check "labeled AC" grep -q 'AC ' <<<"$d"
}

# --- 11. without a battery (desktop) nothing breaks --------------------------
t_battery_absent() {
  fresh_usage
  export POWER_SUPPLY_DIR="$TMP/no-such-dir" AGENT_SYNC_OS=linux  # fake /sys: also on a macOS runner
  fire Stop "$PROJ"
  local d; d="$(display_agent)"
  check "line is built"  grep -q 'claude' <<<"$d"
  check "no battery junk" test -z "$(grep -i 'batt' <<<"$d")"
}

run_test "charge visible on battery"            t_battery_on_battery
run_test "charge visible on mains (AC)"         t_battery_on_ac
run_test "nothing breaks without a battery"    t_battery_absent
limits_cache() { # limits_cache <session> <week>
  mkdir -p "$XDG_RUNTIME_DIR/claude-herdr-meta"
  printf 'SHARED_SESSION_PCT=%s\nSHARED_WEEK_PCT=%s\n' "$1" "$2" \
    > "$XDG_RUNTIME_DIR/claude-herdr-meta/usage-limits"
}

power() { # power <online> <charge>
  export POWER_SUPPLY_DIR="$TMP/power" AGENT_SYNC_OS=linux  # fake /sys: also on a macOS runner
  mkdir -p "$POWER_SUPPLY_DIR/AC" "$POWER_SUPPLY_DIR/BAT0"
  printf 'Mains\n'   > "$POWER_SUPPLY_DIR/AC/type"
  printf '%s\n' "$1" > "$POWER_SUPPLY_DIR/AC/online"
  printf 'Battery\n' > "$POWER_SUPPLY_DIR/BAT0/type"
  printf '%s\n' "$2" > "$POWER_SUPPLY_DIR/BAT0/capacity"
}

# --- 9. a limit running out is visible from afar ------------------------------
# The panel may be collapsed, and a small percent is easy to miss. herdr does not draw
# ANSI color (it shows the codes as letters), but it renders emoji in color.
t_marker_when_high() {
  limits_cache 92 14
  fire UserPromptSubmit "$PROJ" "working"
  local d; d="$(display_agent)"
  check "mark present"          grep -q '!' <<<"$d"
  check "no ANSI codes"      test "$(printf '%s' "$d" | grep -c $'\033')" -eq 0
}

# --- 10. with headroom the line is clean --------------------------------------
t_no_marker_when_low() {
  limits_cache 24 10
  fire UserPromptSubmit "$PROJ" "working"
  check "no mark" test -z "$(grep -o '!' <<<"$(display_agent)")"
}

# --- 11. a low charge is marked too -----------------------------------------
t_marker_battery() {
  limits_cache 24 10; power 0 12
  fire Stop "$PROJ"
  local d; d="$(display_agent)"
  check "charge shown"      grep -q '12' <<<"$d"
  check "and marked"          grep -q '!' <<<"$d"
}

# --- 12. right at the edge the mark is more insistent ------------------------
t_marker_severity() {
  limits_cache 82 10
  fire UserPromptSubmit "$PROJ" "working"
  check "at 82% one exclamation" grep -q '^!\( \|c\)' <<<"$(display_agent)"

  fresh_usage; rm -f "$TMP/herdr.log"; limits_cache 95 10
  fire UserPromptSubmit "$PROJ" "working"
  check "at 95% three"              grep -q '!!!' <<<"$(display_agent)"
}

# --- 13. near the limit the numbers refresh more often ------------------------
# With several parallel sessions usage grows by tens of percent in
# minutes: a five-minute cache showed 73% when it was already 92%.
t_cache_ttl_adaptive() {
  local cache="$XDG_RUNTIME_DIR/claude-herdr-meta/usage-shared"
  mkdir -p "$(dirname "$cache")"

  # headroom: freshness 3 minutes — too early to refresh, take the cache
  printf 'SHARED_TS=%s\nSHARED_PCT=%q\n' "$(( $(date +%s) - 180 ))" '30% · W 5%' > "$cache"
  rm -f "$TMP/herdr.log" "$XDG_RUNTIME_DIR/claude-herdr-meta/w9_p1"
  fire Stop "$PROJ"
  check "with headroom the cache lives long" grep -q '30%' <<<"$(display_agent)"

  # near the edge: the same 3 minutes — time to fetch fresh numbers
  printf 'SHARED_TS=%s\nSHARED_PCT=%q\n' "$(( $(date +%s) - 180 ))" '92% · W 5%' > "$cache"
  rm -f "$TMP/herdr.log" "$XDG_RUNTIME_DIR/claude-herdr-meta/w9_p1"
  fire Stop "$PROJ"
  check "near the edge the numbers are refetched" grep -q '24%' <<<"$(display_agent)"
}

t_fanout_usage() {
  local other=w9:p2
  export HERDR_PANE_ID="w9:p1"
  printf '{"result":{"agents":[{"agent":"claude","pane_id":"w9:p1","cwd":"%s"},{"agent":"claude","pane_id":"w9:p2","cwd":"%s"}]}}' \
    "$PROJ" "$PROJ" > "$TMP/agent-list.json"

  local state_dir="$XDG_RUNTIME_DIR/claude-herdr-meta"
  printf 'TITLE=%q\nWORKING=%q\nBLOCKED=\nLAST_SEQ=5\nLAST_USAGE_TS=0\nUSAGE=%q\n' \
    'old title' 'old working' '10%' > "$state_dir/w9_p2"

  fresh_usage
  rm -f "$TMP/herdr.log"
  fire Stop "$PROJ"

  local d_other
  d_other=$(awk -F'\t' -v pane="$other" \
    '$1=="pane" && $2=="report-metadata" && $3==pane {
      for (i=4;i<NF;i++) if ($i=="--display-agent") { print $(i+1); exit }
    }' "$TMP/herdr.log")
  check "second pane got report-metadata" [ -n "$d_other" ]
  check "second pane has the fresh percent" grep -q '24%' <<<"$d_other"
  check "second pane state updated" grep -q 'USAGE=.*24%' "$state_dir/w9_p2"
}

run_test "fresh /usage on every Claude pane" t_fanout_usage
run_test "near the limit the cache is shorter"          t_cache_ttl_adaptive
run_test "near the edge the mark is more insistent"          t_marker_severity
run_test "a limit running out is marked"           t_marker_when_high
run_test "with headroom the line is clean"          t_no_marker_when_low
run_test "low charge is marked"              t_marker_battery
run_test "weekly limit in the sidebar"        t_weekly_usage
run_test "bottom: agent and percent"            t_display_agent
run_test "top: only the branch"              t_tab_label
run_test "sidebar lines are not duplicated"    t_no_duplication
run_test "directory without git"                   t_no_git
run_test "default Space → worktree name"    t_space_default_renamed
run_test "manual Space name is left alone"       t_space_manual_kept
run_test "correct name is not rewritten"    t_space_noop

printf '\ntotal: %d ok, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
