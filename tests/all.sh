#!/usr/bin/env bash
# Runs every test: tests/*.sh, the hook tests next to the hooks, and the retro script test.
# Exit 1 when any of them fails. Used by CI on Linux and macOS.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
failed=()
for t in "$ROOT"/tests/*.sh "$ROOT"/store/.claude/hooks/*.test.sh; do
  [ "$t" = "$ROOT/tests/all.sh" ] && continue
  name="${t#"$ROOT"/}"
  if out="$(bash "$t" 2>&1)"; then
    printf 'ok    %s\n' "$name"
  else
    printf 'FAIL  %s\n' "$name"
    printf '%s\n' "$out" | grep -A2 -E 'FAIL|rror' | head -40 | sed 's/^/      /'
    failed+=("$name")
  fi
done
if python3 "$ROOT/store/.claude/skills/retro/scripts/test_mine.py" >/dev/null 2>&1; then
  printf 'ok    retro/scripts/test_mine.py\n'
else
  printf 'FAIL  retro/scripts/test_mine.py\n'; failed+=(test_mine.py)
fi
echo
[ ${#failed[@]} -eq 0 ] && { echo "all passed"; exit 0; }
echo "failed: ${failed[*]}"
exit 1
