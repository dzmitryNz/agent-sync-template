#!/usr/bin/env bash
# Tests for tools-check.sh: checks that the machine has everything the rules rely on.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/bin/tools-check.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "not met: $*"; fi; }

setup() {
  TMP="$(mktemp -d)"
  export TOOLS_CONF="$TMP/tools.conf"
  # isolated PATH: only what we put there is visible
  mkdir -p "$TMP/bin"
  export PATH="$TMP/bin:/usr/bin:/bin"
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

have() { printf '#!/bin/sh\necho ok\n' > "$TMP/bin/$1"; chmod +x "$TMP/bin/$1"; }
conf() { printf '%s\n' "$@" > "$TOOLS_CONF"; }

# --- 1. what is missing is shown together with how to install it -------------
t_missing() {
  conf 'madeup-y :: npm i -g madeup-y :: structural search'
  local out; out="$("$CHECK" 2>&1)"
  check "tool marked as missing" grep -q 'madeup-y' <<<"$out"
  check "install command shown"       grep -q 'npm i -g madeup-y' <<<"$out"
  check "purpose shown"         grep -q 'structural search' <<<"$out"
}

# --- 2. an installed tool is not offered for installation again ---------------
t_present() {
  have mytool
  conf 'mytool :: apt install mytool :: test'
  local out; out="$("$CHECK" 2>&1)"
  check "marked as present" grep -qE '(have|ok|✓).*mytool' <<<"$out"
  check "install command is not pushed" \
    test -z "$(grep 'apt install mytool' <<<"$out")"
}

# --- 3. a missing required tool is a failure ---------------------------------
t_exit_code() {
  conf 'nosuchtool :: apt install nosuchtool :: test'
  local rc; "$CHECK" >/dev/null 2>&1; rc=$?
  check "exit 1 when a required tool is missing" test "$rc" -eq 1
}

# --- 4. comments and empty lines in the manifest are ignored ------------------
t_comments() {
  conf '# this is a comment' '' 'mytool :: apt install mytool :: test'
  local out; out="$("$CHECK" 2>&1)"
  check "comment did not become a tool" test -z "$(grep 'this is a comment' <<<"$out")"
}

# --- 5. the summary line says how many are missing ----------------------------
t_summary() {
  have have1
  conf 'have1 :: apt install have1 :: test' \
       'miss1 :: apt install miss1 :: test' \
       'miss2 :: apt install miss2 :: test'
  local out; out="$("$CHECK" 2>&1)"
  check "the summary names the number of missing tools" grep -qE '(missing|absent)[^0-9]*2' <<<"$out"
}

# --- 6. --install installs only what can be done without sudo ----------------
# apt lines need a password, and a non-interactive run has nowhere to get it.
t_install_skips_sudo() {
  conf 'noapt :: apt install noapt :: test'
  local out; out="$("$CHECK" --install 2>&1)"
  check "apt is not run silently"  test -z "$(grep -E '^Installing.*noapt' <<<"$out")"
  check "it says that sudo is needed"   grep -qi 'sudo\|manually' <<<"$out"
}

# --- 7. a vertical bar inside the install command does not break parsing -----
# Real commands contain pipes: `curl ... :: bash`, jq filters.
t_pipe_in_command() {
  conf 'nosuchtool :: curl -fsSL https://x/i.sh | bash :: installer with a pipe'
  local out; out="$("$CHECK" 2>&1)"
  check "command shown in full" grep -q 'curl -fsSL https://x/i.sh | bash' <<<"$out"
  check "purpose did not shift"    grep -q 'installer with a pipe' <<<"$out"
}

# --- macOS: its own list with brew lines -------------------------------------
fake_brew() {
  mkdir -p "$TMP/brew/opt/coreutils/libexec/gnubin" "$TMP/brew/opt/gnu-sed/libexec/gnubin" \
           "$TMP/brew/opt/findutils/libexec/gnubin"
  mkdir -p "$TMP/brew/bin"; ln -sf "$(command -v bash)" "$TMP/brew/bin/bash"
  export AGENT_SYNC_OS=darwin HOMEBREW_PREFIX="$TMP/brew"
  unset TOOLS_CONF
}
t_darwin_conf() {
  fake_brew
  local out; out="$("$CHECK" 2>&1)"
  check "brew install lines"            grep -q 'brew install coreutils' <<<"$out"
  check "herdr from brew"               grep -q 'brew install herdr' <<<"$out"
  check "no apt on macOS"               test -z "$(grep 'apt install' <<<"$out")"
  check "GNU date is required"          grep -qE 'MISSING +gdate' <<<"$out"
}
t_darwin_old_bash() {
  fake_brew
  local out; out="$(AGENT_SYNC_BASH_MAJOR=3 "$CHECK" 2>&1)"; local rc=$?
  check "exit 1"                        test "$rc" -eq 1
  check "bash 4 reported"               grep -qE 'MISSING +bash>=4 .*' <<<"$out"
  check "with the brew command"         grep -q 'brew install bash' <<<"$out"
}
t_linux_arch() {
  check "rg asset by uname -m"  grep -qE '^rg ::.*\$\(uname -m\)' "$ROOT/tools.conf"
  check "no fixed x86_64 asset" test -z "$(grep -E '^(rg|fd|yq|ralphex) ::' "$ROOT/tools.conf" | grep -E 'x86_64|amd64\b' | grep -v 'uname -m')"
}

run_test "pipe in the install command"                 t_pipe_in_command
run_test "what is missing is shown with how to install it" t_missing
run_test "an installed tool is not offered for installation"    t_present
run_test "a missing required tool exits 1"       t_exit_code
run_test "comments are ignored"                 t_comments
run_test "the summary says how many are missing"          t_summary
run_test "--install does not use apt without sudo"        t_install_skips_sudo

t_optional_missing() {
  conf 'opttool :: sudo apt install opttool :: OPTIONAL database client'
  local out; out="$("$CHECK" 2>&1)"
  check "optional is not a missing failure" grep -q 'all present' <<<"$out"
  check "optional line is shown" grep -q 'optional' <<<"$out"
}

t_note_is_not_a_command() {
  conf 'herdr :: see herdr.dev — its own installer :: multiplexer'
  local out; out="$("$CHECK" --install 2>&1)"
  check "a note is not executed" grep -q 'not a command' <<<"$out"
  check "a note does not say installing" test -z "$(grep installing <<<"$out")"
}

t_nvm_login_shell() {
  cat > "$TMP/bin/loginsh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "$TMP/bash.log"
exit 0
EOF
  chmod +x "$TMP/bin/loginsh"
  conf 'need-node :: nvm install 22 :: runtime'
  TOOLS_INSTALL_SHELL="$TMP/bin/loginsh" "$CHECK" --install >/dev/null 2>&1
  check "nvm runs via a login shell" grep -q -- '-lc nvm install 22' "$TMP/bash.log"
}

run_test "optional missing does not fail" t_optional_missing
run_test "a note in the install column is not a command" t_note_is_not_a_command
run_test "nvm install uses a login shell" t_nvm_login_shell
run_test "macOS reads tools.macos.conf"      t_darwin_conf
run_test "macOS without bash 4 is a missing tool" t_darwin_old_bash
run_test "Linux downloads pick the CPU type" t_linux_arch

printf '\ntotal: %d ok, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
