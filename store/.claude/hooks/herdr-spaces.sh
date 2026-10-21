#!/usr/bin/env bash
# herdr-spaces.sh — hosts, spaces (label + pane); send by label with one command.
#
#   herdr-spaces                          # all known hosts, spaces table
#   herdr-spaces list [host ...]          # same, optional host filter
#   herdr-spaces me                       # one line: host label pane agent_status (current space)
#   herdr-spaces send <host> <label> [msg]  # msg from the argument or stdin (no argument)
#   herdr-spaces send <host> <label> --file path   # long text / quotes — more reliable
#       local host: herdr-pane-send; remote host: herdr-agent-send.sh (ssh + tailcat)
#       if the text has no From: line, From: <hostname>:$HERDR_PANE_ID is added
#       in zsh/bash do not wrap long text in "..." if it contains the " character — use --file or a heredoc
#
# Columns: host  status  label  pane  agent
set -u
for _compat in "$(dirname "$(readlink -f "$0")")/../../../bin/lib/compat.sh" "${SYNC_HOME:-$HOME/.agent-sync}/bin/lib/compat.sh"; do [ -f "$_compat" ] && { . "$_compat" || exit 1; break; }; done

HOOKS=${HERDR_HOOKS:-$HOME/.claude/hooks}
P='[ -d /run/user/$(id -u) ] && export XDG_RUNTIME_DIR=/run/user/$(id -u); PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH; herdr'
me=$(hostname)

usage() {
  sed -n '2,11p' "$0" | tr -d '#'
  exit "${1:-0}"
}

