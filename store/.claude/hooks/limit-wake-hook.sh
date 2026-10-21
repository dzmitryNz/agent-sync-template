#!/usr/bin/env bash
set -euo pipefail
for _compat in "$(dirname "$(readlink -f "$0")")/../../../bin/lib/compat.sh" "${SYNC_HOME:-$HOME/.agent-sync}/bin/lib/compat.sh"; do [ -f "$_compat" ] && { . "$_compat" || exit 1; break; }; done

usage() {
  printf '%s\n' \
    'limit-wake-hook: schedule or run a per-pane limit wake-up' \
    '  limit-wake-hook.sh --run --target PANE --message TEXT'
}

die() {
  printf 'limit-wake-hook: %s\n' "$1" >&2
  exit 2
}

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  usage
  exit 0
fi

mode=hook
launchd_label=''
target=${HERDR_PANE_ID:-}
message='continue; the limit reset, continue your assigned task'

while (($#)); do
  case "$1" in
    --run) mode=run; shift ;;
    --target) target=${2:?--target requires a pane id}; shift 2 ;;
    --message) message=${2:?--message requires a value}; shift 2 ;;
    --launchd-label) launchd_label=${2:?--launchd-label requires a value}; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ "$mode" == run && -n "$launchd_label" ]]; then
  # one-shot: the agent fires on its calendar date every year unless it removes itself.
  # The file goes first, so a run that stops early is not loaded again at the next login;
  # bootout stops this process, so it waits for the exit.
  rm -f "$HOME/Library/LaunchAgents/$launchd_label.plist"
  trap 'launchctl bootout "gui/$(id -u)/$launchd_label" >/dev/null 2>&1' EXIT
fi

herdr_bin=${HERDR_BIN:-}
[[ -n "$herdr_bin" ]] || herdr_bin=$(command -v herdr || true)
[[ -x "$herdr_bin" ]] || herdr_bin="$HOME/.local/bin/herdr"
[[ -x "$herdr_bin" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

run_target() {
  local info status
  info=$("$herdr_bin" agent get "$target" 2>/dev/null || true)
  status=$(jq -r '.result.agent.agent_status // empty' <<<"$info")
  case "$status" in
    idle|done|blocked)
      "$herdr_bin" agent prompt "$target" "$message" >/dev/null 2>&1 || true
      ;;
    *)
      printf 'limit-wake-hook: skip target=%s status=%s\n' \
        "$target" "${status:-unknown}" >&2
      ;;
  esac
}

if [[ "$mode" == run ]]; then
  [[ -n "$target" ]] || exit 0
  # herdr finds its socket by XDG_RUNTIME_DIR on Linux; macOS has no /run/user
  [[ "$AGENT_SYNC_OS" == darwin ]] || export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  run_target
  exit 0
fi

[[ "${HERDR_ENV:-}" == 1 ]] || exit 0
[[ -n "$target" ]] || exit 0
payload=$(cat)
event=$(jq -r '.hook_event_name // ""' <<<"$payload" 2>/dev/null || true)
case "$event" in
  Notification|Stop) ;;
  *) exit 0 ;;
esac

text=$(jq -r '[.. | strings] | join("\n")' <<<"$payload" 2>/dev/null || true)
grep -Eiq \
  'rate[ _-]*limit|usage[ _-]*limit|limit[ _-]*(reached|exhausted|exceeded)|out of (your )?credits|resets .*(am|pm|utc|europe)' \
  <<<"$text" || exit 0

limits_file="${XDG_RUNTIME_DIR:-/tmp}/claude-herdr-meta/usage-limits"
[[ -r "$limits_file" ]] || exit 0
# shellcheck disable=SC1090
. "$limits_file"

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
((reset_epoch > now)) || exit 0

wake_epoch=$((reset_epoch + 5 * 60))
delay=$((wake_epoch - now))
script=$(readlink -f "$0")

