#!/bin/sh
# Replica healthcheck — PING + replica is connected to master + lag is
# acceptable. If lag exceeds threshold, replica is considered unhealthy.
set -eu

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set}"
LAG_THRESHOLD_SECS="${LAG_THRESHOLD_SECS:-30}"

# 1. Ping
PONG=$(redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping 2>/dev/null || true)
[ "$PONG" = "PONG" ] || { echo "FAIL: ping"; exit 1; }

# 2. Pull replication info
INFO=$(redis-cli -a "$REDIS_PASSWORD" --no-auth-warning info replication 2>/dev/null)

ROLE=$(echo "$INFO" | awk -F: '/^role:/ {gsub(/[\r\n]/,""); print $2}')

# If this node has been promoted to master (during failover), still
# report healthy — it's now the new master.
if [ "$ROLE" = "master" ]; then
  exit 0
fi

# 3. Replica must be linked to master
LINK=$(echo "$INFO" | awk -F: '/^master_link_status:/ {gsub(/[\r\n]/,""); print $2}')
[ "$LINK" = "up" ] || { echo "FAIL: master_link_status=$LINK"; exit 1; }

# 4. Last I/O recent enough
LAST_IO=$(echo "$INFO" | awk -F: '/^master_last_io_seconds_ago:/ {gsub(/[\r\n]/,""); print $2}')
LAST_IO=${LAST_IO:-9999}
[ "$LAST_IO" -le "$LAG_THRESHOLD_SECS" ] || { echo "FAIL: master_last_io_seconds_ago=$LAST_IO"; exit 1; }

exit 0
