#!/usr/bin/env bash
# Telegram message when a herdr agent waits for a reply (status blocked) longer than the threshold.
# Runs from systemd timer herdr-notify.timer once per minute. Tests: tests/herdr-notify.sh
# Token and chat: HERDR_NOTIFY_ENV (default ~/.config/herdr-notify.env, chmod 600, not in git):
#   TELEGRAM_BOT_TOKEN=...  TELEGRAM_CHAT_ID=...   Missing file or values — exit silently.
# Env: HERDR_NOTIFY_BLOCKED_SEC (threshold, default 600);
#      for tests HERDR_AGENTS_FILE (instead of `herdr agent list`) and HERDR_NOTIFY_NOW (epoch).
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

ENV_FILE=${HERDR_NOTIFY_ENV:-$HOME/.config/herdr-notify.env}
TOKEN="" CHAT=""
if [ -r "$ENV_FILE" ]; then
  while IFS='=' read -r k v; do
    case $k in TELEGRAM_BOT_TOKEN) TOKEN=$v ;; TELEGRAM_CHAT_ID) CHAT=$v ;; esac
  done < "$ENV_FILE"
fi
[ -n "$TOKEN" ] && [ -n "$CHAT" ] || exit 0
THRESHOLD=${HERDR_NOTIFY_BLOCKED_SEC:-600}
NOW=${HERDR_NOTIFY_NOW:-$(date +%s)}
STATE="${XDG_RUNTIME_DIR:-/tmp}/herdr-notify.state"   # pane \t status \t since \t notified

if [ -n "${HERDR_AGENTS_FILE:-}" ]; then json=$(cat "$HERDR_AGENTS_FILE") || exit 0
else json=$(herdr agent list 2>/dev/null) || exit 0
fi

declare -A p_status p_since p_sent
if [ -f "$STATE" ]; then
  while IFS=$'\t' read -r pane st since sent; do
    p_status[$pane]=$st; p_since[$pane]=$since; p_sent[$pane]=$sent
  done < "$STATE"
fi

send() { # send <title> <message>; token in curl -K config, not argv
  jq -nc --arg c "$CHAT" --arg t "⏳ $1"$'\n'"$2" '{chat_id:$c, text:$t}' \
    | curl -fsS -m 10 -K <(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TOKEN") \
        -H 'Content-Type: application/json' --data-binary @- >/dev/null 2>&1
}

tmp="$STATE.tmp"; : > "$tmp"
while IFS=$'\t' read -r pane st title cwd; do
  [ -n "$pane" ] || continue
  if [ "${p_status[$pane]:-}" = "$st" ]; then since=${p_since[$pane]}; sent=${p_sent[$pane]}
  else since=$NOW; sent=0
  fi
  if [ "$st" = blocked ] && [ "$sent" = 0 ] && [ $((NOW - since)) -ge "$THRESHOLD" ]; then
    mins=$(( (NOW - since) / 60 ))
    send "Agent waiting for reply: ${title:-$pane}" "$(hostname -s) · $pane · ${cwd##*/} · ${mins} min" && sent=1
  fi
  printf '%s\t%s\t%s\t%s\n' "$pane" "$st" "$since" "$sent" >> "$tmp"
done < <(jq -r '.result.agents[]? | [.pane_id, .agent_status, (.terminal_title_stripped // .title // ""), (.cwd // "")] | @tsv' <<<"$json")
mv "$tmp" "$STATE"
