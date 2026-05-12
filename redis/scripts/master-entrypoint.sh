#!/bin/sh
# Master entrypoint — fail fast if password is unset.
set -eu

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set}"
: "${REDIS_MAXMEMORY:=512mb}"

exec redis-server /etc/redis/redis.conf \
  --requirepass "$REDIS_PASSWORD" \
  --masterauth  "$REDIS_PASSWORD" \
  --maxmemory   "$REDIS_MAXMEMORY"