known_hosts() {
  {
    printf '%s\n' "$me"
    for d in "$HOME"/.agent-sync/sessions/*/; do
      [ -d "$d" ] || continue
      basename "$d"
    done
  } | sort -u
}

remote_user() {
  local host=$1
  jq -r '.home' "$HOME/.agent-sync/sessions/$host"/*.json 2>/dev/null |
    sort -u | head -1 | xargs -r basename
}

# run HOST REMOTE_CMD — stdout of the command; ssh exit code
remote_run() {
  local host=$1 cmd=$2
  local user out rc addr tc
  user=$(remote_user "$host")
  user=${user:-$USER}
  out=$(timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=5 "$user@$host" "$cmd" 2>&1)
  rc=$?
  if [ $rc -ne 255 ] && [ $rc -ne 124 ] && ! grep -q 'login.tailscale.com' <<<"$out"; then
    printf '%s' "$out"
    return $rc
  fi
  addr=$(sed -n "s/^$host=//p" "$HOME/.config/herdr-hosts.conf" 2>/dev/null | head -1)
  tc="$HOME/.local/bin/tailcat"
  if [ -z "$addr" ] || [ ! -x "$tc" ]; then
    printf '%s' "$out"
    return $rc
  fi
  timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$HOME/.config/tailcat/known_hosts" \
    -o ProxyCommand="$tc $addr 22" \
    "$user@$host-tc" "$cmd" 2>&1
}

herdr_json() {
  local host=$1
  shift
  if [ "$host" = "$me" ]; then
    [ "$AGENT_SYNC_OS" = darwin ] || export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
    herdr "$@" 2>&1
  else
    remote_run "$host" "$P $(printf '%q ' "$@")"
  fi
}

print_table_header() {
  printf 'host\tstatus\tlabel\tpane\tagent\n'
}

print_spaces() {
  local host=$1 ws panes err
  ws=$(herdr_json "$host" workspace list)
  if ! jq -e '.result.workspaces' <<<"$ws" >/dev/null 2>&1; then
    err=$(head -c 120 <<<"$ws" | tr '\n' ' ')
    if grep -q 'login.tailscale.com' <<<"$ws"; then
      printf '%s\tssh-auth\t-\t-\t%s\n' "$host" "$(grep -o 'https://[^ ]*' <<<"$ws" | head -1)"
    else
      printf '%s\tunreachable\t-\t-\t%s\n' "$host" "$err"
    fi
    return 1
  fi
  panes=$(herdr_json "$host" pane list)
  if ! jq -e '.result.panes' <<<"$panes" >/dev/null 2>&1; then
    printf '%s\tno-panes\t-\t-\t-\n' "$host"
    return 1
  fi
  while IFS=$'\t' read -r label status wsid; do
    local row pane agent
    pane=$(jq -r --arg w "$wsid" '
      .result.panes[] | select(.workspace_id == $w) | .pane_id' <<<"$panes" | head -1)
    agent=$(jq -r --arg w "$wsid" '
      .result.panes[] | select(.workspace_id == $w) | .agent // "-"' <<<"$panes" | head -1)
    [ -z "$pane" ] || [ "$pane" = "null" ] && pane="-"
    [ -z "$agent" ] || [ "$agent" = "null" ] && agent="-"
    printf '%s\t%s\t%s\t%s\t%s\n' "$host" "$status" "$label" "$pane" "$agent"
  done < <(jq -r '.result.workspaces[] | [.label, .agent_status, .workspace_id] | @tsv' <<<"$ws")
}

cmd_list() {
  local hosts=() h
  if [ $# -gt 0 ]; then hosts=("$@"); else
    while IFS= read -r h; do hosts+=("$h"); done < <(known_hosts)
  fi
  print_table_header
  for h in "${hosts[@]}"; do
    print_spaces "$h" || true
  done
}

cmd_me() {
  if [ -z "${HERDR_ENV:-}" ]; then
    printf 'not in herdr\n'
    return 0
  fi
  local wsid="${HERDR_WORKSPACE_ID:-}"
  local pane="${HERDR_PANE_ID:-}"
  if [ -z "$wsid" ]; then
    printf 'not in herdr\n'
    return 0
  fi
  local ws label status
  ws=$(herdr_json "$me" workspace get "$wsid")
  label=$(jq -r '.result.workspace.label // empty' <<<"$ws" 2>/dev/null)
  status=$(jq -r '.result.workspace.agent_status // empty' <<<"$ws" 2>/dev/null)
  if [ -z "$label" ]; then
    # fallback: list and pick by id
    ws=$(herdr_json "$me" workspace list)
    label=$(jq -r --arg w "$wsid" '
      .result.workspaces[]? | select(.workspace_id == $w) | .label' <<<"$ws" 2>/dev/null | head -1)
    status=$(jq -r --arg w "$wsid" '
      .result.workspaces[]? | select(.workspace_id == $w) | .agent_status' <<<"$ws" 2>/dev/null | head -1)
  fi
  [ -z "$pane" ] && pane="-"
  [ -z "$label" ] && label="-"
  [ -z "$status" ] && status="-"
  printf '%s\t%s\t%s\t%s\n' "$me" "$label" "$pane" "$status"
}

resolve_local_pane() {
  local label=$1 ws panes wsid pane st
  ws=$(herdr workspace list)
  wsid=$(jq -r --arg l "$label" '
    .result.workspaces[] |
    select(.label == $l or (.label | startswith($l + "-"))) |
    .workspace_id' <<<"$ws" | head -1)
  if [ -z "$wsid" ] || [ "$wsid" = "null" ]; then
    printf 'no-pane\tno space %s. Available: %s\n' "$label" \
      "$(jq -r '.result.workspaces[].label' <<<"$ws" | tr '\n' ' ')" >&2
    return 5
  fi
  st=$(jq -r --arg w "$wsid" '.result.workspaces[] | select(.workspace_id == $w) | .agent_status' <<<"$ws")
  if [ "$st" = "working" ]; then
    printf 'busy\t%s working\n' "$label" >&2
    return 6
  fi
  panes=$(herdr pane list --workspace "$wsid")
  pane=$(jq -r '.result.panes[0].pane_id' <<<"$panes")
  [ -z "$pane" ] || [ "$pane" = "null" ] && { printf 'no-pane\tno pane in %s\n' "$wsid" >&2; return 5; }
  printf '%s' "$pane"
}

prepend_from() {
  local msg=$1
  if grep -q '^From:' <<<"$msg" || grep -q $'\nFrom:' <<<"$msg"; then
    printf '%s' "$msg"
    return
  fi
  local from="${HERDR_FROM:-}"
  if [ -z "$from" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    from="$me:$HERDR_PANE_ID"
  fi
  if [ -n "$from" ]; then
    printf 'From: %s\n\n%s' "$from" "$msg"
  else
    printf '%s' "$msg"
  fi
}

cmd_send() {
  local host=$1 label=$2
  shift 2
  local msg=
  if [ "${1:-}" = "--file" ] || [ "${1:-}" = "-f" ]; then
    [ -n "${2:-}" ] || { printf 'send-fail\t--file needs a path\n' >&2; exit 1; }
    msg=$(cat "$2") || exit 1
  else
    msg=${1-}
    [ $# -eq 0 ] && msg=$(cat)
  fi
  [ -z "$msg" ] && { printf 'send-fail\tempty message\n' >&2; exit 1; }
  msg=$(prepend_from "$msg")

  if [ "$host" = "$me" ]; then
    local pane
    pane=$(resolve_local_pane "$label") || exit $?
    "$HOOKS/herdr-pane-send.sh" "$pane" "$msg"
    exit $?
  fi
  exec "$HOOKS/herdr-agent-send.sh" "$host" --label "$label" "$msg"
}

case "${1:-list}" in
  -h|--help|help) usage 0 ;;
  list) shift; cmd_list "$@" ;;
  me) cmd_me ;;
  send)
    shift
    [ $# -ge 2 ] || usage 1
    cmd_send "$@"
    ;;
  hosts)
    known_hosts
    ;;
  *)
    cmd_list "$@"
    ;;
esac
