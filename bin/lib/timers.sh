#!/usr/bin/env bash
# "agent-sync.sh timers": the scheduled jobs. Source it from agent-sync.sh, do not run it.
#
#   timers enable [name...]   default: agent-sync-boundary, agent-sync, and agent-history when SYNC_SERVER is set
#   timers disable [name...]  default: every job this repo knows
#   timers status
#
# Linux and WSL: links systemd/*.service|*.timer into the systemd user dir and enables them.
# macOS: writes ~/Library/LaunchAgents/dev.agent-sync.<name>.plist and loads it with launchctl.
# launchd has no logout hook, so on macOS the 5-minute sync is what pushes the last changes.

TIMER_NAMES='agent-sync-boundary agent-sync agent-history herdr-notify herdr-host-ping tailcat-serve'
LAUNCHD_PREFIX=dev.agent-sync

timers_default() {
  local n='agent-sync-boundary agent-sync'
  [ -n "${SYNC_SERVER:-}" ] && n="$n agent-history"
  echo "$n"
}

timers_check_names() {
  local n
  for n in "$@"; do
    case " $TIMER_NAMES " in *" $n "*) ;; *) warn "timers: unknown job: $n (known: $TIMER_NAMES)"; return 2 ;; esac
  done
}

# systemd unit that is enabled for a job: the timer when there is one
systemd_unit() {
  if [ -f "$SYNC_HOME/systemd/$1.timer" ]; then echo "$1.timer"; else echo "$1.service"; fi
}

systemd_user_ok() {
  systemctl --user show-environment >/dev/null 2>&1 && return 0
  if [ "$AGENT_SYNC_OS" = wsl ]; then
    warn "timers: systemd is off in this WSL distro. Add these lines to /etc/wsl.conf:"
    warn "  [boot]"
    warn "  systemd=true"
    warn "then run 'wsl --shutdown' in Windows (PowerShell) and open the distro again."
  else
    warn "timers: no systemd user session (systemctl --user does not answer)."
  fi
  return 1
}

