#!/usr/bin/env bash
# Project variables for agent-sync scripts and hooks. Source it, do not run it.
#
# Order: environment > ${SYNC_HOME:-$HOME/.agent-sync}/agent-sync.env > defaults.
# A missing agent-sync.env is not an error. Exports the variables and PROJECT_KEY
# (Claude's project dir key: PROJECT_ROOT with "/" and "." replaced by "-").

# shellcheck source=compat.sh
. "$(dirname "${BASH_SOURCE[0]}")/compat.sh" || return 1

_pe_vars="PROJECT_NAME PROJECT_ROOT PROJECT_GIT_ORG PROJECT_CREDS_DIR PROJECT_BASE_BRANCH SYNC_SERVER HISTORY_REMOTE STAND_DB_HOST"
_pe_file="${SYNC_HOME:-$HOME/.agent-sync}/agent-sync.env"

if [ -f "$_pe_file" ]; then
  for _pe_v in $_pe_vars; do eval "_pe_pre_$_pe_v=\${$_pe_v-__unset__}"; done
  # shellcheck disable=SC1090
  . "$_pe_file"
  for _pe_v in $_pe_vars; do
    eval "_pe_p=\$_pe_pre_$_pe_v"
    if [ "$_pe_p" != "__unset__" ]; then eval "$_pe_v=\$_pe_p"; fi
    unset "_pe_pre_$_pe_v"
  done
fi

PROJECT_NAME="${PROJECT_NAME-project}"
PROJECT_ROOT="${PROJECT_ROOT-$HOME/$PROJECT_NAME}"
PROJECT_GIT_ORG="${PROJECT_GIT_ORG-$PROJECT_NAME}"
PROJECT_CREDS_DIR="${PROJECT_CREDS_DIR-${PROJECT_ROOT%/}-creds}"
if [ -z "${PROJECT_BASE_BRANCH:-}" ]; then
  _pe_head="$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)"
  _pe_head="${_pe_head#refs/remotes/origin/}"
  PROJECT_BASE_BRANCH="${_pe_head:-main}"
fi
SYNC_SERVER="${SYNC_SERVER-}"
STAND_DB_HOST="${STAND_DB_HOST-}"
HISTORY_REMOTE="${HISTORY_REMOTE-${SYNC_SERVER:+$SYNC_SERVER:agent-history/claude}}"

_pe_key="${PROJECT_ROOT%/}"
_pe_key="${_pe_key//\//-}"
PROJECT_KEY="${_pe_key//./-}"

export PROJECT_NAME PROJECT_ROOT PROJECT_GIT_ORG PROJECT_CREDS_DIR PROJECT_BASE_BRANCH \
       SYNC_SERVER HISTORY_REMOTE STAND_DB_HOST PROJECT_KEY
unset _pe_vars _pe_file _pe_v _pe_p _pe_key _pe_head
