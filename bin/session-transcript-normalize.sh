#!/usr/bin/env bash
# Session transcript normalizer → NDJSON {k,t|p|c}.
# Reads by record shape, not by agent label:
#   · jsonl (Claude / Cursor / similar): .type|.role, tool_use|tool
#   · sqlite (OpenCode session_message / Mimo message+part)
# Output:
#   {"k":"meta","id":"...","cwd":"..."}
#   {"k":"user","t":"..."}
#   {"k":"edit","p":"/path"}
#   {"k":"shell","c":"cmd"}
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib/compat.sh" || exit 1

usage() {
  cat <<'EOF'
session-transcript-normalize.sh --id <session_id> [--transcript <path|sqlite:path>] [--cwd <dir>]
EOF
}

SID='' TRANSCRIPT='' CWD=''
while [ $# -gt 0 ]; do
  case "$1" in
    --id) SID="${2:-}"; shift 2 ;;
    --transcript) TRANSCRIPT="${2:-}"; shift 2 ;;
    --cwd) CWD="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$SID" ] || { echo "--id is required" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

# --- resolve source ---------------------------------------------------------

is_sqlite_uri() { case "$1" in sqlite:*|*.db) return 0 ;; *) return 1 ;; esac; }
sqlite_path_of() {
  local t="$1"
  case "$t" in
    sqlite:*) printf '%s' "${t#sqlite:}" ;;
    *)        printf '%s' "$t" ;;
  esac
}

sqlite3_quote() { # ' → ''
  local s="$1"
  s="${s//\'/\'\'}"
  printf "'%s'" "$s"
}

resolve_source() {
  if [ -n "$TRANSCRIPT" ]; then
    if is_sqlite_uri "$TRANSCRIPT"; then
      local db; db="$(sqlite_path_of "$TRANSCRIPT")"
      [ -f "$db" ] || return 1
      printf 'sqlite\t%s\n' "$db"
      return 0
    fi
    if [ -f "$TRANSCRIPT" ]; then
      case "$TRANSCRIPT" in
        *.db) printf 'sqlite\t%s\n' "$TRANSCRIPT" ;;
        *)    printf 'jsonl\t%s\n' "$TRANSCRIPT" ;;
      esac
      return 0
    fi
  fi
  local f
  f="$(find "$HOME/.claude/projects" -name "$SID*.jsonl" -type f 2>/dev/null | head -1)"
  [ -n "$f" ] && { printf 'jsonl\t%s\n' "$f"; return 0; }
  f="$(find "$HOME/.cursor/projects" -path '*/agent-transcripts/*' \
        -name "$SID*.jsonl" -type f 2>/dev/null | head -1)"
  [ -n "$f" ] && { printf 'jsonl\t%s\n' "$f"; return 0; }

  local db
  for db in \
      "${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}" \
      "${MIMO_DB:-$HOME/.local/share/mimocode/mimocode.db}"; do
    [ -f "$db" ] || continue
    command -v sqlite3 >/dev/null 2>&1 || continue
    if sqlite3 "$db" "SELECT 1 FROM sqlite_master WHERE type='table' AND name IN ('session_v2','session') LIMIT 1;" 2>/dev/null | grep -q 1; then
      if sqlite3 "$db" "SELECT 1 FROM session_v2 WHERE id=$(sqlite3_quote "$SID") LIMIT 1;" 2>/dev/null | grep -q 1 \
         || sqlite3 "$db" "SELECT 1 FROM session WHERE id=$(sqlite3_quote "$SID") LIMIT 1;" 2>/dev/null | grep -q 1; then
        printf 'sqlite\t%s\n' "$db"
        return 0
      fi
    fi
  done
  return 1
}

# --- jsonl → NDJSON ---------------------------------------------------------
# Shape: Claude (.type), Cursor (.role + <user_query>), tool_use / tool.

