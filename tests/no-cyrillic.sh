#!/usr/bin/env bash
# The template text is English. Cyrillic is allowed only on a line marked cyrillic-ok.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

hits="$(git ls-files -co --exclude-standard 2>/dev/null | grep -v '^tests/no-cyrillic.sh$' | grep -v '^README.ru.md$' \
  | xargs -r grep -nP '[\x{0400}-\x{04FF}]' 2>/dev/null \
  | grep -v 'cyrillic-ok' | cut -c1-140)"

if [ -z "$hits" ]; then echo "  ok    no Cyrillic outside allowed data lines"; echo; echo "1 passed, 0 failed"; exit 0; fi
printf '%s\n' "$hits" | head -40
echo "  FAIL  Cyrillic text found: $(printf '%s\n' "$hits" | wc -l) line(s)"; echo; echo "0 passed, 1 failed"; exit 1
