#!/usr/bin/env bash
# =====================================================================
#  PgBouncer auto-sync sidecar.
#
#  Polls Postgres (via HAProxy write port → leader) for the list of
#  user databases, compares with pgbouncer.ini, and if a new database
#  appeared (e.g. user ran `CREATE DATABASE` from pgAdmin or app code),
#  re-renders /etc/pgbouncer/pgbouncer.ini with the same alias scheme
#  (<db>, <db>_rw, <db>_ro) and issues `RELOAD;` to the PgBouncer admin
#  console. PgBouncer reload is online — existing client connections
#  stay alive.
#
#  Runs in a sidecar container that shares /etc/pgbouncer with the main
#  pgbouncer container via a named volume.
#
#  Inputs (env):
#    APP_DB_NAME, APP_DB_USER, APP_DB_PASSWORD                    (required)
#    HAPROXY_HOST, HAPROXY_WRITE_PORT                              (defaults haproxy/5000)
#    PGBOUNCER_HOST, PGBOUNCER_PORT                                (defaults pgbouncer/6432)
#    APP_DBS_EXTRA                                                 (comma-separated; merged with auto-discovered)
#    PGBOUNCER_AUTOSYNC_ENABLED      (default true)
#    PGBOUNCER_AUTOSYNC_INTERVAL     (default 30)         seconds between polls
#    PGBOUNCER_AUTOSYNC_EXCLUDE      (default postgres,template0,template1)
#    PGBOUNCER_AUTOSYNC_INITIAL_DELAY (default 15)        seconds to wait at startup
#
#  Logs to stdout. Tails as `docker logs pg-pgbouncer-autosync`.
# =====================================================================
set -euo pipefail

: "${APP_DB_NAME:?APP_DB_NAME must be set}"
: "${APP_DB_USER:?APP_DB_USER must be set}"
: "${APP_DB_PASSWORD:?APP_DB_PASSWORD must be set}"
: "${HAPROXY_HOST:=haproxy}"
: "${HAPROXY_WRITE_PORT:=5000}"
: "${HAPROXY_READ_PORT:=5001}"
: "${PGBOUNCER_HOST:=pgbouncer}"
: "${PGBOUNCER_PORT:=6432}"
: "${APP_DBS_EXTRA:=}"
: "${PGBOUNCER_AUTOSYNC_ENABLED:=true}"
: "${PGBOUNCER_AUTOSYNC_INTERVAL:=30}"
: "${PGBOUNCER_AUTOSYNC_EXCLUDE:=postgres,template0,template1}"
: "${PGBOUNCER_AUTOSYNC_INITIAL_DELAY:=15}"
: "${PGBOUNCER_INI_PATH:=/etc/pgbouncer/pgbouncer.ini}"

