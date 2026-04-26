#!/bin/bash
# =====================================================================
#  Patroni bootstrap.post_init hook — runs ONCE on the very first
#  primary after initdb. Creates the application database, app user,
#  health-check user, and PgBouncer auth helper.
# =====================================================================
set -euo pipefail

# Patroni passes the connection URL as $1; we use unix socket via local trust.
psql -v ON_ERROR_STOP=1 --username "${PATRONI_SUPERUSER_NAME}" --dbname postgres <<-EOSQL
    -- Application database & owner
    CREATE ROLE ${APP_DB_USER} WITH LOGIN PASSWORD '${APP_DB_PASSWORD}';
    CREATE DATABASE ${APP_DB_NAME} OWNER ${APP_DB_USER};
    ALTER ROLE ${APP_DB_USER} CONNECTION LIMIT 250;

    -- Health-check role used by HAProxy probes (read-only)
    CREATE ROLE ${PG_HEALTHCHECK_USER} WITH LOGIN PASSWORD '${PG_HEALTHCHECK_PASSWORD}';
    GRANT pg_read_all_stats TO ${PG_HEALTHCHECK_USER};

    -- PgBouncer auth user + lookup function (lets PgBouncer relay SCRAM)
    CREATE ROLE pgbouncer_auth WITH LOGIN PASSWORD '${APP_DB_PASSWORD}';
EOSQL

# auth_query function lives in every database PgBouncer talks to.
for db in postgres "${APP_DB_NAME}"; do
  psql -v ON_ERROR_STOP=1 --username "${PATRONI_SUPERUSER_NAME}" --dbname "$db" <<-EOSQL
        CREATE OR REPLACE FUNCTION public.pgbouncer_get_auth(p_usename TEXT)
        RETURNS TABLE(usename name, passwd text)
        LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog AS \$\$
            SELECT usename, passwd FROM pg_shadow WHERE usename = p_usename;
        \$\$;
        REVOKE ALL ON FUNCTION public.pgbouncer_get_auth(TEXT) FROM PUBLIC;
        GRANT EXECUTE ON FUNCTION public.pgbouncer_get_auth(TEXT) TO pgbouncer_auth;

        -- pg_stat_statements is preloaded; create the extension.
        CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
EOSQL
done

# Initialise pgBackRest stanza on first primary (idempotent)
pgbackrest --stanza="${PGBACKREST_STANZA:-main}" --repo=1 stanza-create || true
pgbackrest --stanza="${PGBACKREST_STANZA:-main}" --repo=1 check          || true
if [ -n "${PGBACKREST_S3_ENDPOINT:-}" ]; then
  pgbackrest --stanza="${PGBACKREST_STANZA:-main}" --repo=2 stanza-create || true
  pgbackrest --stanza="${PGBACKREST_STANZA:-main}" --repo=2 check          || true
fi

echo "[post-init] bootstrap finished for $(hostname)"
