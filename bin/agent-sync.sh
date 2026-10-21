#!/usr/bin/env bash
# Sync of AI agent configs and memory between machines through git.
#
# What is synced is set in sync.conf: one path per line, relative to
# $HOME; globs and '!' exclusions are supported. sync.conf itself lives in
# the repository, so a line added on one machine arrives on the other.
#
#   agent-sync.sh init [--name N --root R --org O --server S --user-language L]   render {{PROJECT_*}} placeholders (once)
#   agent-sync.sh install [--remote URL] [--adopt]   link config entries; --adopt replaces a local copy that differs
#   agent-sync.sh pull                     fetch from the server
#   agent-sync.sh push                     send to the server
#   agent-sync.sh sync                     pull + push; adopt only after install --adopt
#   agent-sync.sh status                   show what is not pushed
#   agent-sync.sh timers enable|disable|status [name...]   scheduled sync: systemd (Linux, WSL) or launchd (macOS)
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  printf 'agent-sync needs bash 4 or newer (this shell is %s). macOS: brew install bash coreutils gnu-sed findutils. Windows: run it inside WSL2.\n' "${BASH_VERSION:-unknown}" >&2
  exit 1
fi

SYNC_HOME="${SYNC_HOME:-$HOME/.agent-sync}"
STORE="$SYNC_HOME/store"
CONF="$SYNC_HOME/sync.conf"
BRANCH=main

warn() { printf '%s\n' "$*" >&2; }
git_() {
  case "$1" in
    push|ls-remote|fetch) timeout 60 git -C "$SYNC_HOME" "$@" ;;
    *) git -C "$SYNC_HOME" "$@" ;;
  esac
}

default_conf() {
  cat <<'EOF'
# What to sync between machines. A path relative to $HOME, one per line.
# Globs (*) work; a line that starts with '!' excludes a match.
# This file syncs itself, so an edit reaches all machines.

# Claude Code
.claude/CLAUDE.md
.claude/AGENTS.md
.claude/settings.json
.claude/hooks
.claude/skills
.claude/plans
# .claude/settings.local.json stays on this machine (permissions, extra dirs).
# Per-project memory is opt-in. Uncomment one project key, do not sync every project:
# .claude/projects/<project-key>/memory

# Other agents: add your own paths

# Not synced: .claude/.credentials.json, .claude.json (machine-specific),
# caches and session transcripts: keep those in your own backup, not here.
EOF
}

ensure_repo() {
  local remote="${1:-}"
  mkdir -p "$SYNC_HOME"
  if [ ! -d "$SYNC_HOME/.git" ]; then
    git_ init -q -b "$BRANCH" 2>/dev/null || { git_ init -q; git_ checkout -q -b "$BRANCH" 2>/dev/null; }
  fi
  if [ -n "$remote" ]; then
    if git_ remote get-url origin >/dev/null 2>&1;
      then git_ remote set-url origin "$remote"
      else git_ remote add origin "$remote"
    fi
  fi
  # Empty local repository while the server is up: take what is there
  if ! git_ rev-parse HEAD >/dev/null 2>&1 && git_ remote get-url origin >/dev/null 2>&1; then
    if git_ fetch -q origin "$BRANCH" 2>/dev/null; then
      git_ reset -q --hard FETCH_HEAD
    fi
  fi
  [ -f "$CONF" ] || default_conf > "$CONF"
  mkdir -p "$STORE"
  # Per machine. install --adopt clears the pending file; neither file is a commit.
  local exclude
  exclude="$(git_ rev-parse --absolute-git-dir)/info/exclude"
  mkdir -p "$(dirname "$exclude")"
  touch "$exclude"
  grep -qx '.link-adopt-pending' "$exclude" 2>/dev/null || printf '%s\n' '.link-adopt-pending' '.link-adopt' >> "$exclude"
}

