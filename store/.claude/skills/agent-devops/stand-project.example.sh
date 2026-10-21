# EXAMPLE stand-project.sh for a made-up project "acme": four services (api, auth, worker, web),
# one shared LAN DB mode and two ssh-tunnel modes. Nothing here is a real host or credential.
#
# How to use: copy to stand-project.sh and replace, in this order,
#   1. the service ids, ports, health paths and checkout dirs (svc_defaults, default_dir_for);
#   2. the profiles (profile_services) from the "Project stand map" section of SKILL.md;
#   3. the DB modes (STAND_DB_MODES, db_expect_host/port) — one per way of reaching the data;
#   4. the env overlays in ensure_extras: variable NAMES your services read, never values of secrets;
#   5. stand_verify_env: which env variable of each process proves it points at the chosen DB.
# standctl sources stand-project.sh; everything project-specific lives there.
#
# Contract (functions standctl calls):
#   canonical_svc_name <alias>            -> service id (same as repo dir name by convention)
#   profile_services <profile>            -> space-separated service ids
#   svc_defaults <svc>                    -> "port|health-path|kind|extras_csv"   (kind: node | vite-preview)
#   default_dir_for <svc>                 -> checkout dir
#   db_expect_host / db_expect_port <db_mode>
#   ensure_extras <db_mode>               -> writes env files into $EXTRAS_DIR
#   extra_files_for <extras_csv> <db_mode>-> env files for a service (one path per line)
#   stand_service_extra_files <svc>       -> more env files for one service (one path per line)
#   stand_verify_env <svc> <pid> <db_mode> <expected host>  -> die if the listener has the wrong DB env
#   stand_preflight_extra <db_mode> <profile>   -> extra reachability checks (warn, or die)
#   stand_status_dbhost <pid>             -> DB host of a running service, for `status`
#   migrate_state_service_keys            -> rename old keys in $STATE (no-op by default)
#   STAND_STATUS_PORTS                    -> ports shown by `status` when there is no state file
#   STAND_DB_MODES                        -> text for usage()
#   STAND_PROFILES                        -> text for usage()
#   STAND_DEFAULT_DB / STAND_DEFAULT_PROFILE -> defaults for preflight/up

# lan = shared dev DBs on a LAN host, taken from STAND_DB_HOST (agent-sync.env); without it the first tunnel mode is the default
if [ -n "${STAND_DB_HOST:-}" ]; then STAND_DEFAULT_DB="lan"; else STAND_DEFAULT_DB="dev-tunnel"; fi
STAND_DEFAULT_PROFILE="core"
STAND_REPORT_ENV="DB_HOST,DB_PORT,DB_NAME"   # printed by start-svc.mjs; variable names only, never list secrets here
export STAND_REPORT_ENV
STAND_STATUS_PORTS="8080 3000 3001 3002"
STAND_DB_MODES="lan|dev-tunnel|staging-tunnel"
STAND_PROFILES="core|jobs|full"

# Local ends of your ssh tunnels (ssh -L <port>:<db>:3306 <bastion>); change to the ports you use.
DEV_TUNNEL_PORT=3307
STAGING_TUNNEL_PORT=3308

lan_host() {
  [ -n "${STAND_DB_HOST:-}" ] || die "DB mode lan needs STAND_DB_HOST (set it in ~/.agent-sync/agent-sync.env) or pick a tunnel mode"
  echo "$STAND_DB_HOST"
}

db_expect_host() {
  case "${1:-$STAND_DEFAULT_DB}" in
    lan) lan_host ;;
    dev-tunnel|staging-tunnel) echo 127.0.0.1 ;;
    *) die "unknown db mode: $1" ;;
  esac
}

db_expect_port() {
  case "${1:-$STAND_DEFAULT_DB}" in
    lan) echo 3306 ;;
    dev-tunnel) echo "$DEV_TUNNEL_PORT" ;;
    staging-tunnel) echo "$STAGING_TUNNEL_PORT" ;;
    *) die "unknown db mode: $1" ;;
  esac
}

# Canonical service id = repo dir name. Aliases people type in [DEVOPS REQUEST] map here.
canonical_svc_name() {
  case "$1" in
    api|backend) echo acme-api ;;
    web|frontend) echo acme-web ;;
    auth) echo acme-auth ;;
    worker|jobs) echo acme-worker ;;
    *) echo "$1" ;;
  esac
}

profile_services() {
  case "$1" in
    core) echo acme-auth acme-api acme-web ;;
    jobs) echo acme-auth acme-api acme-worker acme-web ;;
    full) echo acme-auth acme-api acme-worker acme-web ;;
    *) die "unknown profile: $1 (core|jobs|full)" ;;
  esac
}

