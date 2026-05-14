#!/bin/sh
# Sentinel entrypoint — bootstraps writable sentinel.conf in /data on
# first boot, then preserves it across restarts so failover state
# survives container recreation.
set -eu

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set}"
: "${SENTINEL_PASSWORD:?SENTINEL_PASSWORD must be set}"

: "${SENTINEL_QUORUM:=2}"
: "${SENTINEL_DOWN_AFTER_MS:=5000}"
: "${SENTINEL_FAILOVER_TIMEOUT_MS:=30000}"
: "${SENTINEL_PARALLEL_SYNCS:=1}"
: "${SENTINEL_ANNOUNCE_IP:=}"
: "${SENTINEL_ANNOUNCE_PORT:=}"

: "${REDIS_MASTER_ANNOUNCE_IP:=}"
: "${REDIS_MASTER_ANNOUNCE_PORT:=6379}"

# Determine master address for sentinel monitor:
# If REDIS_MASTER_ANNOUNCE_IP is set (external client scenario), sentinel
# monitors master via external IP:port so it reports the correct address
# to clients outside Docker. Otherwise use Docker hostname.
if [ -n "$REDIS_MASTER_ANNOUNCE_IP" ]; then
  MONITOR_HOST="$REDIS_MASTER_ANNOUNCE_IP"
  MONITOR_PORT="$REDIS_MASTER_ANNOUNCE_PORT"
else
  MONITOR_HOST="redis-master"
  MONITOR_PORT="6379"
fi

SENTINEL_CONF="/data/sentinel.conf"

if [ ! -f "$SENTINEL_CONF" ]; then
  echo "[sentinel-entrypoint] Creating new sentinel.conf"
  {
    echo "port 26379"
    echo "bind 0.0.0.0"
    echo "dir /data"
    echo ""
    echo "# Auth for sentinel itself (clients must AUTH to query/control it)"
    echo "requirepass $SENTINEL_PASSWORD"
    echo ""
    echo "# Master to monitor"
    echo "sentinel monitor mymaster $MONITOR_HOST $MONITOR_PORT $SENTINEL_QUORUM"
    echo "sentinel auth-pass mymaster $REDIS_PASSWORD"
    echo "sentinel down-after-milliseconds mymaster $SENTINEL_DOWN_AFTER_MS"
    echo "sentinel failover-timeout mymaster $SENTINEL_FAILOVER_TIMEOUT_MS"
    echo "sentinel parallel-syncs mymaster $SENTINEL_PARALLEL_SYNCS"
    echo ""
    echo "# DNS / hostname resolution"
    echo "sentinel resolve-hostnames yes"
    if [ -n "$SENTINEL_ANNOUNCE_IP" ]; then
      echo "sentinel announce-hostnames no"
      echo "sentinel announce-ip $SENTINEL_ANNOUNCE_IP"
    else
      echo "sentinel announce-hostnames yes"
    fi
    if [ -n "$SENTINEL_ANNOUNCE_PORT" ]; then
      echo "sentinel announce-port $SENTINEL_ANNOUNCE_PORT"
    fi
    echo ""
    echo "# Hardening"
    echo "sentinel deny-scripts-reconfig yes"
    echo ""
    echo "loglevel notice"
    echo 'logfile ""'
  } > "$SENTINEL_CONF"
else
  echo "[sentinel-entrypoint] Reusing existing sentinel.conf"
fi

TMP_CONF="${SENTINEL_CONF}.tmp"
grep -vE '^(requirepass|user default|sentinel auth-pass mymaster|sentinel down-after-milliseconds mymaster|sentinel failover-timeout mymaster|sentinel parallel-syncs mymaster|sentinel resolve-hostnames|sentinel announce-hostnames|sentinel announce-ip|sentinel announce-port|sentinel deny-scripts-reconfig)( |$)' \
  "$SENTINEL_CONF" > "$TMP_CONF"
mv "$TMP_CONF" "$SENTINEL_CONF"

if ! grep -qE '^sentinel monitor mymaster ' "$SENTINEL_CONF"; then
  echo "sentinel monitor mymaster $MONITOR_HOST $MONITOR_PORT $SENTINEL_QUORUM" >> "$SENTINEL_CONF"
fi

{
  echo ""
  echo "# Managed from environment"
  echo "requirepass $SENTINEL_PASSWORD"
  echo "sentinel auth-pass mymaster $REDIS_PASSWORD"
  echo "sentinel down-after-milliseconds mymaster $SENTINEL_DOWN_AFTER_MS"
  echo "sentinel failover-timeout mymaster $SENTINEL_FAILOVER_TIMEOUT_MS"
  echo "sentinel parallel-syncs mymaster $SENTINEL_PARALLEL_SYNCS"
  echo "sentinel resolve-hostnames yes"
  if [ -n "$SENTINEL_ANNOUNCE_IP" ]; then
    echo "sentinel announce-hostnames no"
    echo "sentinel announce-ip $SENTINEL_ANNOUNCE_IP"
  else
    echo "sentinel announce-hostnames yes"
  fi
  if [ -n "$SENTINEL_ANNOUNCE_PORT" ]; then
    echo "sentinel announce-port $SENTINEL_ANNOUNCE_PORT"
  fi
  echo "sentinel deny-scripts-reconfig yes"
} >> "$SENTINEL_CONF"

exec redis-sentinel "$SENTINEL_CONF"
