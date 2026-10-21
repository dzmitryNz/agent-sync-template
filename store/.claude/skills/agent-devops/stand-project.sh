# stand-project.sh — project-specific part of standctl. EDIT FOR YOUR STACK.
# Contract and a complete worked example: stand-project.example.sh (same directory).
# This default describes one service named "app" on port 3000 and a local DB.

STAND_DEFAULT_DB="local"
STAND_DEFAULT_PROFILE="core"
STAND_STATUS_PORTS="3000"
STAND_DB_MODES="local"
STAND_PROFILES="core"

db_expect_host() { echo 127.0.0.1; }
db_expect_port() { echo 3306; }

canonical_svc_name() { echo "$1"; }

profile_services() {
  case "$1" in
    core) echo app ;;
    *) die "unknown profile: $1 (core)" ;;
  esac
}

svc_defaults() {
  # name -> port|health path|kind (node | vite-preview)|extras_csv
  case "$1" in
    app) echo "3000|/health|node|" ;;
    *) die "unknown service: $1" ;;
  esac
}

default_dir_for() {
  case "$1" in
    app) echo "${PROJECT_ROOT}/app" ;;
  esac
}

ensure_extras() { :; }
extra_files_for() { :; }
stand_service_extra_files() { :; }
migrate_state_service_keys() { :; }
stand_preflight_extra() { :; }
stand_status_dbhost() { env_from_pid "${1:-}" DB_HOST; }

stand_verify_env() {
  local name="$1" lp="$2" expect="$4" got
  got="$(env_from_pid "$lp" DB_HOST)"
  [ -z "$got" ] || [ "$got" = "$expect" ] || die "${name}: DB_HOST=${got} want ${expect}"
  info "${name}: OK health=200 DB_HOST=${got:--}"
}
