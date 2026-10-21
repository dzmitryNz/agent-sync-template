#!/usr/bin/env bash
# Will the limit last until reset at the current average burn rate: blue|gray|yellow|red.
# Herdr sidebar labels use arrow glyphs from this level (herdr-pane-meta.sh).
#   limit-pace.sh <used_pct> <reset_epoch> <window_sec> [now_epoch]
#   limit-pace.sh --parse-reset "<text from /usage>" [now_epoch]
# A reset time with no "(Zone)" uses LIMIT_PACE_TZ, or LIMIT_PACE_GAP_HOURS
# (signed integer hours from UTC) when the zone name is empty. A zone written
# in the text wins over both. Missing or bad input prints nothing, exit 0.
set -u
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

parse_reset() {
  local text=$1 now=${2:-$(date +%s)} tz='' rest mon day time year at gap posix=0
  is_int "$now" || return 0
  case "$text" in
    *'('*')'*) tz=${text##*(}; tz=${tz%%)*}; rest=${text%%(*} ;;
    *) rest=$text ;;
  esac
  if [ -z "$tz" ]; then
    tz=${LIMIT_PACE_TZ:-}
  fi
  if [ -z "$tz" ] && [ -n "${LIMIT_PACE_GAP_HOURS:-}" ]; then
    gap=$LIMIT_PACE_GAP_HOURS
    case "$gap" in
      ''|*[!0-9-]*|-*[!0-9]*) return 0 ;;
    esac
    # POSIX TZ offset is west-positive, opposite of the ISO sign.
    case "$gap" in
      -*) tz="XXX${gap#-}" ;;
      *)  tz="XXX-$gap" ;;
    esac
    posix=1
  fi
  case "$tz" in *[!A-Za-z0-9_/+-]*) return 0 ;; esac
  # glibc treats an unknown zone as the system zone — require a real zoneinfo file.
  if [ "$posix" -eq 0 ]; then
    [ -z "$tz" ] || [ -e "/usr/share/zoneinfo/$tz" ] || return 0
  fi
  read -r mon day time <<<"${rest//,/ }"
  [ -n "$time" ] || return 0
  [ -z "$tz" ] || export TZ="$tz"
  # No year in the text: use current year, roll forward if that lands in the past
  year=$(date -d "@$now" +%Y)
  at=$(date -d "$mon $day $year $time" +%s 2>/dev/null) || return 0
  if [ "$at" -lt $((now - 86400)) ]; then
    at=$(date -d "$mon $day $((year + 1)) $time" +%s 2>/dev/null) || return 0
  fi
  printf '%s\n' "$at"
}

pace() {
  local used=$1 reset=$2 window=$3 now=${4:-$(date +%s)}
  is_int "$used" && is_int "$reset" && is_int "$window" && is_int "$now" || return 0
  used=$((10#$used)); window=$((10#$window))
  [ "$window" -gt 0 ] || return 0
  local remaining=$((reset - now))
  # reset already passed or beyond the window: stale or bad data
  [ "$remaining" -gt 0 ] && [ "$remaining" -le "$window" ] || return 0
  [ "$used" -lt 100 ] || { echo red; return 0; }
  local elapsed=$((window - remaining))
  # early in the window the average is too noisy
  [ $((elapsed * 10)) -ge "$window" ] || { echo gray; return 0; }
  local forecast=$((used * window / elapsed))
  if   [ "$forecast" -lt 60 ];  then echo blue
  elif [ "$forecast" -le 100 ]; then echo gray
  elif [ "$forecast" -le 130 ]; then echo yellow
  else echo red
  fi
}

if [ "${1:-}" = "--parse-reset" ]; then
  parse_reset "${2:-}" "${3:-}"
else
  pace "${1:-}" "${2:-}" "${3:-}" "${4:-}"
fi
exit 0