timers_systemd() {
  local action="$1"; shift
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" n f units=()
  for n in "$@"; do units+=("$(systemd_unit "$n")"); done
  case "$action" in
    enable)
      systemd_user_ok || return 1
      mkdir -p "$dir"
      for n in "$@"; do
        for f in "$SYNC_HOME/systemd/$n".service "$SYNC_HOME/systemd/$n".timer; do
          [ -f "$f" ] && ln -sfn "$f" "$dir/${f##*/}"
        done
      done
      systemctl --user daemon-reload
      systemctl --user enable --now "${units[@]}" || return 1
      printf 'timers: enabled %s\n' "${units[*]}"
      printf 'To keep them running with no graphical session (sync over SSH): loginctl enable-linger "$USER"\n'
      ;;
    disable)
      systemctl --user disable --now "${units[@]}" 2>/dev/null
      for n in "$@"; do
        for f in "$dir/$n".service "$dir/$n".timer; do
          [ -L "$f" ] && case "$(readlink "$f")" in "$SYNC_HOME"/systemd/*) rm -f "$f" ;; esac
        done
      done
      systemctl --user daemon-reload 2>/dev/null
      printf 'timers: disabled %s\n' "${units[*]}"
      ;;
    status)
      systemctl --user is-active "${units[@]}"
      return 0
      ;;
  esac
}

# launchd_plist <name>: print the plist for a job
launchd_plist() {
  local name="$1" args=() interval='' at_load=false
  case "$name" in
    agent-sync)          args=("$SYNC_HOME/bin/agent-sync.sh" sync); interval=300 ;;
    agent-sync-boundary) args=("$SYNC_HOME/bin/agent-sync.sh" pull); at_load=true ;;
    agent-history)       args=("$SYNC_HOME/bin/history-sync.sh"); interval=3600; at_load=true ;;
    herdr-notify)        args=("$SYNC_HOME/bin/herdr-notify.sh"); interval=60 ;;
    herdr-host-ping)     args=("$HOME/.claude/hooks/herdr-host-ping.sh" --all); interval=300 ;;
  esac
  local log="$HOME/Library/Logs/agent-sync/$name.log" a
  printf '<?xml version="1.0" encoding="UTF-8"?>\n'
  printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
  printf '<plist version="1.0">\n<dict>\n'
  printf '  <key>Label</key><string>%s.%s</string>\n' "$LAUNCHD_PREFIX" "$name"
  printf '  <key>ProgramArguments</key>\n  <array>\n'
  for a in "${args[@]}"; do printf '    <string>%s</string>\n' "$(agent_sync_xml_escape "$a")"; done
  printf '  </array>\n'
  [ -n "$interval" ] && printf '  <key>StartInterval</key><integer>%s</integer>\n' "$interval"
  printf '  <key>RunAtLoad</key><%s/>\n' "$at_load"
  # launchd starts jobs with a bare PATH: no Homebrew bash, no GNU tools, no ~/.local/bin
  printf '  <key>EnvironmentVariables</key>\n  <dict>\n'
  printf '    <key>PATH</key><string>%s</string>\n' "$(agent_sync_xml_escape "$PATH")"
  printf '  </dict>\n'
  printf '  <key>StandardOutPath</key><string>%s</string>\n' "$(agent_sync_xml_escape "$log")"
  printf '  <key>StandardErrorPath</key><string>%s</string>\n' "$(agent_sync_xml_escape "$log")"
  printf '  <key>ProcessType</key><string>Background</string>\n'
  printf '  <key>LowPriorityIO</key><true/>\n'
  printf '</dict>\n</plist>\n'
}

# launchd_unload <domain/label>: bootout returns before launchd has removed the job, and a
# bootstrap of the same label fails until then ("Bootstrap failed: 5"). Wait up to 5 s.
launchd_unload() {
  # a non-zero bootout can still be tearing the job down ("36: Operation now in progress")
  launchctl bootout "$1" 2>/dev/null
  local i
  for i in $(seq 25); do
    launchctl print "$1" >/dev/null 2>&1 || return 0
    sleep 0.2
  done
}

timers_launchd() {
  local action="$1"; shift
  local dir="$HOME/Library/LaunchAgents" domain n label file
  domain="gui/$(id -u)"
  case "$action" in
    enable)
      for n in "$@"; do
        [ "$n" = tailcat-serve ] && { warn "timers: tailcat-serve is Linux only"; return 2; }
      done
      mkdir -p "$dir" "$HOME/Library/Logs/agent-sync"
      for n in "$@"; do
        label="$LAUNCHD_PREFIX.$n"; file="$dir/$label.plist"
        launchd_plist "$n" > "$file.tmp" && mv "$file.tmp" "$file"
        launchd_unload "$domain/$label"
        launchctl bootstrap "$domain" "$file" || { warn "timers: launchctl could not load $file"; return 1; }
      done
      printf 'timers: loaded %s (logs: ~/Library/Logs/agent-sync)\n' "$*"
      ;;
    disable)
      for n in "$@"; do
        label="$LAUNCHD_PREFIX.$n"
        launchctl bootout "$domain/$label" 2>/dev/null
        rm -f "$dir/$label.plist"
      done
      printf 'timers: removed %s\n' "$*"
      ;;
    status)
      for n in "$@"; do
        label="$LAUNCHD_PREFIX.$n"
        if launchctl print "$domain/$label" >/dev/null 2>&1; then echo "loaded  $n"; else echo "off     $n"; fi
      done
      ;;
  esac
}

cmd_timers() {
  local action="${1:-status}"; shift 2>/dev/null
  case "$action" in enable|disable|status) ;; *) warn "timers: use enable, disable or status"; return 2 ;; esac
  local names="$*"
  if [ -z "$names" ]; then
    if [ "$action" = enable ]; then names="$(timers_default)"; else names="$TIMER_NAMES"; fi
    [ "$AGENT_SYNC_OS" = darwin ] && names="${names/tailcat-serve/}"
  fi
  # shellcheck disable=SC2086
  timers_check_names $names || return 2
  # shellcheck disable=SC2086
  if [ "$AGENT_SYNC_OS" = darwin ]; then timers_launchd "$action" $names
  else timers_systemd "$action" $names
  fi
}
