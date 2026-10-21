#!/usr/bin/env bash
# Checks that the machine has the tools that the rules from CLAUDE.md rely on
# (code search, PR work, sync).
#
#   tools-check.sh            show what is missing and how to install it
#   tools-check.sh --install  install what can be installed without sudo
#
# The list is in tools.conf next to this script: "command :: install :: why".
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
if [ -n "${TOOLS_CONF:-}" ]; then CONF="$TOOLS_CONF"
elif [ "$AGENT_SYNC_OS" = darwin ]; then CONF="$ROOT/tools.macos.conf"
else CONF="$ROOT/tools.conf"
fi
DO_INSTALL=''
[ "${1:-}" = --install ] && DO_INSTALL=1

[ -f "$CONF" ] || { echo "no manifest: $CONF" >&2; exit 0; }

missing=0
need_manual=()

# compat.sh already re-ran this script with Homebrew bash if there is one
if [ "${AGENT_SYNC_BASH_MAJOR:-${BASH_VERSINFO[0]}}" -lt 4 ]; then
  missing=1
  printf '  MISSING  %-12s %s\n' 'bash>=4' 'the scripts use bash 4 (macOS ships 3.2)'
  printf '         %s\n' 'brew install bash'
fi

# A line is runnable when the install column starts with a command, not a note
# ("see herdr.dev …"). nvm is a shell function, so it runs in a login shell.
runnable_install() {
  local first="${1%% *}"
  case "$first" in
    ''|see|http:*|https:*) return 1 ;;
  esac
  return 0
}

# The separator is "::", not "|": install commands are full of pipes themselves
# (curl ... | bash, jq filters) and would break the parsing.
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  cmd="$(printf '%s' "$line" | awk -F' *:: *' '{print $1}' | tr -d '[:space:]')"
  how="$(printf '%s' "$line" | awk -F' *:: *' '{print $2}')"
  why="$(printf '%s' "$line" | awk -F' *:: *' '{print $3}')"
  case "$cmd" in ''|'#'*) continue ;; esac
  optional=0
  case "$why" in OPTIONAL*|optional*) optional=1 ;; esac

  if command -v "$cmd" >/dev/null 2>&1; then
    printf '  ok       %-12s %s\n' "$cmd" "$why"
    continue
  fi

  if [ "$optional" = 1 ]; then
    printf '  optional %-12s %s\n' "$cmd" "$why"
    printf '         %s\n' "$how"
  else
    missing=$((missing+1))
    printf '  MISSING  %-12s %s\n' "$cmd" "$why"
    printf '         %s\n' "$how"
  fi

  # apt needs a password, and a non-interactive run has nowhere to get it
  case "$how" in
    sudo*|apt*|*apt\ install*)
      [ "$optional" = 1 ] || need_manual+=("$cmd")
      continue ;;
  esac
  if [ -n "$DO_INSTALL" ]; then
    if ! runnable_install "$how"; then
      printf '         not a command, install it by hand\n'
      continue
    fi
    printf '         installing...\n'
    # </dev/null: an installer such as `curl | bash` must not read the rest of tools.conf
    # nvm is a function from the user's shell, not a binary on PATH
    if [ "${how%% *}" = nvm ]; then
      ran=("${TOOLS_INSTALL_SHELL:-bash}" -lc "$how")
    else
      ran=(sh -c "$how")
    fi
    if "${ran[@]}" >/dev/null 2>&1 </dev/null; then
      printf '         done\n'
      [ "$optional" = 1 ] || missing=$((missing-1))
    elif [ "$optional" = 1 ]; then
      printf '         optional, left missing\n'
    else
      printf '         failed, install it manually\n'
    fi
  fi
done < "$CONF"

echo
if [ "$missing" -eq 0 ]; then
  echo "all present"
  exit 0
fi
echo "missing: $missing"
[ ${#need_manual[@]} -gt 0 ] && \
  echo "needs sudo, install manually: ${need_manual[*]}"
[ -z "$DO_INSTALL" ] && echo "install the rest: $0 --install"
exit 1