# Expands the config entries into a list of paths relative to $HOME.
# Matches are searched in $HOME (what is on this machine) and in $STORE (what came
# from the server); otherwise a new machine would have nothing to link.
expand_items() {
  local -a includes=() excludes=()
  local line
  while IFS= read -r line; do
    line="${line%%#*}"                       # trailing comment
    line="$(printf '%s' "$line" | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')"
    [ -z "$line" ] && continue
    if [ "${line:0:1}" = '!' ]; then excludes+=("${line:1}"); else includes+=("$line"); fi
  done < "$CONF"

  local -a found=()
  local pat m rel
  local oldglob; oldglob="$(shopt -p nullglob)"
  shopt -s nullglob
  for pat in "${includes[@]}"; do
    if [[ "$pat" == *[*?[]* ]]; then
      for m in "$HOME"/$pat;  do found+=("${m#"$HOME"/}"); done
      for m in "$STORE"/$pat; do found+=("${m#"$STORE"/}"); done
    else
      found+=("$pat")
    fi
  done
  eval "$oldglob"

  # dedupe keeping the order + drop the exclusions
  local -A seen=()
  local ex skip
  for rel in "${found[@]}"; do
    [ -n "${seen[$rel]:-}" ] && continue
    seen[$rel]=1
    skip=
    for ex in "${excludes[@]}"; do
      # shellcheck disable=SC2053  — comparing with a glob pattern is intended
      [[ "$rel" == $ex ]] && { skip=1; break; }
    done
    [ -n "$skip" ] || printf '%s\n' "$rel"
  done
}

# Moves an entry into the repository (if it is still only on the machine) and replaces it
# with a symlink. An entry that is neither on the machine nor in the repository is skipped.
link_item() {
  local rel="$1" src="$HOME/$1" dst="$STORE/$1"

  if [ -L "$src" ]; then
    [ "$(readlink "$src")" = "$dst" ] && [ -e "$dst" ] && return 0
    if [ ! -e "$dst" ]; then
      warn "left symlink $rel in place: the repo has no file to link"
      return 0
    fi
    rm -f "$src"
  elif [ -e "$src" ]; then
    if [ ! -e "$dst" ]; then
      mkdir -p "$(dirname "$dst")"
      mv "$src" "$dst"
    elif cmp -s "$src" "$dst" 2>/dev/null; then
      rm -rf "$src"
    elif [ "${LINK_ADOPT:-}" != 1 ]; then
      warn "left $rel in place: it differs from the copy in the repo. Run install --adopt to switch (your file is kept as $rel.local-<time>)."
      return 0
    elif [ -f "$src" ] && [ -f "$dst" ] && [ "$src" -nt "$dst" ] && [ "${LINK_ADOPT_LINKED:-}" = 1 ]; then
      # Already opted in. An app replaced the symlink with a newer file (temp + rename).
      # That edit is the current one. The first install --adopt does not take this branch:
      # a newer local file is kept aside, and the repo copy stays.
      cp -p "$src" "$dst"
      rm -f "$src"
    else
      # both the machine and the repository have their own version: do not lose the local one
      local keep="$src.local-$(date +%Y%m%d%H%M%S)"
      mv "$src" "$keep"
      warn "conflict: local version of $rel saved as ${keep##*/}"
    fi
  fi

  [ -e "$dst" ] || return 0
  mkdir -p "$(dirname "$src")"
  ln -s "$dst" "$src"
}

link_all() {
  local rel
  while IFS= read -r rel; do
    [ -n "$rel" ] && link_item "$rel"
  done < <(expand_items)
}

# .link-adopt-pending means "do not replace a differing local file".
# install without --adopt creates it. The first pull/push/sync creates it too
# when the user has never opted in, so the timer cannot adopt on its own.
# install --adopt is the only command that removes it. It also writes .link-adopt,
# and later pull/push/sync/timer runs adopt.
ADOPT_PENDING="$SYNC_HOME/.link-adopt-pending"
ADOPT_ON="$SYNC_HOME/.link-adopt"

set_adopt_mode() {
  if [ -f "$ADOPT_PENDING" ]; then
    LINK_ADOPT=
    LINK_ADOPT_LINKED=
    return 0
  fi
  if [ -f "$ADOPT_ON" ]; then
    LINK_ADOPT=1
    LINK_ADOPT_LINKED=1
    return 0
  fi
  touch "$ADOPT_PENDING"
  LINK_ADOPT=
  LINK_ADOPT_LINKED=
}

# Commands that the README promises as a bare name. Left: file in bin/, right:
# names in PATH: without .sh (canonical) and with .sh, because people type both.
# check.sh is exposed only with a prefix: "check" in PATH is too generic a name.
CLI_COMMANDS='
agent-sessions.sh :: agent-sessions agent-sessions.sh
agent-sync.sh     :: agent-sync agent-sync.sh
register-me.sh    :: register-me register-me.sh
tools-check.sh    :: tools-check tools-check.sh
history-sync.sh   :: history-sync history-sync.sh
check.sh          :: agent-sync-check
wt-install.sh     :: wt-install
wt-new.sh         :: wt-new
herdr-spaces.sh   :: herdr-spaces herdr-spaces.sh
herdr-pane-reply.sh :: herdr-pane-reply
pr-diff.sh        :: pr-diff
project-develop.sh :: project-develop
'

link_commands() {
  local bin_src bin_dir file names name target
  # Through a symlink from ~/.local/bin, "next to itself" is no longer the repository:
  # without resolving, install would link the commands to themselves.
  bin_src="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  bin_dir="${BIN_DIR:-$HOME/.local/bin}"
  mkdir -p "$bin_dir" || return 0

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    file="${line%%::*}"; file="${file// /}"
    names="${line#*::}"
    [ -f "$bin_src/$file" ] || continue

    for name in $names; do
      target="$bin_dir/$name"
      if [ -e "$target" ] && [ ! -L "$target" ]; then
        warn "$bin_dir already has its own $name — symlink not created"
        continue
      fi
      ln -sfn "$bin_src/$file" "$target"
    done
  done <<< "$CLI_COMMANDS"

  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *)
      case "${SHELL##*/}" in
        zsh) rc=~/.zshrc ;;
        bash) rc=~/.bashrc ;;
        *) rc="your shell rc file" ;;
      esac
      warn "$bin_dir is not in PATH — the commands will not be found, add it to $rc" ;;
  esac
}

