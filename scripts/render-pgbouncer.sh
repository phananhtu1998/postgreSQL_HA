#!/bin/sh
# =====================================================================
#  Render PgBouncer config + userlist at start time.
#
#  Note on auth strategy:
#    PgBouncer's `auth_query` cannot supply plaintext to authenticate
#    against a SCRAM-only backend (auth_query returns hashed SCRAM
#    secrets, which can't be used to compute a SCRAM client proof).
#    Therefore for SCRAM-only Postgres we put the app user's plaintext
#    in userlist.txt — that lets PgBouncer compute the SCRAM proof to
#    the backend, and clients still authenticate to PgBouncer over
#    encrypted SCRAM. The userlist is mode 600.
#
#  To add more application users, add them to APP_USERS_EXTRA in the
#  form "user1:pass1,user2:pass2".
# =====================================================================
set -eu

: "${APP_DB_NAME:?APP_DB_NAME must be set}"
: "${APP_DB_USER:?APP_DB_USER must be set}"
: "${APP_DB_PASSWORD:?APP_DB_PASSWORD must be set}"
: "${PG_HEALTHCHECK_USER:=health_chk}"
: "${PG_HEALTHCHECK_PASSWORD:?PG_HEALTHCHECK_PASSWORD must be set}"
: "${HAPROXY_HOST:=haproxy}"
: "${HAPROXY_WRITE_PORT:=5000}"
: "${HAPROXY_READ_PORT:=5001}"
: "${PGBOUNCER_POOL_MODE:=transaction}"
: "${PGBOUNCER_MAX_CLIENT_CONN:=1000}"
: "${PGBOUNCER_DEFAULT_POOL_SIZE:=80}"
: "${PGBOUNCER_RESERVE_POOL_SIZE:=20}"
: "${APP_USERS_EXTRA:=}"

mkdir -p /etc/pgbouncer

cat > /etc/pgbouncer/pgbouncer.ini <<EOF
[databases]
${APP_DB_NAME}    = host=${HAPROXY_HOST} port=${HAPROXY_WRITE_PORT} dbname=${APP_DB_NAME}
${APP_DB_NAME}_rw = host=${HAPROXY_HOST} port=${HAPROXY_WRITE_PORT} dbname=${APP_DB_NAME}
${APP_DB_NAME}_ro = host=${HAPROXY_HOST} port=${HAPROXY_READ_PORT}  dbname=${APP_DB_NAME}

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

{
  printf '"%s" "%s"\n' "${APP_DB_USER}"          "${APP_DB_PASSWORD}"
  printf '"%s" "%s"\n' "${PG_HEALTHCHECK_USER}"  "${PG_HEALTHCHECK_PASSWORD}"
  if [ -n "${APP_USERS_EXTRA}" ]; then
    echo "${APP_USERS_EXTRA}" | tr ',' '\n' | while IFS=':' read -r u p; do
      [ -n "$u" ] && [ -n "$p" ] && printf '"%s" "%s"\n' "$u" "$p"
    done
  fi
} > /etc/pgbouncer/userlist.txt

chmod 600 /etc/pgbouncer/pgbouncer.ini /etc/pgbouncer/userlist.txt

echo "[pgbouncer-entrypoint] config rendered for users: ${APP_DB_USER}, ${PG_HEALTHCHECK_USER}"
exec pgbouncer /etc/pgbouncer/pgbouncer.ini
