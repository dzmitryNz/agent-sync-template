#!/usr/bin/env bash
# Auto and API percents from the same GetCurrentPeriodUsage as Cursor CLI /usage.
# Prints AUTO, API and LINE for the Cursor pane label. --cached skips the network.
# Failures stay silent: this hook runs on every action.
set -u


CACHE="${CURSOR_USAGE_CACHE:-${XDG_RUNTIME_DIR:-/tmp}/cursor-usage}"
PACE="$(dirname "$(readlink -f "$0")")/limit-pace.sh"
CACHED=0
[ "${1:-}" = "--cached" ] && CACHED=1

load_cache() {
  AUTO=""; API=""; LINE=""; FETCHED=0
  [ -f "$CACHE" ] || return 1
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      AUTO) AUTO=$v ;;
      API) API=$v ;;
      LINE) LINE=$v ;;
      FETCHED) FETCHED=$v ;;
    esac
  done < "$CACHE"
  [ -n "$LINE" ]
}

emit() {
  printf 'AUTO=%s\nAPI=%s\nLINE=%s\n' "$AUTO" "$API" "$LINE"
}

fresh() {
  local max=$1 now age ttl=300
  case "$FETCHED" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  age=$((now - FETCHED))
  [ "$max" -ge 85 ] && ttl=60
  [ "$max" -ge 70 ] && [ "$max" -lt 85 ] && ttl=120
  [ "$age" -lt "$ttl" ]
}

arrow() {
  local color
  [ -x "$PACE" ] || return 0
  color=$("$PACE" "$1" "${RESET:-}" "${WINDOW:-}" 2>/dev/null) || true
  case "$color" in
    blue) printf '↑' ;;
    yellow) printf '↓' ;;
    red) printf '↓↓' ;;
  esac
}

save() {
  local max=$AUTO
  [ "$API" -gt "$max" ] && max=$API
  LINE="Auto $(arrow "$AUTO")${AUTO}% · API $(arrow "$API")${API}%"
  mkdir -p "$(dirname "$CACHE")" 2>/dev/null || true
  FETCHED=$(date +%s)
  printf 'AUTO=%s\nAPI=%s\nLINE=%s\nFETCHED=%s\n' "$AUTO" "$API" "$LINE" "$FETCHED" > "$CACHE.$$" \
    && mv -f "$CACHE.$$" "$CACHE"
  emit
}

if [ "$CACHED" = 1 ]; then
  load_cache && emit
  exit 0
fi

if load_cache; then
  max=$AUTO
  [ "${API:-0}" -gt "$max" ] 2>/dev/null && max=$API
  if fresh "$max"; then
    emit
    exit 0
  fi
fi

fetched=$(python3 - "$CACHE" <<'PY'
import json, os, sys, urllib.request
from pathlib import Path

def rnd(value):
    x = max(0.0, min(100.0, float(value)))
    if 0 < x < 1:
        return 1
    return int(round(x))

def as_secs(value):
    if value is None or value == "":
        return None
    n = int(float(value))
    if n > 10**12:
        n //= 1000
    return n

raw = os.environ.get("CURSOR_USAGE_JSON")
if raw:
    data = json.loads(raw)
else:
    auth_path = Path(os.environ.get("CURSOR_AUTH_FILE") or Path.home() / ".config/cursor/auth.json")
    token = json.loads(auth_path.read_text()).get("accessToken") or ""
    if not token:
        raise SystemExit(1)
    req = urllib.request.Request(
        "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
        data=b"{}",
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Connect-Protocol-Version": "1",
            "x-cursor-client-version": "cli-2026.10.22-27dcf5f",
            "x-cursor-client-type": "cli",
        },
    )
    with urllib.request.urlopen(req, timeout=8) as resp:
        data = json.loads(resp.read().decode())

plan = data.get("planUsage") or {}
if "autoPercentUsed" not in plan or "apiPercentUsed" not in plan:
    raise SystemExit(1)
auto = rnd(plan["autoPercentUsed"])
api = rnd(plan["apiPercentUsed"])
start = as_secs(data.get("billingCycleStart"))
end = as_secs(data.get("billingCycleEnd"))
reset = end or 0
window = (end - start) if start and end and end > start else 0
sys.stdout.write(f"{auto} {api} {reset} {window}\n")
PY
) || fetched=""

if [ -z "$fetched" ]; then
  load_cache && emit
  exit 0
fi

read -r AUTO API RESET WINDOW <<<"$fetched"
case "$AUTO$API" in *[!0-9]*) load_cache && emit; exit 0 ;; esac
save
exit 0