svc_defaults() {
  # name|port|health|kind|extras_csv   (extras_csv names the overlays from extra_files_for)
  local name
  name="$(canonical_svc_name "$1")"
  case "$name" in
    acme-auth)   echo "3001|/health|node|" ;;
    acme-api)    echo "3000|/health/live|node|auth-url" ;;
    acme-worker) echo "3002|/health|node|auth-url" ;;
    acme-web)    echo "8080|/|vite-preview|" ;;
    *) die "unknown service: $1" ;;
  esac
}

default_dir_for() {
  local name
  name="$(canonical_svc_name "$1")"
  case "$name" in
    acme-auth)   echo "${PROJECT_ROOT}/acme-auth" ;;
    acme-api)    echo "${PROJECT_ROOT}/acme-api" ;;
    acme-worker) echo "${PROJECT_ROOT}/acme-worker" ;;
    acme-web)    echo "${PROJECT_ROOT}/acme-web" ;;
  esac
}

# Env overlays applied on top of the service's own .env/.env.local (last file wins in start-svc).
# Only variable names of YOUR services go here; credentials are read from the repo's own .env.
ensure_extras() {
  local db_mode="$1"
  [ "$db_mode" = "lan" ] && lan_host >/dev/null

  # Services that call each other: point them at the local ports, not at the dev cluster.
  cat >"${EXTRAS_DIR}/auth-url.env" <<'EOF'
AUTH_API_URL=http://127.0.0.1:3001
EOF

  local db_overlay="${EXTRAS_DIR}/db-overlay.env"
  case "$db_mode" in
    lan)
      printf 'DB_HOST=%s\nDB_PORT=3306\n' "$STAND_DB_HOST" >"$db_overlay"
      ;;
    dev-tunnel)
      printf 'DB_HOST=127.0.0.1\nDB_PORT=%s\n' "$DEV_TUNNEL_PORT" >"$db_overlay"
      ;;
    staging-tunnel)
      printf 'DB_HOST=127.0.0.1\nDB_PORT=%s\n' "$STAGING_TUNNEL_PORT" >"$db_overlay"
      ;;
    *)
      rm -f "$db_overlay"
      ;;
  esac
}

extra_files_for() {
  local extras_csv="$1" db_mode="$2"
  local out=() e
  IFS=',' read -ra parts <<<"$extras_csv"
  for e in "${parts[@]}"; do
    [ -z "$e" ] && continue
    case "$e" in
      auth-url)
        [ -s "${EXTRAS_DIR}/auth-url.env" ] && out+=("${EXTRAS_DIR}/auth-url.env")
        ;;
    esac
  done
  printf '%s\n' "${out[@]+"${out[@]}"}"
}

# Every backend gets the DB overlay; the frontend does not read DB_*.
stand_service_extra_files() {
  case "$(canonical_svc_name "$1")" in
    acme-api|acme-auth|acme-worker)
      [ -s "${EXTRAS_DIR}/db-overlay.env" ] && printf '%s\n' "${EXTRAS_DIR}/db-overlay.env"
      ;;
  esac
  return 0
}

# Rename state keys when a service id changes (example: an old alias "jobs" became "acme-worker").
migrate_state_service_keys() {
  [ -f "$STATE" ] || return 0
  if jq -e '.services.jobs // empty' "$STATE" >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp)"
    jq '
      if .services.jobs then
        .services["acme-worker"] = (
          .services.jobs
          | .pidfile |= gsub("/logs/jobs\\.pid$"; "/logs/acme-worker.pid")
        )
        | del(.services.jobs)
      else . end
    ' "$STATE" >"$tmp" && mv "$tmp" "$STATE"
    info "migrated state key jobs -> acme-worker"
  fi
}

# Health 200 is not enough: prove the live process points at the chosen DB.
# Use the variable each service actually reads (they differ between repos more often than you think).
stand_verify_env() {
  local name="$1" lp="$2" db_mode="$3" expect="$4" host_got
  case "$(canonical_svc_name "$name")" in
    acme-web) info "${name}: OK health=200 (frontend, no DB)" ;;
    *)
      host_got="$(env_from_pid "$lp" DB_HOST)"
      [ "$host_got" = "$expect" ] || die "${name}: DB_HOST=${host_got} want ${expect}"
      info "${name}: OK health=200 DB_HOST=${host_got}"
      ;;
  esac
}

# Extra reachability per profile: e.g. a queue or a second DB engine only some profiles use.
stand_preflight_extra() {
  local db_mode="$1" profile="$2"
  case "$profile" in
    jobs|full)
      if [ "$db_mode" = "lan" ]; then
        if tcp_ok "$STAND_DB_HOST" 6379; then
          info "Redis ${STAND_DB_HOST}:6379 OK"
        else
          info "WARN: Redis ${STAND_DB_HOST}:6379 unreachable (acme-worker needs it)"
        fi
      fi
      ;;
  esac
}

stand_status_dbhost() {
  env_from_pid "${1:-}" DB_HOST
}