# Without arguments it commits the whole tree (push/sync: a tool edit must
# travel together with the configs). With arguments, only those: install adopts
# configs and must not carry someone's uncommitted work into "sync <machine>".
commit_local() {
  if [ $# -gt 0 ]; then git_ add -- "$@" 2>/dev/null; else git_ add -A 2>/dev/null; fi
  git_ diff --cached --quiet 2>/dev/null && return 0
  local hook hits
  hook="$(dirname "$(readlink -f "$0")")/../store/.claude/hooks/prevent-secret-commit.sh"
  if ! hits="$("$hook" --cached "$SYNC_HOME" 2>/dev/null)"; then
    warn "refused commit: ${hits:-secret scan failed}"
    agent_sync_notify "agent-sync refused a commit" "${hits:-secret scan failed}"
    git_ reset -q
    return 2
  fi
  git_ -c user.name="${GIT_AUTHOR_NAME:-agent-sync}" \
       -c user.email="${GIT_AUTHOR_EMAIL:-agent-sync@localhost}" \
       commit -qm "sync $(hostname -s) $(date '+%Y-%m-%d %H:%M')"
}

# A merge conflict, a broken repository or a server refusal can only be fixed by hand,
# and the script is silent in journalctl: this is how sync stood still for two days (twice). After
# several failures in a row we call the desktop notification, if the machine
# has one at all. A server that is switched off does not count: it is not a breakage.
FAILS="${XDG_CACHE_HOME:-$HOME/.cache}/agent-sync/sync-fails"
FAILS_BEFORE_NOTIFY=3

note_sync_failure() {
  local n=0
  [ -f "$FAILS" ] && n="$(cat "$FAILS" 2>/dev/null)"
  n=$((n + 1))
  mkdir -p "$(dirname "$FAILS")"
  printf '%s\n' "$n" > "$FAILS"
  [ "$n" -ge "$FAILS_BEFORE_NOTIFY" ] || return 0
  local logs="journalctl --user -u agent-sync"
  [ "$AGENT_SYNC_OS" = darwin ] && logs="~/Library/Logs/agent-sync"
  agent_sync_notify "agent-sync is stuck" "$n failures in a row: $1 ($SYNC_HOME, $logs)"
}

# /model on any machine rewrites "model" in settings.json, so neighbor commits
# conflict on that one line. Git merges the rest and we keep the local "model"
# (in a rebase that is :3, the commit being replayed).
resolve_settings_model_conflict() {
  local path="store/.claude/settings.json" base ours theirs line out rc
  base="$(mktemp)"; ours="$(mktemp)"; theirs="$(mktemp)"; out="$(mktemp)"
  git_ show :1:"$path" > "$base" 2>/dev/null || { rm -f "$base" "$ours" "$theirs" "$out"; return 1; }
  git_ show :2:"$path" > "$ours"
  git_ show :3:"$path" > "$theirs"
  line="$(grep -m1 '^ *"model":' "$theirs" || true)"
  if [ -z "$line" ]; then rm -f "$base" "$ours" "$theirs" "$out"; return 1; fi
  sed -i 's/^\( *"model":\).*/\1 "__MODEL__"/' "$base" "$ours" "$theirs"
  git merge-file -p "$ours" "$base" "$theirs" > "$out"; rc=$?
  if [ "$rc" -ne 0 ]; then rm -f "$base" "$ours" "$theirs" "$out"; return 1; fi
  awk -v l="$line" '/^ *"model": "__MODEL__"/ { print l; next } { print }' "$out" > "$SYNC_HOME/$path"
  rm -f "$base" "$ours" "$theirs" "$out"
  git_ add "$path"
}

# Resolves the conflict only when settings.json is the only unmerged file.
try_resolve_settings_rebase() {
  local unmerged
  unmerged="$(git_ diff --name-only --diff-filter=U 2>/dev/null || true)"
  [ "$unmerged" = "store/.claude/settings.json" ] || return 1
  resolve_settings_model_conflict
}

rebase_in_progress() {
  [ -d "$SYNC_HOME/.git/rebase-merge" ] || [ -d "$SYNC_HOME/.git/rebase-apply" ]
}

finish_rebase_or_abort() {
  if ! git_ rebase -q --autostash FETCH_HEAD 2>/dev/null; then
    while rebase_in_progress; do
      if git_ diff --name-only --diff-filter=U 2>/dev/null | grep -q .; then
        try_resolve_settings_rebase || break
      elif GIT_EDITOR=true git_ rebase --continue 2>/dev/null; then
        :
      else
        break
      fi
    done
    if rebase_in_progress; then
      git_ rebase --abort 2>/dev/null
      warn "could not merge the changes automatically: resolve the conflict in $SYNC_HOME"
      note_sync_failure "resolve the merge conflict"
      return 1
    fi
  fi
  return 0
}

# Merges with the server. An unreachable server is not an error: the local commit is already
# made, we will push next time (otherwise the timer would spam when the NAS is off).
fetch_rebase() {
  git_ remote get-url origin >/dev/null 2>&1 || return 0
  if ! git_ ls-remote -q origin >/dev/null 2>&1; then
    warn "server unreachable, changes saved locally"
    return 1
  fi
  # The branch is not on the server yet (first machine): nothing to merge, push as is
  if ! git_ fetch -q origin "$BRANCH" 2>/dev/null; then
    # The branch is on the server but fetch failed: this is a breakage (broken repository,
    # server), not a first machine
    git_ ls-remote --exit-code -q origin "refs/heads/$BRANCH" >/dev/null 2>&1 || return 0
    warn "fetch from the server failed"
    note_sync_failure "fetch from the server fails, check the repository"
    return 1
  fi
  git_ rev-parse HEAD >/dev/null 2>&1 || { git_ reset -q --hard FETCH_HEAD; return 0; }
  finish_rebase_or_abort || return 1
  return 0
}

# The failure counter is reset only by a successful push: a successful fetch with
# a failing push must not zero it.
do_push() {
  commit_local
  local rc=$?
  # 2: the secret scan refused this commit. Do not push it. Fetch still runs:
  # a refused commit must not block updates from the other machine.
  if [ "$rc" -eq 2 ]; then
    fetch_rebase || return 0
    return 0
  fi
  fetch_rebase || return 0
  link_all
  git_ remote get-url origin >/dev/null 2>&1 || return 0
  if git_ push -q origin "HEAD:$BRANCH" 2>/dev/null; then
    rm -f "$FAILS"
  else
    warn "could not push to the server, will try next time"
    note_sync_failure "the server rejects the push"
  fi
  return 0
}

# --- init: render {{PROJECT_*}} placeholders under store/ -----------------------
# Values come from flags > environment > agent-sync.env > prompt (tty only).
# Text files are rewritten in place, paths with {{PROJECT_NAME}}/{{PROJECT_KEY}} are renamed.
# Unknown {{...}} are left alone; CLICKUP_* only produce a warning (fill them by hand).
KNOWN_PLACEHOLDERS='\{\{(PROJECT_[A-Z_]+|SYNC_SERVER|USER_LANGUAGE)\}\}'
ENV_FILE="$SYNC_HOME/agent-sync.env"

store_has_placeholders() {
  [ -d "$STORE" ] || return 1
  grep -rIlq -E "$KNOWN_PLACEHOLDERS" "$STORE" 2>/dev/null && return 0
  find "$STORE" -name '*{{PROJECT_*' 2>/dev/null | grep -q .
}

# Value of VAR in agent-sync.env; empty when absent or still equal to the shipped example value
env_file_value() {
  local v ex
  [ -f "$ENV_FILE" ] || return 0
  v="$( set +u; . "$ENV_FILE" >/dev/null 2>&1; eval "printf '%s' \"\${$1-}\"" )"
  ex="$( set +u; . "$SYNC_HOME/agent-sync.env.example" >/dev/null 2>&1; eval "printf '%s' \"\${$1-}\"" )"
  [ "$v" = "$ex" ] && return 0
  printf '%s' "$v"
}

