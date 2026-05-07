#!/bin/bash
# =====================================================================
#  Create / update DBA superuser on an EXISTING running cluster.
#
#  Why this script exists:
#    `post-init.sh` is a Patroni `bootstrap.post_init` hook — it runs
#    ONCE on the very first primary after `initdb`. If you add the
#    ADMIN_DB_USER / ADMIN_DB_PASSWORD variables to `.env` AFTER the
#    cluster was already initialised (or you want to rotate the admin
#    password), `post-init.sh` will not run again. This script is the
#    idempotent replacement.
#
#  Usage from host:
#    make create-admin
#  or directly:
#    bash scripts/create-admin.sh
#
#  Inputs (env / .env):
#    ADMIN_DB_USER          (required) e.g. admin
#    ADMIN_DB_PASSWORD      (required) e.g. 123 (dev only — use strong in prod)
#    PATRONI_REST_USER      (required, to discover leader)
#    PATRONI_REST_PASSWORD  (required)
#    PATRONI_SUPERUSER_NAME (default postgres) — used for the psql exec
#    PATRONI_1/2/3_REST_PORT (defaults 8011/8012/8013)
# =====================================================================
set -euo pipefail

if [ -f .env ]; then set -a; . ./.env; set +a; fi

: "${ADMIN_DB_USER:?ADMIN_DB_USER must be set in .env}"
: "${ADMIN_DB_PASSWORD:?ADMIN_DB_PASSWORD must be set in .env}"
: "${PATRONI_REST_USER:?PATRONI_REST_USER must be set in .env}"
: "${PATRONI_REST_PASSWORD:?PATRONI_REST_PASSWORD must be set in .env}"
: "${PATRONI_SUPERUSER_NAME:=postgres}"

# Block dangerous role names that could break the cluster.
case "${ADMIN_DB_USER}" in
  postgres|replicator|patroni_rest|health_chk|pgbouncer_auth)
    echo "[create-admin] ERROR: ADMIN_DB_USER='${ADMIN_DB_USER}' collides with a reserved/cluster role" >&2
    exit 1 ;;
esac
case "${ADMIN_DB_USER}" in
  *[!a-zA-Z0-9_]*)
    echo "[create-admin] ERROR: ADMIN_DB_USER must match [a-zA-Z0-9_] (got '${ADMIN_DB_USER}')" >&2
    exit 1 ;;
esac

declare -A REST_PORT=(
  [pg-1]="${PATRONI_1_REST_PORT:-8011}"
  [pg-2]="${PATRONI_2_REST_PORT:-8012}"
  [pg-3]="${PATRONI_3_REST_PORT:-8013}"
)

LEADER=""
for n in pg-1 pg-2 pg-3; do
  role=$(curl -s --max-time 3 -u "${PATRONI_REST_USER}:${PATRONI_REST_PASSWORD}" \
              "http://localhost:${REST_PORT[$n]}/patroni" \
         | jq -r '.role // empty' 2>/dev/null || true)
  if [ "$role" = "primary" ]; then
    LEADER="$n"
    break
  fi
done

if [ -z "$LEADER" ]; then
  echo "[create-admin] ERROR: no Patroni leader found via REST API on ports" \
       "${REST_PORT[pg-1]}/${REST_PORT[pg-2]}/${REST_PORT[pg-3]}." \
       "Is the cluster up? Try: make patroni-list" >&2
  exit 1
fi

echo "[create-admin] leader=${LEADER}, role=${ADMIN_DB_USER} (SUPERUSER CREATEDB CREATEROLE LOGIN)"

# Run inside the leader container via local unix-socket trust to avoid
# leaking PATRONI_SUPERUSER_PASSWORD on the command line.
docker exec -i -e PGOPTIONS='-c client_min_messages=warning' \
  -e ADMIN_DB_USER="${ADMIN_DB_USER}" \
  -e ADMIN_DB_PASSWORD="${ADMIN_DB_PASSWORD}" \
  -e PATRONI_SUPERUSER_NAME="${PATRONI_SUPERUSER_NAME}" \
  "${LEADER}" \
  bash -se <<'INNER'
set -euo pipefail
psql -v ON_ERROR_STOP=1 \
     --username "${PATRONI_SUPERUSER_NAME}" \
     --dbname postgres <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${ADMIN_DB_USER}') THEN
        CREATE ROLE ${ADMIN_DB_USER}
            WITH LOGIN SUPERUSER CREATEDB CREATEROLE
            PASSWORD '${ADMIN_DB_PASSWORD}';
        RAISE NOTICE 'created role ${ADMIN_DB_USER}';
    ELSE
        ALTER ROLE ${ADMIN_DB_USER}
            WITH LOGIN SUPERUSER CREATEDB CREATEROLE
            PASSWORD '${ADMIN_DB_PASSWORD}';
        RAISE NOTICE 'updated role ${ADMIN_DB_USER}';
    END IF;
END
\$\$;
SQL
INNER

# Reload pgbouncer so the new admin entry in userlist.txt (if pgbouncer
# was restarted with the new env) is picked up — safe no-op otherwise.
if docker ps --format '{{.Names}}' | grep -q '^pg-pgbouncer$'; then
  docker exec pg-pgbouncer sh -c \
    'pgrep -x pgbouncer >/dev/null && kill -HUP $(pgrep -x pgbouncer)' \
    >/dev/null 2>&1 || true
fi

echo "[create-admin] done. Login pgAdmin với:"
echo "                Host: pgbouncer (trong Docker) hoặc localhost (host máy)"
echo "                Port: 6432 (qua PgBouncer) hoặc 5000 (HAProxy write)"
echo "                User: ${ADMIN_DB_USER}"
echo "                DB:   postgres"
