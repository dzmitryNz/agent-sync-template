#!/usr/bin/env bash
# Auto/API percent rounding as on Cursor /usage.
set -uo pipefail

BIN="$(cd "$(dirname "$0")/.." && pwd)/bin/cursor-usage.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "not satisfied: $*"; fi; }

TMP="$(mktemp -d)"
export CURSOR_USAGE_CACHE="$TMP/cache"
export CURSOR_USAGE_JSON='{"planUsage":{"autoPercentUsed":16.062,"apiPercentUsed":0.4},"billingCycleStart":1,"billingCycleEnd":2}'

out="$("$BIN")"
check "Auto rounded to 16" grep -qx 'AUTO=16' <<<"$(printf '%s\n' "$out" | grep '^AUTO=')"
check "API under 1% becomes 1" grep -qx 'API=1' <<<"$(printf '%s\n' "$out" | grep '^API=')"
check "sidebar line" grep -q 'LINE=Auto 16% · API 1%' <<<"$out"

export CURSOR_USAGE_JSON='{"planUsage":{"autoPercentUsed":1}}'
cached="$("$BIN" --cached)"
check "cache skips a new json fetch" grep -qx 'AUTO=16' <<<"$(printf '%s\n' "$cached" | grep '^AUTO=')"

rm -rf "$TMP"
printf '\ntotal: %d ok, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
