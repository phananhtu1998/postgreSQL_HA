#!/bin/bash
# =====================================================================
#  pgBackRest restore — restore a node's data dir from a backup.
#  WARNING: this stops Patroni on the target node and reinitialises
#  PGDATA. Use only on replicas, or as part of full-cluster recovery.
# =====================================================================
set -euo pipefail

if [ -f .env ]; then set -a; . ./.env; set +a; fi

NODE="${1:-}"
TARGET="${2:-latest}"   # latest | <backup-set-name>
PGBACKREST_STANZA="${PGBACKREST_STANZA:-main}"
RESTORE_REPO="${RESTORE_REPO:-1}"

if [ -z "$NODE" ]; then
  echo "Usage: $0 <node>  [latest|<backup-set>]"
  echo "Example: $0 pg-2 latest"
  exit 1
fi

echo "[restore] target node = $NODE, set = $TARGET"
read -p "This will WIPE PGDATA on $NODE. Continue? [yes/NO] " yn
[ "$yn" = "yes" ] || { echo "aborted"; exit 1; }

echo "[restore] stopping Patroni on $NODE"
docker exec "$NODE" patronictl -c /etc/patroni/patroni.yml pause || true
docker exec "$NODE" pg_ctl -D /var/lib/patroni/pgdata stop -m fast || true

echo "[restore] running pgbackrest restore"
if [ "$TARGET" = "latest" ]; then
  docker exec -u postgres "$NODE" pgbackrest --stanza="$PGBACKREST_STANZA" --repo="$RESTORE_REPO" --delta restore
else
  docker exec -u postgres "$NODE" pgbackrest --stanza="$PGBACKREST_STANZA" --repo="$RESTORE_REPO" --set="$TARGET" --delta restore
fi

echo "[restore] starting Patroni on $NODE"
docker restart "$NODE"

echo "[restore] resuming cluster"
sleep 10
docker exec "$NODE" patronictl -c /etc/patroni/patroni.yml resume || true
docker exec "$NODE" patronictl -c /etc/patroni/patroni.yml list
