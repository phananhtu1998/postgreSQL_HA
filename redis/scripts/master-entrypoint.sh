#!/bin/sh
# Master entrypoint — fail fast if password is unset.
set -eu

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set}"
: "${REDIS_MAXMEMORY:=512mb}"
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
  --requirepass "$REDIS_PASSWORD" \
  --masterauth  "$REDIS_PASSWORD" \
  --maxmemory   "$REDIS_MAXMEMORY" \
  $EXTRA_ARGS
