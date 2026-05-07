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
#
#  To route additional databases through PgBouncer (write via HAProxy
#  port 5000, read via 5001), set APP_DBS_EXTRA="db1,db2,..." in .env.
#  The DBs must already exist on Postgres (CREATE DATABASE on leader).
#  Each entry generates 3 PgBouncer aliases: <db>, <db>_rw, <db>_ro.
#
#  For automatic discovery (no need to edit APP_DBS_EXTRA every time),
#  enable the pgbouncer-autosync sidecar — it polls pg_database and
#  re-renders this file at runtime via the same build-pgbouncer-ini.sh
#  helper.
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
: "${APP_DBS_EXTRA:=}"

mkdir -p /etc/pgbouncer

# Convert comma-separated APP_DBS_EXTRA → space-separated EXTRA_DBS for
# build-pgbouncer-ini.sh. Validation/dedup is done inside the helper.
EXTRA_DBS=$(echo "${APP_DBS_EXTRA}" | tr ',' ' ')
export APP_DB_NAME APP_DB_USER HAPROXY_HOST HAPROXY_WRITE_PORT HAPROXY_READ_PORT \
       PGBOUNCER_POOL_MODE PGBOUNCER_MAX_CLIENT_CONN \
       PGBOUNCER_DEFAULT_POOL_SIZE PGBOUNCER_RESERVE_POOL_SIZE EXTRA_DBS

sh /usr/local/bin/build-pgbouncer-ini.sh > /etc/pgbouncer/pgbouncer.ini

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

# Echo the database aliases that ended up rendered (for visibility in logs).
# Only parse the [databases] section so we don't pick up keys from [pgbouncer].
RENDERED_DBS=$(awk '
  /^\[pgbouncer\]/ { exit }
  /^\[databases\]/ { in_db=1; next }
  in_db && /^[a-zA-Z0-9_]+ +=/ {
    name=$1
    if (name ~ /_(rw|ro)$/) next
    print name
  }
' /etc/pgbouncer/pgbouncer.ini | tr '\n' ' ')
echo "[pgbouncer-entrypoint] config rendered for users: ${APP_DB_USER}, ${PG_HEALTHCHECK_USER}"
echo "[pgbouncer-entrypoint] databases routed (each with _rw/_ro alias): ${RENDERED_DBS}"
exec pgbouncer /etc/pgbouncer/pgbouncer.ini
