#!/bin/sh
# Sentinel healthcheck — PING + master is discoverable via this sentinel.
set -eu

: "${SENTINEL_PASSWORD:?SENTINEL_PASSWORD must be set}"
: "${SENTINEL_MASTER_NAME:=mymaster}"

# 1. Ping
PONG=$(redis-cli -p 26379 -a "$SENTINEL_PASSWORD" --no-auth-warning ping 2>/dev/null || true)
[ "$PONG" = "PONG" ] || { echo "FAIL: ping"; exit 1; }

# 2. Sentinel must not be running with an unauthenticated default user.
ACL=$(redis-cli -p 26379 -a "$SENTINEL_PASSWORD" --no-auth-warning ACL LIST 2>/dev/null || true)
echo "$ACL" | grep -qE '^user default .*nopass' && { echo "FAIL: sentinel auth disabled"; exit 1; }

# 3. Sentinel knows about master
ADDR=$(redis-cli -p 26379 -a "$SENTINEL_PASSWORD" --no-auth-warning \
       sentinel get-master-addr-by-name "$SENTINEL_MASTER_NAME" 2>/dev/null | head -n1 || true)
[ -n "$ADDR" ] || { echo "FAIL: master not discovered"; exit 1; }

exit 0
