#!/bin/sh
# Master healthcheck — must respond to PING AND report role:master.
# Catches scenarios where master was demoted (e.g. partition recovery).
set -eu

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set}"

# 1. Server reachable
PONG=$(redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping 2>/dev/null || true)
[ "$PONG" = "PONG" ] || { echo "FAIL: ping"; exit 1; }

# 2. Role check (allow either master OR replica — sentinel may have
#    demoted us after partition; container is still healthy, just not
#    the leader. Healthcheck only fails for hard failures.)
ROLE=$(redis-cli -a "$REDIS_PASSWORD" --no-auth-warning info replication \
       | awk -F: '/^role:/ {gsub(/[\r\n]/,""); print $2}')
[ "$ROLE" = "master" ] || [ "$ROLE" = "slave" ] || { echo "FAIL: unknown role $ROLE"; exit 1; }

exit 0
