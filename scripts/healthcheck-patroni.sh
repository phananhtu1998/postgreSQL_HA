#!/bin/sh
# Container-level healthcheck. We just verify the Patroni REST API is up
# (any 2xx OR 503 reply means patroni itself is alive — 503 just means
# the node is currently a replica, which is healthy at the container level).
set -eu

CODE="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8008/health || echo '000')"
case "$CODE" in
  200|503) exit 0 ;;
  *)       exit 1 ;;
esac
