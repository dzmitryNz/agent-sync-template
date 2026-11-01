#!/usr/bin/env bash
# Shared limit reset timing + per-pane systemd one-shot (Linux).
# Used by limit-wake-hook and limit-deferred-handoff.
set -euo pipefail

limits_file() {
  printf '%s/usage-limits' "${LIMIT_STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/claude-herdr-meta}"
}

# After weekly reset, herdr meta may still show W=100% until the pane runs again.
limit_sanitize_usage_metadata() {
  local f now week_ts pad tmp line
  f="$(limits_file)"
  [[ -r "$f" ]] || return 0
  # shellcheck disable=SC1090
  . "$f"
  now=$(date +%s)
  pad=${LIMIT_WAKE_PAD_SEC:-300}
  week_ts=${SHARED_WEEK_RESET_TS:-0}
  [[ "$week_ts" =~ ^[0-9]+$ ]] && ((week_ts > 0)) || return 0
  ((now >= week_ts)) || return 0
  tmp=$(mktemp)
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      SHARED_WEEK_PCT=*) printf 'SHARED_WEEK_PCT=0\n' >>"$tmp" ;;
      SHARED_FETCHED_AT=*) printf 'SHARED_FETCHED_AT=%s\n' "$now" >>"$tmp" ;;
      *) printf '%s\n' "$line" >>"$tmp" ;;
    esac
  done <"$f"
  mv "$tmp" "$f"
}

limit_cancel_pane_timers() {
  local pane=$1 base suffix u
  base="${pane//[^A-Za-z0-9]/-}"
  for suffix in wake deferred-handoff; do
    u="agent-limit-${suffix}-${base}"
    systemctl --user stop "${u}.timer" "${u}.service" 2>/dev/null || true
    systemctl --user reset-failed "${u}.timer" "${u}.service" 2>/dev/null || true
  done
}

# Prints earliest future reset epoch (session/week from usage-limits), or empty.
limit_nearest_reset_epoch() {
  local f now year reset reset_epoch epoch
  f="$(limits_file)"
  [[ -r "$f" ]] || return 1
  # shellcheck disable=SC1090
  . "$f"
  now=$(date +%s)
  year=$(date +%Y)
  reset_epoch=0
  for reset in "${SHARED_SESSION_RESET:-}" "${SHARED_WEEK_RESET:-}"; do
    [[ -n "$reset" ]] || continue
    reset=${reset% \(*)}
    epoch=$(date -d "${reset//,/} $year" +%s 2>/dev/null || true)
    [[ -n "$epoch" ]] || continue
    if ((epoch <= now)); then
      epoch=$(date -d "${reset//,/} $((year + 1))" +%s 2>/dev/null || true)
    fi
    if [[ -n "$epoch" && "$epoch" -gt "$now" ]] &&
      { [[ "$reset_epoch" -eq 0 ]] || [[ "$epoch" -lt "$reset_epoch" ]]; }; then
      reset_epoch=$epoch
    fi
  done
  ((reset_epoch > now)) || return 1
  printf '%s' "$reset_epoch"
}

# Wake at reset + LIMIT_WAKE_PAD_SEC (default 300).
limit_wake_epoch() {
  local reset pad
  reset=$(limit_nearest_reset_epoch) || return 1
  pad=${LIMIT_WAKE_PAD_SEC:-300}
  printf '%s' "$((reset + pad))"
}

limit_wake_delay_seconds() {
  local wake now f pad week_ts week_pct thresh
  now=$(date +%s)
  pad=${LIMIT_WAKE_PAD_SEC:-300}
  thresh=${LIMIT_WEEK_HIT_PCT:-90}
  f="$(limits_file)"
  week_ts=0
  week_pct=0
  if [[ -r "$f" ]]; then
    # shellcheck disable=SC1090
    . "$f"
    week_ts=${SHARED_WEEK_RESET_TS:-0}
    week_pct=${SHARED_WEEK_PCT:-0}
    case "$week_pct" in ''|*[!0-9]*) week_pct=0 ;; esac
  fi
  # Sanitize may zero WEEK_PCT when WEEK_RESET_TS is past; read the hit signal first.
  limit_sanitize_usage_metadata
  if [[ -r "$f" ]]; then
    # shellcheck disable=SC1090
    . "$f"
    week_ts=${SHARED_WEEK_RESET_TS:-0}
  fi
  # Only short-circuit on a past weekly reset when the week limit was what hit.
  # A stale WEEK_RESET_TS after the weekly reset must not fire a 30s wake while
  # the session limit is still active.
  if [[ "$week_ts" =~ ^[0-9]+$ ]] && ((week_ts > 0)) && ((week_pct >= thresh)); then
    if ((now >= week_ts + pad)); then
      printf '%s' 30
      return 0
    fi
    if ((now >= week_ts)); then
      printf '%s' "$((week_ts + pad - now))"
      return 0
    fi
  fi
  wake=$(limit_wake_epoch) || return 1
  ((wake > now)) || return 1
  printf '%s' "$((wake - now))"
}

# unit_suffix: wake | deferred-handoff
limit_schedule_pane_job() {
  local pane=$1 unit_suffix=$2
  shift 2
  [[ $# -gt 0 ]] || return 1

  local delay unit log_dir
  limit_sanitize_usage_metadata
  delay=$(limit_wake_delay_seconds) || return 1
  unit="agent-limit-${unit_suffix}-${pane//[^A-Za-z0-9]/-}"

  systemctl --user stop "${unit}.timer" "${unit}.service" 2>/dev/null || true
  systemctl --user reset-failed "${unit}.timer" "${unit}.service" 2>/dev/null || true

  if [[ "${LIMIT_WAKE_DRY_RUN:-0}" == 1 ]]; then
    printf 'LIMIT_SCHEDULE unit=%s delay=%ss cmd=%q\n' "$unit" "$delay" "$*"
    return 0
  fi

  systemd-run --user \
    "--unit=$unit" \
    "--on-active=${delay}s" \
    --collect \
    --quiet \
    "$@" >/dev/null 2>&1 || return 1

  log_dir="${XDG_RUNTIME_DIR:-/tmp}/claude-herdr-meta"
  mkdir -p "$log_dir"
  printf '%s\tpane=%s\tunit=%s\tdelay=%s\n' \
    "$(date --iso-8601=seconds)" "$pane" "$unit" "$delay" \
    >>"$log_dir/limit-schedule.log"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    schedule-job)
      shift
      limit_schedule_pane_job "$@"
      ;;
    wake-epoch)
      limit_wake_epoch
      ;;
    wake-delay)
      limit_wake_delay_seconds
      ;;
    sanitize-limits)
      limit_sanitize_usage_metadata
      ;;
    cancel-pane)
      limit_cancel_pane_timers "${2:?pane}"
      ;;
    -h|--help)
      echo "usage: limit-schedule.sh schedule-job|cancel-pane|sanitize-limits ..."
      exit 0
      ;;
    *)
      echo "limit-schedule.sh: unknown command" >&2
      exit 2
      ;;
  esac
fi
