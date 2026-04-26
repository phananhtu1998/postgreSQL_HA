#!/bin/bash
# =====================================================================
#  Patroni entrypoint — fail-fast on missing required env vars,
#  render config from template, hand off to patroni.
# =====================================================================
set -euo pipefail

: "${PATRONI_NAME:?PATRONI_NAME must be set}"
: "${PATRONI_SCOPE:?PATRONI_SCOPE must be set}"
: "${ETCD_HOSTS:?ETCD_HOSTS must be set (comma-separated etcd endpoints)}"
: "${PATRONI_SUPERUSER_NAME:?PATRONI_SUPERUSER_NAME must be set}"
: "${PATRONI_SUPERUSER_PASSWORD:?PATRONI_SUPERUSER_PASSWORD must be set}"
: "${PATRONI_REPLICATION_USERNAME:?PATRONI_REPLICATION_USERNAME must be set}"
: "${PATRONI_REPLICATION_PASSWORD:?PATRONI_REPLICATION_PASSWORD must be set}"
: "${PATRONI_REST_USER:?PATRONI_REST_USER must be set}"
: "${PATRONI_REST_PASSWORD:?PATRONI_REST_PASSWORD must be set}"
: "${APP_DB_NAME:?APP_DB_NAME must be set}"
: "${APP_DB_USER:?APP_DB_USER must be set}"
: "${APP_DB_PASSWORD:?APP_DB_PASSWORD must be set}"
: "${PG_HEALTHCHECK_USER:=health_chk}"
: "${PG_HEALTHCHECK_PASSWORD:?PG_HEALTHCHECK_PASSWORD must be set}"
: "${PGBACKREST_STANZA:=main}"
: "${PGBACKREST_S3_ENDPOINT:=}"
: "${PGBACKREST_S3_BUCKET:=}"
: "${PGBACKREST_S3_REGION:=us-east-1}"
: "${PGBACKREST_S3_KEY:=}"
: "${PGBACKREST_S3_KEY_SECRET:=}"
: "${PGBACKREST_S3_PATH:=/pgbackrest}"
: "${PGBACKREST_S3_URI_STYLE:=path}"
: "${PGBACKREST_S3_VERIFY_TLS:=n}"

# Render config from template
CONFIG_FILE=/etc/patroni/patroni.yml
mkdir -p /etc/patroni
envsubst < /etc/patroni-templates/patroni.yml.tpl > "$CONFIG_FILE"
chown -R postgres:postgres /etc/patroni /var/lib/patroni
chmod 600 "$CONFIG_FILE"

# Ensure postgres run dir
mkdir -p /var/run/postgresql
chown postgres:postgres /var/run/postgresql

# pgBackRest configuration (for archive_command + restore)
mkdir -p /etc/pgbackrest
cat > /etc/pgbackrest/pgbackrest.conf <<EOF
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=2
repo1-retention-diff=4
log-level-console=warn
log-level-file=info
process-max=2
compress-type=zst
compress-level=3
start-fast=y
EOF

if [ -n "$PGBACKREST_S3_ENDPOINT" ]; then
  : "${PGBACKREST_S3_BUCKET:?PGBACKREST_S3_BUCKET must be set when PGBACKREST_S3_ENDPOINT is set}"
  : "${PGBACKREST_S3_KEY:?PGBACKREST_S3_KEY must be set when PGBACKREST_S3_ENDPOINT is set}"
  : "${PGBACKREST_S3_KEY_SECRET:?PGBACKREST_S3_KEY_SECRET must be set when PGBACKREST_S3_ENDPOINT is set}"

  cat >> /etc/pgbackrest/pgbackrest.conf <<EOF
repo2-type=s3
repo2-s3-endpoint=${PGBACKREST_S3_ENDPOINT}
repo2-s3-bucket=${PGBACKREST_S3_BUCKET}
repo2-s3-region=${PGBACKREST_S3_REGION}
repo2-s3-key=${PGBACKREST_S3_KEY}
repo2-s3-key-secret=${PGBACKREST_S3_KEY_SECRET}
repo2-s3-uri-style=${PGBACKREST_S3_URI_STYLE}
repo2-s3-verify-tls=${PGBACKREST_S3_VERIFY_TLS}
repo2-path=${PGBACKREST_S3_PATH}
repo2-retention-full=2
repo2-retention-diff=4
EOF
fi

cat >> /etc/pgbackrest/pgbackrest.conf <<EOF

[${PGBACKREST_STANZA}]
pg1-path=/var/lib/patroni/pgdata
pg1-port=5432
pg1-user=${PATRONI_SUPERUSER_NAME}
pg1-database=postgres
EOF
chown -R postgres:postgres /etc/pgbackrest /var/lib/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest

echo "[patroni-entrypoint] Starting Patroni node '${PATRONI_NAME}' (scope=${PATRONI_SCOPE}, etcd=${ETCD_HOSTS})"
exec gosu postgres patroni "$CONFIG_FILE"
