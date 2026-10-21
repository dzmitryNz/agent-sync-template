#!/usr/bin/env bash
# What changed on main since the last port to agent-sync-template.
#
#   template-drift.sh                 commits and diff --stat <marker>..origin/main; exit 1 if drift
#   template-drift.sh --diff [path…]  full diff for the same range (optional path filter)
#   template-drift.sh --mark [sha]    write origin/main (or sha) to template.ported and commit
#
# Marker: template.ported in the repo root — one line, sha of main fully ported to the template.
# Exit: 0 up to date, 1 drift, 2 missing/bad marker or bad args.
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

SYNC_HOME="${SYNC_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
MARKER_FILE="$SYNC_HOME/template.ported"
REF=origin/main

PATHS=(
  bin tests systemd tools.conf sync.conf .gitignore README.md
  store/.claude/AGENTS.md store/.claude/CLAUDE.md store/.claude/settings.json
  store/.claude/hooks store/.claude/skills store/.config/herdr
)
EXCLUDE=(
  store/.claude/skills/synced
  store/.claude/skills/{documentation,fastify,node,nodejs-core,oauth,octocat,skill-optimizer,small-agents,typescript-magician}
  bin/cursor-session-record.sh bin/merge-cli-config.sh
)

g() { git -C "$SYNC_HOME" "$@"; }
die() { printf 'template-drift: %s\n' "$*" >&2; exit 2; }

spec() {
  SPEC=("${@:-${PATHS[@]}}")
  local e; for e in "${EXCLUDE[@]}"; do SPEC+=(":(exclude)$e"); done
}

read_marker() {
  [[ -f "$MARKER_FILE" ]] || die "missing marker $MARKER_FILE (one line: sha of main ported to template; see --mark)"
  MARKER="$(head -n1 "$MARKER_FILE" | tr -d '[:space:]')"
  [[ -n "$MARKER" ]] && g rev-parse -q --verify "$MARKER^{commit}" >/dev/null \
    || die "marker in $MARKER_FILE is not a valid commit: '$MARKER'"
  MARKER="$(g rev-parse "$MARKER^{commit}")"
}

need_ref() { g rev-parse -q --verify "$REF^{commit}" >/dev/null || die "no $REF (git fetch origin)"; }

fetch() { g fetch -q origin 2>/dev/null || printf 'template-drift: git fetch failed, using local refs\n' >&2; }

cmd="${1:-}"
case "$cmd" in
  --mark)
    fetch; need_ref
    target="$(g rev-parse "$REF")"
    if [[ -n "${2:-}" ]]; then
      target="$(g rev-parse -q --verify "$2^{commit}")" || die "unknown commit: $2"
      g merge-base --is-ancestor "$target" "$REF" || die "$2 is not an ancestor of $REF"
    fi
    printf '%s\n' "$target" > "$MARKER_FILE"
    g add template.ported
    g commit -q -m "template: ported up to ${target:0:7}" -- template.ported
    printf 'marker: %s\n' "$target"
    ;;
  --diff)
    shift
    fetch; read_marker; need_ref
    spec "$@"
    g --no-pager diff "$MARKER..$REF" -- "${SPEC[@]}"
    ;;
  "")
    fetch; read_marker; need_ref
    spec
    log="$(g --no-pager log --format='%h %ci %s' "$MARKER..$REF" -- "${SPEC[@]}")"
    if [[ -z "$log" ]]; then
      printf 'template is up to date with main (%s)\n' "$(g rev-parse --short "$MARKER")"
      exit 0
    fi
    printf 'Changes on main since %s:\n%s\n\n' "$(g rev-parse --short "$MARKER")" "$log"
    g --no-pager diff --stat "$MARKER..$REF" -- "${SPEC[@]}"
    exit 1
    ;;
  *) die "unknown argument: $cmd (use: --diff [path…], --mark [sha])" ;;
esac
