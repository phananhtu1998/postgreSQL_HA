#!/bin/bash
# =====================================================================
#  Automated Patroni failover chaos test.
#    1. Discover current leader via Patroni REST.
#    2. Pause it (simulates crash/network partition).
#    3. Wait for a replica to be promoted.
#    4. Verify the new leader accepts writes.
#    5. Unpause the old leader.
#    6. Verify it rejoins as a streaming replica.
# =====================================================================
set -euo pipefail

# Load .env
if [ -f .env ]; then set -a; . ./.env; set +a; fi

NODES=(pg-1 pg-2 pg-3)
PATRONI_REST_AUTH="${PATRONI_REST_USER:-patroni_rest}:${PATRONI_REST_PASSWORD:?}"

bold() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓ %s\033[0m\n' "$*"; }
fail() { printf '  \033[31m✗ %s\033[0m\n' "$*"; exit 1; }

role_of() {
  curl -s --max-time 3 -u "$PATRONI_REST_AUTH" "http://localhost:$(node_rest_port "$1")/patroni" \
    | jq -r '.role // empty' 2>/dev/null
}

discover_leader() {
  for n in "${NODES[@]}"; do
    if [ "$(role_of "$n" || true)" = "primary" ]; then
      echo "$n"
      return 0
    fi
  done
  return 1
}

node_rest_port() {
  case "$1" in
    pg-1) echo "${PATRONI_1_REST_PORT:-8011}";;
    pg-2) echo "${PATRONI_2_REST_PORT:-8012}";;
    pg-3) echo "${PATRONI_3_REST_PORT:-8013}";;
  esac
}

bold "Discovering current leader"
LEADER=$(discover_leader) || fail "no leader found"
ok "leader = $LEADER"

bold "Writing a sentinel row through HAProxy:5000"
docker run --rm --network pg-ha -e PGPASSWORD="$APP_DB_PASSWORD" postgres:17.2-bookworm \
  psql -h pg-haproxy -p 5000 -U "$APP_DB_USER" -d "$APP_DB_NAME" -tAc \
  "CREATE TABLE IF NOT EXISTS failover_test(t TEXT); INSERT INTO failover_test VALUES ('pre-failover-' || now());" \
  || fail "could not write sentinel row"
ok "wrote sentinel row"

bold "Pausing leader '$LEADER' (simulates crash)"
docker pause "$LEADER" >/dev/null
ok "$LEADER paused"

bold "Waiting up to 90s for a new leader to be elected"
NEW_LEADER=""
for i in $(seq 1 30); do
  for n in "${NODES[@]}"; do
    [ "$n" = "$LEADER" ] && continue
    if [ "$(role_of "$n" || true)" = "primary" ]; then
      NEW_LEADER="$n"
      break 2
    fi
  done
  sleep 3
done
[ -n "$NEW_LEADER" ] || { docker unpause "$LEADER" >/dev/null; fail "no new leader elected after 90s"; }
ok "new leader = $NEW_LEADER"

bold "Verifying HAProxy converges + new leader accepts writes (up to 30s)"
WROTE=0
for i in $(seq 1 10); do
  if docker run --rm --network pg-ha -e PGPASSWORD="$APP_DB_PASSWORD" postgres:17.2-bookworm \
       psql -h pg-haproxy -p 5000 -U "$APP_DB_USER" -d "$APP_DB_NAME" -tAc \
       "INSERT INTO failover_test VALUES ('post-failover-' || now());" 2>/dev/null; then
    WROTE=1; break
  fi
  sleep 3
done
[ "$WROTE" = "1" ] || fail "new leader rejected writes for >30s"
ok "new leader accepted write"

bold "Unpausing old leader '$LEADER'"
docker unpause "$LEADER" >/dev/null
ok "$LEADER unpaused"

bold "Waiting up to 60s for old leader to rejoin as replica"
role=""
for i in $(seq 1 20); do
  role="$(role_of "$LEADER" || true)"
  if [ "$role" = "replica" ] || [ "$role" = "standby_leader" ]; then
    ok "$LEADER rejoined as $role"
    break
  fi
  sleep 3
done
[ "$role" = "replica" ] || [ "$role" = "standby_leader" ] || fail "$LEADER did not rejoin (final role=$role)"

bold "Final cluster state:"
docker exec "$NEW_LEADER" patronictl -c /etc/patroni/patroni.yml list || true

printf '\n\033[1;32mFailover test PASSED\033[0m\n'
