#!/usr/bin/env bash
# Cursor beforeSubmitPrompt. geo-guard.sh blocks with exit 2 and a stderr line.
# Cursor only honors {"continue":false,"user_message":"..."}.
set -u

command -v jq >/dev/null 2>&1 || { printf '{"continue":true}\n'; exit 0; }

payload="$(cat 2>/dev/null)"
bin="$(dirname "$(readlink -f "$0")")"
err="$(printf '%s\n' "$payload" | "$bin/geo-guard.sh" 2>&1 >/dev/null)"
rc=$?
# failClosed treats an empty reply as a hook failure, so allow must answer too.
if [ "$rc" -eq 0 ]; then
  printf '{"continue":true}\n'
  exit 0
fi

[ -n "$err" ] || err="[geo-guard] Prompt blocked."
jq -nc --arg m "$err" '{continue:false, user_message:$m}'
exit 0
