#!/bin/sh
# =====================================================================
#  Build PgBouncer pgbouncer.ini to stdout.
#
#  Used by:
#    - scripts/render-pgbouncer.sh (initial render at container start)
#    - scripts/pgbouncer-autosync.sh (re-render when new DBs detected)
#
#  Inputs (env):
#    APP_DB_NAME (required)        — primary application database.
#    APP_DB_USER (required)        — used in [pgbouncer] stats/admin_users.
#    HAPROXY_HOST (default haproxy)
#    HAPROXY_WRITE_PORT (default 5000)
#    HAPROXY_READ_PORT (default 5001)
#    PGBOUNCER_POOL_MODE (default transaction)
#    PGBOUNCER_MAX_CLIENT_CONN (default 1000)
#    PGBOUNCER_DEFAULT_POOL_SIZE (default 80)
#    PGBOUNCER_RESERVE_POOL_SIZE (default 20)
#    EXTRA_DBS                     — space-separated list of additional DB
#                                    names; emits 3 aliases each
#                                    (<db>, <db>_rw, <db>_ro). Caller is
#                                    responsible for de-dup against
#                                    APP_DB_NAME and validation.
# =====================================================================
set -eu

: "${APP_DB_NAME:?APP_DB_NAME must be set}"
: "${APP_DB_USER:?APP_DB_USER must be set}"
: "${HAPROXY_HOST:=haproxy}"
: "${HAPROXY_WRITE_PORT:=5000}"
: "${HAPROXY_READ_PORT:=5001}"
: "${PGBOUNCER_POOL_MODE:=transaction}"
: "${PGBOUNCER_MAX_CLIENT_CONN:=1000}"
: "${PGBOUNCER_DEFAULT_POOL_SIZE:=80}"
: "${PGBOUNCER_RESERVE_POOL_SIZE:=20}"
: "${EXTRA_DBS:=}"

emit_db_block() {
  db="$1"
  printf '%s    = host=%s port=%s dbname=%s\n' "${db}"     "${HAPROXY_HOST}" "${HAPROXY_WRITE_PORT}" "${db}"
  printf '%s_rw = host=%s port=%s dbname=%s\n' "${db}"     "${HAPROXY_HOST}" "${HAPROXY_WRITE_PORT}" "${db}"
  printf '%s_ro = host=%s port=%s dbname=%s\n' "${db}"     "${HAPROXY_HOST}" "${HAPROXY_READ_PORT}"  "${db}"
}

cat <<EOF
[databases]
EOF
emit_db_block "${APP_DB_NAME}"

# Always route 'postgres' so admin/superuser can manage the cluster
# via PgBouncer (e.g. CREATE DATABASE from pgAdmin).
if [ "${APP_DB_NAME}" != "postgres" ]; then
  emit_db_block "postgres"
fi

# Track already-emitted DBs to dedupe (POSIX sh — no associative arrays).
EMITTED=" ${APP_DB_NAME} postgres "
for raw_db in ${EXTRA_DBS}; do
  db=$(echo "${raw_db}" | tr -d '[:space:]')
  [ -z "${db}" ] && continue
  case "${EMITTED}" in *" ${db} "*) continue ;; esac
  case "${db}" in
    *[!a-zA-Z0-9_]*)
      echo "[build-pgbouncer-ini] WARNING: skipping invalid DB name '${db}' (only [a-zA-Z0-9_] allowed)" >&2
      continue
      ;;
  esac
  EMITTED="${EMITTED}${db} "
  emit_db_block "${db}"
done

cat <<EOF

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432

auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt

pool_mode             = ${PGBOUNCER_POOL_MODE}
max_client_conn       = ${PGBOUNCER_MAX_CLIENT_CONN}
default_pool_size     = ${PGBOUNCER_DEFAULT_POOL_SIZE}
reserve_pool_size     = ${PGBOUNCER_RESERVE_POOL_SIZE}
reserve_pool_timeout  = 3
server_reset_query    = DISCARD ALL
server_check_query    = select 1
server_check_delay    = 30
server_lifetime       = 3600
server_idle_timeout   = 600
server_login_retry    = 5
client_idle_timeout   = 0
log_connections       = 0
log_disconnections    = 0
log_pooler_errors     = 1

ignore_startup_parameters = extra_float_digits,search_path,application_name,options

stats_users = ${APP_DB_USER}
admin_users = ${APP_DB_USER}

unix_socket_dir =
EOF