env_file_has() { [ -f "$ENV_FILE" ] && grep -q "^$1=" "$ENV_FILE"; }

sed_escape() { printf '%s' "$1" | sed 's/[\\&|]/\\&/g'; }

# set_env_line <VAR> <value>: keeps the trailing comment of the example line
set_env_line() {
  local var="$1" raw="$2" esc tmp
  esc="$(printf '%s' "$raw" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  if grep -q "^$var=" "$ENV_FILE"; then
    tmp="$(mktemp)"
    awk -v var="$var" -v val="$esc" '
      index($0, var "=") == 1 {
        comment = ""
        n = index($0, "#")
        if (n > 0) comment = "  " substr($0, n)
        print var "=\"" val "\"" comment
        next
      }
      { print }
    ' "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
  else
    printf '%s="%s"\n' "$var" "$esc" >> "$ENV_FILE"
  fi
}

# render_text <file>: substitute every known placeholder; R_* hold sed-escaped values
render_text() {
  sed -i \
    -e "s|{{PROJECT_NAME}}|$R_NAME|g" \
    -e "s|{{PROJECT_ROOT}}|$R_ROOT|g" \
    -e "s|{{PROJECT_GIT_ORG}}|$R_ORG|g" \
    -e "s|{{PROJECT_CREDS_DIR}}|$R_CREDS|g" \
    -e "s|{{PROJECT_BASE_BRANCH}}|$R_BRANCH|g" \
    -e "s|{{PROJECT_KEY}}|$R_KEY|g" \
    -e "s|{{USER_LANGUAGE}}|$R_LANG|g" \
    -e "s|{{SYNC_SERVER}}|$R_SERVER|g" "$1"
}

