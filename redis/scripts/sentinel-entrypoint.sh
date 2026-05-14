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
: "${SENTINEL_MASTER_NAME:=mymaster}"

SENTINEL_CONF="/data/sentinel.conf"

if [ ! -f "$SENTINEL_CONF" ]; then
  echo "[sentinel-entrypoint] Creating new sentinel.conf (master name: $SENTINEL_MASTER_NAME)"
  {
    echo "port 26379"
    echo "bind 0.0.0.0"
    echo "dir /data"
    echo ""
    echo "# Auth for sentinel itself (clients must AUTH to query/control it)"
    echo "requirepass $SENTINEL_PASSWORD"
    echo ""
    echo "# Master to monitor"
    echo "sentinel monitor $SENTINEL_MASTER_NAME redis-master 6379 $SENTINEL_QUORUM"
    echo "sentinel auth-pass $SENTINEL_MASTER_NAME $REDIS_PASSWORD"
    echo "sentinel down-after-milliseconds $SENTINEL_MASTER_NAME $SENTINEL_DOWN_AFTER_MS"
    echo "sentinel failover-timeout $SENTINEL_MASTER_NAME $SENTINEL_FAILOVER_TIMEOUT_MS"
    echo "sentinel parallel-syncs $SENTINEL_MASTER_NAME $SENTINEL_PARALLEL_SYNCS"
    echo ""
    echo "# DNS / hostname resolution"
    echo "sentinel resolve-hostnames yes"
    echo "sentinel announce-hostnames yes"
    if [ -n "$SENTINEL_ANNOUNCE_IP" ]; then
      echo "sentinel announce-ip $SENTINEL_ANNOUNCE_IP"
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
grep -vE "^(requirepass|user default|sentinel auth-pass $SENTINEL_MASTER_NAME|sentinel down-after-milliseconds $SENTINEL_MASTER_NAME|sentinel failover-timeout $SENTINEL_MASTER_NAME|sentinel parallel-syncs $SENTINEL_MASTER_NAME|sentinel resolve-hostnames|sentinel announce-hostnames|sentinel announce-ip|sentinel deny-scripts-reconfig)( |\$)" \
  "$SENTINEL_CONF" > "$TMP_CONF"
mv "$TMP_CONF" "$SENTINEL_CONF"

if ! grep -qE "^sentinel monitor $SENTINEL_MASTER_NAME " "$SENTINEL_CONF"; then
  echo "sentinel monitor $SENTINEL_MASTER_NAME redis-master 6379 $SENTINEL_QUORUM" >> "$SENTINEL_CONF"
fi

{
  echo ""
  echo "# Managed from environment"
  echo "requirepass $SENTINEL_PASSWORD"
  echo "sentinel auth-pass $SENTINEL_MASTER_NAME $REDIS_PASSWORD"
  echo "sentinel down-after-milliseconds $SENTINEL_MASTER_NAME $SENTINEL_DOWN_AFTER_MS"
  echo "sentinel failover-timeout $SENTINEL_MASTER_NAME $SENTINEL_FAILOVER_TIMEOUT_MS"
  echo "sentinel parallel-syncs $SENTINEL_MASTER_NAME $SENTINEL_PARALLEL_SYNCS"
  echo "sentinel resolve-hostnames yes"
  echo "sentinel announce-hostnames yes"
  if [ -n "$SENTINEL_ANNOUNCE_IP" ]; then
    echo "sentinel announce-ip $SENTINEL_ANNOUNCE_IP"
  fi
  echo "sentinel deny-scripts-reconfig yes"
} >> "$SENTINEL_CONF"

exec redis-sentinel "$SENTINEL_CONF"
