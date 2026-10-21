#!/usr/bin/env bash
# Check that the sync came up after boot.
. "$(dirname "$(readlink -f "$0")")/lib/project-env.sh" || exit 1
echo "=== timers ==="
"$(dirname "$(readlink -f "$0")")/agent-sync.sh" timers status agent-sync-boundary agent-sync agent-history
echo
echo "=== recent runs ==="
if [ "$AGENT_SYNC_OS" = darwin ]; then
  cat "$HOME"/Library/Logs/agent-sync/*.log 2>/dev/null | grep -Ei 'error|failed|could not|unreachable|refused' | tail -8
else
  journalctl --user -u agent-sync-boundary.service -u agent-sync.service -u agent-history.service \
    --since "-20min" --no-pager | grep -Ei 'Finished|Failed|could not|unreachable' | tail -8
fi
echo
echo "=== config repository ==="
cd "$HOME/.agent-sync" || exit 1
printf 'not pushed / not pulled (behind ahead): '
git rev-list --left-right --count origin/main...HEAD 2>/dev/null || echo '?'
printf 'uncommitted: '; git status --porcelain | wc -l
echo
echo "=== symlinks in place ==="
for p in .claude/CLAUDE.md .claude/AGENTS.md .claude/settings.json; do
  if [ -L "$HOME/$p" ] && [ -e "$HOME/$p" ]; then echo "ok     $p"; else echo "BROKEN $p"; fi
done
n=0; bad=0
if [ -d "$HOME/.claude/projects" ]; then
  for d in "$HOME"/.claude/projects/*/memory; do
    [ -L "$d" ] || continue; n=$((n+1)); [ -e "$d" ] || bad=$((bad+1))
  done
fi
echo "project memory: $n symlinks, broken: $bad"
echo
echo "=== skills outside the sync (move them to ~/.claude/skills) ==="
ls -d "$PROJECT_ROOT"/.claude/skills/*/ 2>/dev/null || echo "none"
echo
echo "=== session history ==="
if [ -d "$HOME/.claude/projects" ]; then
  printf 'local: '; find "$HOME/.claude/projects" -name '*.jsonl' | wc -l
else
  echo 'local: ~/.claude/projects is absent'
fi
if [ -z "$SYNC_SERVER" ]; then
  echo 'on the server: SYNC_SERVER is not set, check skipped'
else
  printf 'on the server: '; ssh -o BatchMode=yes -o ConnectTimeout=8 "$SYNC_SERVER" 'find ~/agent-history/claude -name "*.jsonl" | wc -l' 2>/dev/null || echo 'server unreachable'
fi