emit_jsonl() {
  local file="$1"
  jq -rsc --arg id "$SID" --arg fallback_cwd "$CWD" '
    def raw_text:
      if has("message") then
        (.message.content
         | if type == "string" then .
           elif type == "array" then
             (map(select(.type=="text") | (.text // empty)) | join(" "))
           else empty end)
      elif (.text | type) == "string" then .text
      elif (.content | type) == "string" then .content
      elif (.content | type) == "array" then
        (.content | map(select(.type=="text") | (.text // empty)) | join(" "))
      else empty end;

    def user_text:
      raw_text
      | if type != "string" then empty else . end
      | if test("<user_query>") then
          sub("(?s)^.*<user_query>\\s*"; "") | sub("(?s)\\s*</user_query>.*$"; "")
        else . end
      | gsub("^\\s+|\\s+$"; "")
      | select(. != "" and (startswith("<") | not));

    def tool_blocks:
      (.message.content // .content // empty)
      | if type == "array" then .[] else empty end
      | select(.type == "tool_use" or .type == "tool");

    def tool_name: (.name // .tool // "");
    def tool_input: (.input // .state.input // {});

    def is_edit:
      (tool_name | ascii_downcase) as $n
      | ($n == "edit" or $n == "write" or $n == "strreplace"
         or $n == "search_replace" or $n == "apply_patch");

    def is_shell:
      (tool_name | ascii_downcase) as $n
      | ($n == "bash" or $n == "shell" or $n == "run_terminal_cmd"
         or $n == "execute" or $n == "terminal");

    def edit_path:
      tool_input | (.file_path // .path // .filePath // .file // empty)
      | select(type == "string" and . != "");

    def shell_cmd:
      tool_input | (.command // .cmd // empty)
      | select(type == "string" and . != "");

    (map(select(.cwd != null) | .cwd) | .[0] // $fallback_cwd) as $cwd
    | {k:"meta", id:$id, cwd:$cwd},
      (.[] | select(.type == "user" or .role == "user") | user_text | {k:"user", t:.}),
      (.[] | tool_blocks
           | if is_edit then (edit_path | {k:"edit", p:.})
             elif is_shell then (shell_cmd | {k:"shell", c:.})
             else empty end)
  ' "$file" 2>/dev/null
}

# --- OpenCode sqlite --------------------------------------------------------

emit_opencode() {
  local db="$1" qsid
  qsid="$(sqlite3_quote "$SID")"
  command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 is required" >&2; return 1; }
  local cwd
  cwd="$(sqlite3 "$db" "SELECT directory FROM session_v2 WHERE id=$qsid LIMIT 1;" 2>/dev/null)"
  [ -n "$cwd" ] || cwd="$CWD"
  jq -nc --arg id "$SID" --arg cwd "$cwd" '{k:"meta",id:$id,cwd:$cwd}'

  sqlite3 -separator $'\t' "$db" \
    "SELECT seq, data FROM session_message WHERE session_id=$qsid AND type='user' ORDER BY seq;" \
    2>/dev/null \
    | while IFS=$'\t' read -r _ data; do
        [ -n "$data" ] || continue
        jq -c '(.text // empty) | select(type=="string" and . != "") | {k:"user", t:.}' <<<"$data" 2>/dev/null
      done

  sqlite3 -separator $'\t' "$db" \
    "SELECT type, data FROM session_message WHERE session_id=$qsid AND type IN ('assistant','shell') ORDER BY seq;" \
    2>/dev/null \
    | while IFS=$'\t' read -r typ data; do
        [ -n "$data" ] || continue
        if [ "$typ" = shell ]; then
          jq -c '(.command // empty) | select(type=="string" and . != "") | {k:"shell", c:.}' <<<"$data" 2>/dev/null
          continue
        fi
        jq -c '
          (.content // [])
          | .[]?
          | select(.type == "tool")
          | (.name // "" | ascii_downcase) as $n
          | (.state.input // .input // {}) as $in
          | if ($n == "edit" or $n == "write" or $n == "strreplace") then
              ($in.path // $in.file_path // $in.filePath // empty)
              | select(type=="string" and . != "") | {k:"edit", p:.}
            elif ($n == "shell" or $n == "bash" or $n == "execute") then
              ($in.command // $in.cmd // empty)
              | select(type=="string" and . != "") | {k:"shell", c:.}
            else empty end
        ' <<<"$data" 2>/dev/null
      done
}

# --- Mimo sqlite ------------------------------------------------------------

emit_mimo() {
  local db="$1" qsid
  qsid="$(sqlite3_quote "$SID")"
  command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 is required" >&2; return 1; }
  local cwd
  cwd="$(sqlite3 "$db" "SELECT directory FROM session WHERE id=$qsid LIMIT 1;" 2>/dev/null)"
  [ -n "$cwd" ] || cwd="$CWD"
  jq -nc --arg id "$SID" --arg cwd "$cwd" '{k:"meta",id:$id,cwd:$cwd}'

  sqlite3 -separator $'\t' "$db" "
    SELECT json_extract(m.data,'\$.role'),
           json_extract(p.data,'\$.type'),
           p.data
    FROM message m
    JOIN part p ON p.message_id = m.id
    WHERE m.session_id = $qsid
    ORDER BY m.time_created, p.time_created;
  " 2>/dev/null \
    | while IFS=$'\t' read -r role ptype data; do
        [ -n "$data" ] || continue
        if [ "$role" = user ] && [ "$ptype" = text ]; then
          jq -c '(.text // empty) | select(type=="string" and . != "") | {k:"user", t:.}' <<<"$data" 2>/dev/null
        elif [ "$ptype" = tool ]; then
          jq -c '
            (.tool // .name // "" | ascii_downcase) as $n
            | (.state.input // .input // {}) as $in
            | if ($n == "edit" or $n == "write" or $n == "strreplace"
                  or $n == "search_replace") then
                ($in.file_path // $in.path // $in.filePath // empty)
                | select(type=="string" and . != "") | {k:"edit", p:.}
              elif ($n == "bash" or $n == "shell") then
                ($in.command // $in.cmd // empty)
                | select(type=="string" and . != "") | {k:"shell", c:.}
              else empty end
          ' <<<"$data" 2>/dev/null
        fi
      done
}

detect_sqlite_flavor() {
  local db="$1"
  if sqlite3 "$db" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_v2';" 2>/dev/null | grep -q 1; then
    printf opencode
  elif sqlite3 "$db" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='message';" 2>/dev/null | grep -q 1 \
    && sqlite3 "$db" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='part';" 2>/dev/null | grep -q 1; then
    printf mimo
  else
    printf unknown
  fi
}

# --- main -------------------------------------------------------------------

src="$(resolve_source)" || { echo "transcript not found for session $SID" >&2; exit 1; }
kind="${src%%$'\t'*}"
path="${src#*$'\t'}"

case "$kind" in
  jsonl)
    emit_jsonl "$path"
    ;;
  sqlite)
    case "$(detect_sqlite_flavor "$path")" in
      opencode) emit_opencode "$path" ;;
      mimo)     emit_mimo "$path" ;;
      *)
        echo "unknown sqlite schema: $path" >&2
        exit 1
        ;;
    esac
    ;;
  *) echo "unknown source" >&2; exit 1 ;;
esac