cmd_init() {
  local name root org server branch creds lang
  # flags win over the environment, the environment over the file
  name="${PROJECT_NAME-}"; root="${PROJECT_ROOT-}"; org="${PROJECT_GIT_ORG-}"
  server="${SYNC_SERVER-}"; branch="${PROJECT_BASE_BRANCH-}"; creds="${PROJECT_CREDS_DIR-}"; lang="${USER_LANGUAGE-}"
  local server_set="${SYNC_SERVER+x}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)        name="${2?--name needs a value}"; shift 2 ;;
      --root)        root="${2?--root needs a value}"; shift 2 ;;
      --org)         org="${2?--org needs a value}"; shift 2 ;;
      --server)      server="${2?--server needs a value}"; server_set=x; shift 2 ;;
      --base-branch) branch="${2?--base-branch needs a value}"; shift 2 ;;
      --creds)       creds="${2?--creds needs a value}"; shift 2 ;;
      --user-language) lang="${2?--user-language needs a value}"; shift 2 ;;
      *) warn "init: unknown option: $1"; return 2 ;;
    esac
  done

  [ -n "$name" ]   || name="$(env_file_value PROJECT_NAME)"
  [ -n "$root" ]   || root="$(env_file_value PROJECT_ROOT)"
  [ -n "$org" ]    || org="$(env_file_value PROJECT_GIT_ORG)"
  [ -n "$branch" ] || branch="$(env_file_value PROJECT_BASE_BRANCH)"
  [ -n "$creds" ]  || creds="$(env_file_value PROJECT_CREDS_DIR)"
  [ -n "$lang" ]   || lang="$(env_file_value USER_LANGUAGE)"
  [ -n "$server_set" ] || server="$(env_file_value SYNC_SERVER)"

  if [ -t 0 ]; then
    [ -n "$name" ] || { printf 'Project name (short slug, e.g. acme): '; read -r name; }
    [ -n "$root" ] || { printf 'Project root (absolute path with your checkouts): '; read -r root; }
    [ -n "$org" ]  || { printf 'GitHub org [%s]: ' "$name"; read -r org; }
    [ -n "$lang" ] || { printf 'Your chat language for long answers (e.g. Polish): '; read -r lang; }
    [ -n "$server_set" ] || [ -n "$server" ] || { printf 'Sync server ssh alias (empty = none): '; read -r server; }
  fi

  [ -n "$name" ] || { warn "init: PROJECT_NAME is required (use --name)"; return 1; }
  [ -n "$root" ] || { warn "init: PROJECT_ROOT is required (use --root)"; return 1; }
  [ -n "$lang" ] || { warn "init: USER_LANGUAGE is required (use --user-language, e.g. Polish)"; return 1; }
  [[ "$lang" =~ ^[A-Za-z][A-Za-z-]*$ ]] || { warn "init: --user-language must be one word, e.g. Polish"; return 1; }
  root="${root%/}"
  [[ "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { warn "init: --name must match [a-z0-9][a-z0-9_-]*"; return 1; }
  [[ "$root" == /* ]] || { warn "init: --root must be an absolute path"; return 1; }
  [ -n "$org" ]    || org="$name"
  if [ -z "$branch" ]; then
    # The shell is usually inside ~/.agent-sync. The project's default branch
    # lives in --root, and only when that path is itself a git checkout.
    if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      branch="$(git -C "$root" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)"
      branch="${branch#refs/remotes/origin/}"
    fi
  fi
  [ -n "$branch" ] || branch=main
  [ -n "$creds" ]  || creds="$root-creds"
  local v
  for v in "$name" "$root" "$org" "$branch" "$creds" "$server"; do
    case "$v" in *'|'*|*$'\n'*) warn "init: values must not contain '|' or a newline"; return 1 ;; esac
  done

  # same derivation as bin/lib/project-env.sh
  local key; key="$(printf '%s' "$root" | tr '/.' '--')"
  R_NAME="$(sed_escape "$name")"; R_ROOT="$(sed_escape "$root")"; R_ORG="$(sed_escape "$org")"
  R_CREDS="$(sed_escape "$creds")"; R_BRANCH="$(sed_escape "$branch")"; R_KEY="$(sed_escape "$key")"
  R_SERVER="$(sed_escape "${server:-none}")"; R_LANG="$lang"

  # 1. agent-sync.env
  [ -f "$ENV_FILE" ] || cp "$SYNC_HOME/agent-sync.env.example" "$ENV_FILE" || return 1
  set_env_line PROJECT_NAME "$name"
  set_env_line PROJECT_ROOT "$root"
  set_env_line PROJECT_GIT_ORG "$org"
  set_env_line PROJECT_BASE_BRANCH "$branch"
  set_env_line SYNC_SERVER "$server"
  set_env_line USER_LANGUAGE "$lang"
  if [ "$creds" != "$root-creds" ] || env_file_has PROJECT_CREDS_DIR; then
    set_env_line PROJECT_CREDS_DIR "$creds"
  fi

  # 2. text under store/ (-I skips binaries)
  local f
  while IFS= read -r f; do render_text "$f"; done \
    < <(grep -rIl -E "$KNOWN_PLACEHOLDERS" "$STORE" 2>/dev/null)

  # 3. paths, deepest first so a renamed parent does not hide its children
  local p new
  while IFS= read -r p; do
    new="$(dirname "$p")/$(basename "$p" | sed -e "s|{{PROJECT_NAME}}|$name|g" -e "s|{{PROJECT_KEY}}|$key|g")"
    [ "$new" = "$p" ] && continue
    if [ -e "$new" ]; then cp -a "$p/." "$new/" && rm -rf "$p"; else mv "$p" "$new"; fi
  done < <(find "$STORE" -depth -name '*{{PROJECT_*' 2>/dev/null)

  # 4. CLAUDE.md for the project root, only if the folder exists and has none yet
  local tpl="$SYNC_HOME/templates/project-root-CLAUDE.md"
  if [ -d "$root" ] && [ ! -e "$root/CLAUDE.md" ] && [ -f "$tpl" ]; then
    cp "$tpl" "$root/CLAUDE.md" && render_text "$root/CLAUDE.md"
  fi

  if store_has_placeholders; then
    warn "init: known placeholders are still left under $STORE:"
    grep -rIl -E "$KNOWN_PLACEHOLDERS" "$STORE" 2>/dev/null >&2
    return 1
  fi
  if grep -rIlq 'CLICKUP_' "$STORE" 2>/dev/null; then
    warn "init: CLICKUP_* placeholders are left on purpose: fill them by hand or delete the skill that uses them"
  fi
  mem_line="$(grep -n 'projects/<project-key>/memory' "$SYNC_HOME/sync.conf" | head -1 | cut -d: -f1)"
  printf 'init: project memory is opt-in: uncomment line %s in sync.conf\n' "${mem_line:-?}"
  printf 'init: done for project "%s" (root %s)\n' "$name" "$root"
  printf 'Next: review `git -C %s status`, commit, check that origin is your PRIVATE repository (git remote -v), then run: agent-sync.sh install\n' "$SYNC_HOME"
}

case "${1:-sync}" in
  init) shift; cmd_init "$@"; exit $? ;;
  timers)
    shift
    . "$(dirname "$(readlink -f "$0")")/lib/project-env.sh" || exit 1
    . "$(dirname "$(readlink -f "$0")")/lib/timers.sh"
    cmd_timers "$@"; exit $? ;;
  install)
    shift
    remote=
    adopt_now=
    while [ $# -gt 0 ]; do
      case "$1" in
        --remote) remote="${2:?--remote needs a URL}"; shift 2 ;;
        --adopt)  adopt_now=1; shift ;;
        *) warn "install: unknown argument: $1"; exit 2 ;;
      esac
    done
    if store_has_placeholders; then cmd_init || exit 1; fi
    ensure_repo "$remote"
    if [ -n "$adopt_now" ]; then
      # LINK_ADOPT_LINKED is set only when adopt was already on. The first
      # --adopt must not copy a newer local file over the repo copy.
      if [ -f "$ADOPT_ON" ]; then LINK_ADOPT_LINKED=1; else LINK_ADOPT_LINKED=; fi
      rm -f "$ADOPT_PENDING"
      touch "$ADOPT_ON"
      LINK_ADOPT=1
    elif [ -f "$ADOPT_ON" ]; then
      LINK_ADOPT=1
      LINK_ADOPT_LINKED=1
    else
      touch "$ADOPT_PENDING"
      LINK_ADOPT=
      LINK_ADOPT_LINKED=
    fi
    link_all
    link_commands
    commit_local store sync.conf
    ;;
  pull)   ensure_repo; set_adopt_mode; fetch_rebase; link_all; link_commands ;;
  push)   ensure_repo; set_adopt_mode; link_all; link_commands; do_push ;;
  sync)   ensure_repo; set_adopt_mode; link_all; link_commands; do_push ;;
  status)
    ensure_repo
    printf 'repository: %s\n' "$SYNC_HOME"
    printf 'server:     %s\n' "$(git_ remote get-url origin 2>/dev/null || echo 'not set')"
    printf 'commits not pushed: %s\n' \
      "$(git_ rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo '?')"
    git_ status --short
    ;;
  *) warn "unknown command: $1"; exit 2 ;;
esac
exit 0