log() { printf '%s [autosync] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

if [ "${PGBOUNCER_AUTOSYNC_ENABLED}" != "true" ]; then
  log "PGBOUNCER_AUTOSYNC_ENABLED=${PGBOUNCER_AUTOSYNC_ENABLED} — disabled, sleeping forever"
  exec sleep infinity
fi

# Build EXCLUDE_REGEX from comma-separated list, used in awk filter below.
# e.g. "postgres,template0,template1" → "^(postgres|template0|template1)$"
EXCLUDE_REGEX=$(echo "${PGBOUNCER_AUTOSYNC_EXCLUDE}" \
  | tr ',' '|' \
  | sed 's/^/^(/' \
  | sed 's/$/)$/')

export PGPASSWORD="${APP_DB_PASSWORD}"

# Initial delay so pgbouncer container has time to render pgbouncer.ini.
log "starting; initial_delay=${PGBOUNCER_AUTOSYNC_INITIAL_DELAY}s, interval=${PGBOUNCER_AUTOSYNC_INTERVAL}s"
log "exclude pattern: ${EXCLUDE_REGEX}"
log "APP_DBS_EXTRA (manual override list): ${APP_DBS_EXTRA:-<empty>}"
sleep "${PGBOUNCER_AUTOSYNC_INITIAL_DELAY}"

# Wait for pgbouncer.ini to exist (the main pgbouncer container renders it).
while [ ! -s "${PGBOUNCER_INI_PATH}" ]; do
  log "waiting for ${PGBOUNCER_INI_PATH} to be rendered by pgbouncer container..."
  sleep 5
done

query_postgres_dbs() {
  # Returns sorted unique DB names, one per line, excluding the EXCLUDE_REGEX list.
  psql -h "${HAPROXY_HOST}" -p "${HAPROXY_WRITE_PORT}" -U "${APP_DB_USER}" -d postgres \
       -tAX -v ON_ERROR_STOP=1 \
       -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datallowconn = true ORDER BY datname;" \
    | awk -v re="${EXCLUDE_REGEX}" '$0 != "" && $0 !~ re { print }' \
    | sort -u
}

current_pgbouncer_dbs() {
  # Parse pgbouncer.ini, return primary DB aliases (no _rw/_ro suffix), sorted unique.
  awk '
    /^\[pgbouncer\]/ { exit }
    /^\[databases\]/ { in_db=1; next }
    in_db && /^[a-zA-Z0-9_]+ +=/ {
      name=$1
      if (name ~ /_(rw|ro)$/) next
      print name
    }
  ' "${PGBOUNCER_INI_PATH}" | sort -u
}

reload_pgbouncer() {
  # Issue RELOAD to PgBouncer admin DB. APP_DB_USER is in admin_users.
  if psql -h "${PGBOUNCER_HOST}" -p "${PGBOUNCER_PORT}" -U "${APP_DB_USER}" -d pgbouncer \
          -X -v ON_ERROR_STOP=1 -c "RELOAD;" >/dev/null 2>&1; then
    return 0
  else
    log "WARNING: RELOAD via psql failed (pgbouncer may still be starting); retrying next cycle"
    return 1
  fi
}

re_render_ini() {
  # Combine auto-discovered DBs (excluding APP_DB_NAME, since helper emits it)
  # with APP_DBS_EXTRA (user manual list). Helper validates+dedupes.
  local discovered_list="$1"
  local manual_list
  manual_list=$(echo "${APP_DBS_EXTRA}" | tr ',' ' ')
  local extra_dbs
  extra_dbs=$(printf '%s\n%s\n' "${discovered_list}" "${manual_list}" \
              | tr ' ' '\n' | grep -v "^${APP_DB_NAME}\$" | grep -v '^$' \
              | sort -u | tr '\n' ' ')

  EXTRA_DBS="${extra_dbs}" \
    APP_DB_NAME="${APP_DB_NAME}" \
    APP_DB_USER="${APP_DB_USER}" \
    HAPROXY_HOST="${HAPROXY_HOST}" \
    HAPROXY_WRITE_PORT="${HAPROXY_WRITE_PORT}" \
    HAPROXY_READ_PORT="${HAPROXY_READ_PORT}" \
    PGBOUNCER_POOL_MODE="${PGBOUNCER_POOL_MODE:-transaction}" \
    PGBOUNCER_MAX_CLIENT_CONN="${PGBOUNCER_MAX_CLIENT_CONN:-1000}" \
    PGBOUNCER_DEFAULT_POOL_SIZE="${PGBOUNCER_DEFAULT_POOL_SIZE:-80}" \
    PGBOUNCER_RESERVE_POOL_SIZE="${PGBOUNCER_RESERVE_POOL_SIZE:-20}" \
    sh /usr/local/bin/build-pgbouncer-ini.sh > "${PGBOUNCER_INI_PATH}.new"

  # Atomic swap so partial writes never end up in the live file.
  mv "${PGBOUNCER_INI_PATH}.new" "${PGBOUNCER_INI_PATH}"
}

while true; do
  if ! discovered=$(query_postgres_dbs 2>&1); then
    log "WARNING: failed to query pg_database (Postgres unreachable?): ${discovered}"
    sleep "${PGBOUNCER_AUTOSYNC_INTERVAL}"
    continue
  fi

  current=$(current_pgbouncer_dbs)

  # Build "expected" set = discovered ∪ APP_DBS_EXTRA (∪ APP_DB_NAME ∪ postgres).
  # 'postgres' is always routed by build-pgbouncer-ini.sh for admin access.
  manual=$(echo "${APP_DBS_EXTRA}" | tr ',' ' ' | tr ' ' '\n' | grep -v '^$' || true)
  expected=$(printf '%s\n%s\n%s\n%s\n' "${APP_DB_NAME}" "postgres" "${discovered}" "${manual}" \
             | grep -v '^$' | sort -u)

  if [ "${current}" = "${expected}" ]; then
    sleep "${PGBOUNCER_AUTOSYNC_INTERVAL}"
    continue
  fi

  added=$(comm -13 <(echo "${current}") <(echo "${expected}") | tr '\n' ' ' | sed 's/ *$//')
  removed=$(comm -23 <(echo "${current}") <(echo "${expected}") | tr '\n' ' ' | sed 's/ *$//')
  log "drift detected — added: [${added:-<none>}], removed: [${removed:-<none>}]"

  if re_render_ini "${discovered}"; then
    if reload_pgbouncer; then
      log "RELOAD ok — pgbouncer.ini now routes: $(echo "${expected}" | tr '\n' ' ')"
    fi
  else
    log "ERROR: re-render failed; keeping previous pgbouncer.ini"
  fi

  sleep "${PGBOUNCER_AUTOSYNC_INTERVAL}"
done
