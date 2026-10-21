#!/usr/bin/env bash
# Hard-blocks catastrophic `rm -rf`-style invocations (root, home, wildcards
# covering everything) regardless of permission mode. Narrow, targeted
# deletions (rm -rf node_modules, rm -rf dist, rm -rf .worktrees/foo) are
# left alone — this is a last-resort guard against wiping out a whole tree,
# not a blanket ban on rm -rf.
set -euo pipefail
for _compat in "$(dirname "$(readlink -f "$0")")/../../../bin/lib/compat.sh" "${SYNC_HOME:-$HOME/.agent-sync}/bin/lib/compat.sh"; do [ -f "$_compat" ] && { . "$_compat" || exit 1; break; }; done

input="$(cat)"
command="$(jq -r '.tool_input.command // empty' <<<"$input")"
[ -z "$command" ] && exit 0

# Only look at commands that actually invoke rm with both recursive and force.
if ! grep -qiE '(^|[[:space:];|&]|&&|\|\|)[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*f[a-zA-Z]*|-[a-zA-Z]*f[a-zA-Z]*[rR][a-zA-Z]*|(-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+-[a-zA-Z]*f[a-zA-Z]*)|(-[a-zA-Z]*f[a-zA-Z]*[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*)|--recursive([[:space:]].*)?--force|--force([[:space:]].*)?--recursive)' <<<"$command"; then
  exit 0
fi

# Pull out the non-flag arguments (the targets) from each rm invocation.
targets="$(grep -oiE '(^|[|;&[:space:]])rm[[:space:]]+[^|;&]*' <<<"$command" \
  | tr ';|&' '\n' \
  | sed -E 's/^[[:space:]]*rm[[:space:]]+//' \
  | tr ' ' '\n' \
  | grep -vE '^-' | grep -vE '^$' || true)"

is_dangerous=0
while IFS= read -r t; do
  [ -z "$t" ] && continue
  t="${t#\"}"; t="${t%\"}"
  t="${t#\'}"; t="${t%\'}"
  # /tmp/* is the designated scratch area — never flag it.
  case "$t" in
    /tmp|/tmp/*) continue ;;
  esac
  case "$t" in
    /|'~'|'$HOME'|'${HOME}'|'*'|'/*'|'~/*'|'$HOME/*'|'${HOME}/*'|.|./|./*|..)
      is_dangerous=1
      ;;
    /etc|/etc/*|/usr|/usr/*|/var|/var/*|/opt|/opt/*|/bin|/bin/*|/sbin|/sbin/*|/boot|/boot/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/mnt|/mnt/*|/media|/media/*|/root|/root/*)
      is_dangerous=1
      ;;
  esac
  # Top-level absolute path with 0 or 1 segments (e.g. /home, /home/me) — also dangerous.
  case "$t" in
    /*)
      segs="$(echo "$t" | tr -cd '/' | wc -c)"
      if [ "$segs" -le 2 ]; then
        is_dangerous=1
      fi
      ;;
  esac
done <<<"$targets"

# No targets at all after the flags (bare `rm -rf`) is also suspicious.
if [ -z "$(echo "$targets" | tr -d '[:space:]')" ]; then
  is_dangerous=1
fi

if [ "$is_dangerous" -eq 1 ]; then
  cat <<EOF
{
  "continue": false,
  "stopReason": "Blocked: this rm -rf targets a root/home/top-level or wildcard path ('$command'). If this is really intended, ask the user to run it themselves.",
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Catastrophic rm -rf target detected."
  }
}
EOF
fi

exit 0
