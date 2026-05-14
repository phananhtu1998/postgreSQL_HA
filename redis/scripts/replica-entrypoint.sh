#!/bin/sh
# Replica entrypoint — points at master, fail fast if vars unset.
set -eu

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set}"
: "${MASTER_HOST:=redis-master}"
: "${MASTER_PORT:=6379}"
: "${REDIS_MAXMEMORY:=512mb}"
: "${REPLICA_PRIORITY:=100}"
: "${REDIS_ANNOUNCE_IP:=}"
: "${REDIS_ANNOUNCE_PORT:=}"

EXTRA_ARGS=""
if [ -n "$REDIS_ANNOUNCE_IP" ]; then
  EXTRA_ARGS="$EXTRA_ARGS --replica-announce-ip $REDIS_ANNOUNCE_IP"
fi
if [ -n "$REDIS_ANNOUNCE_PORT" ]; then
  EXTRA_ARGS="$EXTRA_ARGS --replica-announce-port $REDIS_ANNOUNCE_PORT"
fi

exec redis-server /etc/redis/redis.conf \
  --requirepass     "$REDIS_PASSWORD" \
  --masterauth      "$REDIS_PASSWORD" \
  --replicaof       "$MASTER_HOST" "$MASTER_PORT" \
  --replica-priority "$REPLICA_PRIORITY" \
  --maxmemory       "$REDIS_MAXMEMORY" \
  $EXTRA_ARGS
