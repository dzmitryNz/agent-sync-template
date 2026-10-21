#!/usr/bin/env bash
# The template must carry no personal or project-specific literals.
# Two checks:
#   1. words from tests/no-literals.words (your company, logins, account ids; see no-literals.words.example;
#      the file is gitignored so the list itself never ships) — lines between <!-- EXAMPLE:BEGIN ... --> and
#      <!-- EXAMPLE:END --> and the *.example* files are exempt;
#   2. private-network IPs — never allowed, not even in example blocks (use STAND_DB_HOST).
# Word patterns are extended regexes, one per line. mawk does not treat \b as a word
# boundary, so the scan strips example blocks with awk and matches with grep -E.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

WORDS_FILE="${NO_LITERALS_WORDS:-tests/no-literals.words}"
PRIVATE_IP='192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+|10\.[0-9]+\.[0-9]+\.[0-9]+|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+'

# \b is not a word boundary in mawk, and a joined "|" pattern hid misses.
# Turn each \b into a boundary grep -E can see.
prep_patterns() {
  grep -v -E '^\s*(#|$)' "$1" | sed -e 's/\\b/(^|[^a-zA-Z0-9_])/g' > "$2"
}

# Blank example-block lines so later grep -n still reports the original line.
strip_examples() {
  awk '
    /^[[:space:]]*<!-- EXAMPLE:BEGIN/ { skip=1; print ""; next }
    /^[[:space:]]*<!-- EXAMPLE:END/   { skip=0; print ""; next }
    skip { print ""; next }
    { print }
  ' "$1"
}

if [ "${1:-}" = --boundary ]; then
  # Own list. A fresh clone has no words file, and the private list is not the probe.
  btmp="$(mktemp -d)"
  printf '%s\n' '\bacme\b' > "$btmp/words"
  prep_patterns "$btmp/words" "$btmp/pat"
  printf '%s\n' 'x acme y' > "$btmp/line"
  if grep -iqE -f "$btmp/pat" "$btmp/line"; then
    echo "  ok    boundary catches 'x acme y'"
    rm -rf "$btmp"
    exit 0
  fi
  echo "  FAIL  'x acme y' was not caught"
  rm -rf "$btmp"
  exit 1
fi

hits=0
if [ -f "$WORDS_FILE" ]; then
  ptmp="$(mktemp -d)"
  trap 'rm -rf "$ptmp"' EXIT
  prep_patterns "$WORDS_FILE" "$ptmp/pat"
  if [ -s "$ptmp/pat" ]; then
    while IFS= read -r f; do
      # LICENSE names the copyright holder; that string is on the deny list on purpose.
      # The boundary self-test names a sample token on purpose.
      case "$f" in
        tests/no-literals.sh|tests/no-literals-boundary.sh|LICENSE|*.example|*.example.*|*.words) continue ;;
      esac
      strip_examples "$f" > "$ptmp/body"
      out="$(grep -inE -f "$ptmp/pat" "$ptmp/body" || true)"
      if [ -n "$out" ]; then
        printf '%s\n' "$out" | while IFS= read -r line; do
          printf '%s:%s\n' "$f" "$(printf '%s' "$line" | cut -c1-140)"
        done
        hits=$((hits+1))
      fi
    done < <(git ls-files -co --exclude-standard 2>/dev/null || find . -type f -not -path './.git/*')
  fi
else
  echo "  skip  $WORDS_FILE missing: copy tests/no-literals.words.example and list your own names"
fi

ip_hits="$(git ls-files -co --exclude-standard 2>/dev/null | grep -v '^tests/no-literals.sh$' \
  | xargs -r grep -nE "$PRIVATE_IP" 2>/dev/null | cut -c1-140)"
if [ -n "$ip_hits" ]; then printf '%s\n' "$ip_hits"; hits=$((hits+1)); fi

if [ "$hits" -eq 0 ]; then echo "  ok    no literals outside EXAMPLE blocks"; echo; echo "1 passed, 0 failed"; exit 0; fi
echo "  FAIL  literals found in $hits file(s)"; echo; echo "0 passed, 1 failed"; exit 1
