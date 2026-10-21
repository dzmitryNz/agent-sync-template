#!/usr/bin/env bash
# CI smoke test on a real Mac: start scripts the way launchd and Claude hooks do, with
# /bin/bash 3.2 and a bare PATH, so compat.sh itself has to find the Homebrew GNU tools
# and re-run the script with Homebrew bash. tests/all.sh cannot show this: in CI the
# gnubin dirs are already first in PATH.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
H="${RUNNER_TEMP:-$(mktemp -d)}/smoke-home"
mkdir -p "$H"
BARE=(env -i HOME="$H" PATH=/usr/bin:/bin SYNC_HOME="$REPO")
BAD='command not found|invalid option|illegal option|unrecognized option|usage: (date|stat|sed|readlink|find|touch)|declare: -A|bad substitution|syntax error|needs Homebrew'
FAIL=0

run() { # run <name> <expect-regex|-> <command...>: no shell/tool errors, and the expected text
  local name="$1" want="$2" out; shift 2
  out="$("$@" 2>&1)"
  if grep -Eq "$BAD" <<<"$out"; then
    FAIL=1; printf 'FAIL  %s\n%s\n' "$name" "$out"
  elif [ "$want" != - ] && ! grep -Eq "$want" <<<"$out"; then
    FAIL=1; printf 'FAIL  %s: no "%s" in\n%s\n' "$name" "$want" "$out"
  else
    printf 'ok    %s\n' "$name"
  fi
}

# bash 4 features after the re-exec
cat > "$H/bash4.sh" <<EOF
#!/bin/bash
. "$REPO/bin/lib/compat.sh" || exit 1
declare -A m=([k]=v); mapfile -t l < <(printf 'a\nb\n')
echo "bash \${BASH_VERSINFO[0]} \${m[k]} \${#l[@]} \$(date -d @0 -u +%Y) \$(stat -c %s /dev/null)"
EOF
run "re-exec with Homebrew bash, GNU date and stat" '^bash [4-9] v 2 1970 0$' "${BARE[@]}" /bin/bash "$H/bash4.sh"

run "tools-check" 'MISSING|ok' "${BARE[@]}" /bin/bash "$REPO/bin/tools-check.sh"
run "timers status (launchd)" 'off|loaded' "${BARE[@]}" /bin/bash "$REPO/bin/agent-sync.sh" timers status agent-sync

# herdr-notify uses declare -A once it has a token and an agent list
printf 'TELEGRAM_BOT_TOKEN=x\nTELEGRAM_CHAT_ID=1\n' > "$H/notify.env"
echo '{"result":{"agents":[]}}' > "$H/agents.json"
run "herdr-notify" - "${BARE[@]}" HERDR_NOTIFY_ENV="$H/notify.env" HERDR_AGENTS_FILE="$H/agents.json" \
  /bin/bash "$REPO/bin/herdr-notify.sh"

# limit-wake: reset time parsed with GNU date, launchd unit planned (dry run)
mkdir -p "$H/rt/claude-herdr-meta"
reset="$(LC_ALL=C date -d "$(date -d '+2 hours' '+%Y-%m-%d %H:00')" '+%b %-d, %-I%P') (UTC)"
printf 'SHARED_SESSION_RESET=%q\n' "$reset" > "$H/rt/claude-herdr-meta/usage-limits"
run "limit-wake plan" 'LIMIT_WAKE target=w1:p1 .*unit=dev.agent-sync.limit-wake-w1-p1' \
  "${BARE[@]}" XDG_RUNTIME_DIR="$H/rt" HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_BIN=/usr/bin/true \
  LIMIT_WAKE_DRY_RUN=1 LC_ALL=C TZ=UTC /bin/bash -c \
  "echo '{\"hook_event_name\":\"Stop\",\"message\":\"You have hit your usage limit\"}' | '$REPO/store/.claude/hooks/limit-wake-hook.sh'"

exit "$FAIL"
