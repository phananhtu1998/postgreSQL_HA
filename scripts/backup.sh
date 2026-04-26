#!/bin/bash
# =====================================================================
#  pgBackRest backup helper.
#  Run from the host: `make backup` or `make backup-full`.
#  Discovers the current Patroni leader via host-mapped REST ports,
#  then `docker exec`s pgbackrest into that container.
# =====================================================================
set -euo pipefail

if [ -f .env ]; then set -a; . ./.env; set +a; fi

: "${PATRONI_REST_USER:?}"
: "${PATRONI_REST_PASSWORD:?}"
: "${BACKUP_TYPE:=incr}"
: "${BACKUP_REPO:=1}"
: "${PGBACKREST_STANZA:=main}"

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
  echo "[backup] ERROR: no Patroni leader found" >&2
  exit 1
fi

echo "[backup] $(date -u +%FT%TZ) — type=$BACKUP_TYPE, repo=$BACKUP_REPO, leader=$LEADER, stanza=$PGBACKREST_STANZA"
docker exec -u postgres "$LEADER" pgbackrest --stanza="$PGBACKREST_STANZA" --repo="$BACKUP_REPO" stanza-create >/dev/null 2>&1 || true
docker exec -u postgres "$LEADER" pgbackrest --stanza="$PGBACKREST_STANZA" --repo="$BACKUP_REPO" --type="$BACKUP_TYPE" backup
echo "[backup] $(date -u +%FT%TZ) — done"
