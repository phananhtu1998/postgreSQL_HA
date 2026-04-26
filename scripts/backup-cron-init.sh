#!/bin/sh
# =====================================================================
#  Backup scheduler container — installs cron jobs that exec
#  pgbackrest inside the current Patroni leader.
# =====================================================================
set -eu

: "${BACKUP_CRON_FULL:=0 2 * * 0}"
: "${BACKUP_CRON_INCR:=0 2 * * 1-6}"
: "${PATRONI_REST_USER:?}"
: "${PATRONI_REST_PASSWORD:?}"
: "${PATRONI_NODES:=pg-1,pg-2,pg-3}"
: "${PGBACKREST_STANZA:=main}"
: "${BACKUP_REPO:=1}"
: "${BACKUP_REPOS:=${BACKUP_REPO}}"

# Make env available to cron jobs
{
  echo "PATRONI_REST_USER=${PATRONI_REST_USER}"
  echo "PATRONI_REST_PASSWORD=${PATRONI_REST_PASSWORD}"
  echo "PATRONI_NODES=${PATRONI_NODES}"
  echo "PATRONI_REST_PORT=8008"
  echo "PGBACKREST_STANZA=${PGBACKREST_STANZA}"
  echo "BACKUP_REPO=${BACKUP_REPO}"
  echo "BACKUP_REPOS=${BACKUP_REPOS}"
} > /etc/backup.env

mkdir -p /var/log/backup

cat > /etc/periodic/backup-runner.sh <<'EOF'
#!/bin/sh
set -eu
. /etc/backup.env
TYPE="$1"

LEADER=""
for n in $(echo "$PATRONI_NODES" | tr ',' ' '); do
  STATE="$(curl -s -u "${PATRONI_REST_USER}:${PATRONI_REST_PASSWORD}" \
              "http://${n}:${PATRONI_REST_PORT}/" | jq -r .role 2>/dev/null || true)"
  [ "$STATE" = "primary" ] && LEADER="$n" && break
done

if [ -z "$LEADER" ]; then
  echo "$(date -u +%FT%TZ) [backup] no leader" >> /var/log/backup/backup.log
  exit 1
fi

for REPO in $(echo "$BACKUP_REPOS" | tr ',' ' '); do
  echo "$(date -u +%FT%TZ) [backup] type=$TYPE repo=$REPO leader=$LEADER" >> /var/log/backup/backup.log
  docker exec -u postgres "$LEADER" pgbackrest --stanza="$PGBACKREST_STANZA" --repo="$REPO" stanza-create \
    >> /var/log/backup/backup.log 2>&1 || true
  docker exec -u postgres "$LEADER" pgbackrest --stanza="$PGBACKREST_STANZA" --repo="$REPO" --type="$TYPE" backup \
    >> /var/log/backup/backup.log 2>&1
done
echo "$(date -u +%FT%TZ) [backup] done" >> /var/log/backup/backup.log
EOF
chmod +x /etc/periodic/backup-runner.sh

# Generate crontab
cat > /etc/crontabs/root <<EOF
${BACKUP_CRON_FULL} /etc/periodic/backup-runner.sh full
${BACKUP_CRON_INCR} /etc/periodic/backup-runner.sh incr
EOF

echo "[backup-init] schedules:"
echo "  full: ${BACKUP_CRON_FULL}"
echo "  incr: ${BACKUP_CRON_INCR}"
echo "  repos: ${BACKUP_REPOS}"
echo "[backup-init] starting crond"
touch /var/log/backup/backup.log
exec crond -f -d 8 -L /var/log/backup/cron.log