if [[ "$AGENT_SYNC_OS" == darwin ]]; then
  unit="dev.agent-sync.limit-wake-${target//[^A-Za-z0-9]/-}"
  domain="gui/$(id -u)"
  # A reset is at most 7 days away. An older agent missed its minute (the Mac was off)
  # and would fire on that date next year: remove it, for every pane.
  find "$HOME/Library/LaunchAgents" -maxdepth 1 -name 'dev.agent-sync.limit-wake-*.plist' -mtime +8 \
    2>/dev/null | while read -r old; do
    launchctl bootout "$domain/$(basename "$old" .plist)" >/dev/null 2>&1
    rm -f "$old"
  done || true
  plist="$HOME/Library/LaunchAgents/$unit.plist"
  if [[ "${LIMIT_WAKE_DRY_RUN:-0}" == 1 ]]; then
    printf 'LIMIT_WAKE target=%s reset=%s delay=%ss unit=%s\n' \
      "$target" "$(date -d "@$reset_epoch" --iso-8601=seconds)" "$delay" "$unit"
    exit 0
  fi
  read -r w_month w_day w_hour w_min <<<"$(date -d "@$wake_epoch" '+%-m %-d %-H %-M')"
  body=$(
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n  <key>Label</key><string>%s</string>\n' "$unit"
    printf '  <key>ProgramArguments</key>\n  <array>\n'
    for a in "$script" --run --target "$target" --message "$message" --launchd-label "$unit"; do
      printf '    <string>%s</string>\n' "$(agent_sync_xml_escape "$a")"
    done
    printf '  </array>\n  <key>StartCalendarInterval</key>\n  <dict>\n'
    printf '    <key>Month</key><integer>%s</integer>\n    <key>Day</key><integer>%s</integer>\n' "$w_month" "$w_day"
    printf '    <key>Hour</key><integer>%s</integer>\n    <key>Minute</key><integer>%s</integer>\n' "$w_hour" "$w_min"
    printf '  </dict>\n  <key>EnvironmentVariables</key>\n  <dict>\n'
    printf '    <key>PATH</key><string>%s</string>\n  </dict>\n</dict>\n</plist>' "$(agent_sync_xml_escape "$PATH")"
  )
  if launchctl print "$domain/$unit" >/dev/null 2>&1; then
    # Stop and Notification both report one limit: the same wake is already planned
    [[ -f "$plist" && "$(cat "$plist")" == "$body" ]] && exit 0
    # A new limit replaces the old wake, which may have missed its minute while the Mac
    # was off. bootout returns before launchd has removed the job: wait up to 5 s.
    launchctl bootout "$domain/$unit" >/dev/null 2>&1 || true
    for _ in $(seq 25); do
      launchctl print "$domain/$unit" >/dev/null 2>&1 || break
      sleep 0.2
    done
  fi
  mkdir -p "${plist%/*}"
  printf '%s\n' "$body" > "$plist"
  launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1 || exit 0
else
  unit="agent-limit-wake-${target//[^A-Za-z0-9]/-}"
  if systemctl --user is-active --quiet "$unit.timer" 2>/dev/null ||
    systemctl --user is-active --quiet "$unit.service" 2>/dev/null; then
    exit 0
  fi
  if [[ "${LIMIT_WAKE_DRY_RUN:-0}" == 1 ]]; then
    printf 'LIMIT_WAKE target=%s reset=%s delay=%ss unit=%s\n' \
      "$target" "$(date -d "@$reset_epoch" --iso-8601=seconds)" "$delay" "$unit"
    exit 0
  fi

  systemd-run --user \
    "--unit=$unit" \
    "--on-active=${delay}s" \
    --collect \
    --quiet \
    "$script" --run --target "$target" --message "$message" >/dev/null 2>&1 || exit 0
fi

log_dir="${XDG_RUNTIME_DIR:-/tmp}/claude-herdr-meta"
mkdir -p "$log_dir"
printf '%s\tpane=%s\treset=%s\tunit=%s\n' \
  "$(date --iso-8601=seconds)" "$target" \
  "$(date -d "@$reset_epoch" --iso-8601=seconds)" "$unit" \
  >>"$log_dir/limit-wake.log"
