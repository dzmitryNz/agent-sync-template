#!/usr/bin/env bash
# A prose mention of EXAMPLE:BEGIN must not open a skip region.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCAN="$ROOT/tests/no-literals.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }

grep -q '/^\[\[:space:\]\]\*<!-- EXAMPLE:BEGIN/' "$SCAN" \
  && ok "skip matches only a whole EXAMPLE:BEGIN comment line" \
  || fail "awk skip is not anchored to a whole comment line"

d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
cat > "$d/sample.md" <<'EOF'
Prose mentions the marker `<!-- EXAMPLE:BEGIN -->` and scanning continues.
zzliteralzz
<!-- EXAMPLE:BEGIN optional -->
zzliteralzz
<!-- EXAMPLE:END -->
clean
EOF

out="$(awk -v pat='zzliteralzz' '
  /^[[:space:]]*<!-- EXAMPLE:BEGIN/ { skip=1; next }
  /^[[:space:]]*<!-- EXAMPLE:END/   { skip=0; next }
  !skip && tolower($0) ~ tolower(pat) { printf "%d\n", FNR }
' "$d/sample.md")"

printf '%s\n' "$out" | grep -qx 2 \
  && ok "literal after a prose EXAMPLE:BEGIN is caught" \
  || fail "literal after a prose EXAMPLE:BEGIN was not caught" "$out"
printf '%s\n' "$out" | grep -qx 4 \
  && fail "literal inside an EXAMPLE block was caught" \
  || ok "literal inside an EXAMPLE block is skipped"

printf '\ntotal: %d ok, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
