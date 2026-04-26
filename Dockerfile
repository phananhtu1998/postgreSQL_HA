# =====================================================================
#  PostgreSQL 17 + Patroni + pgBackRest — production HA image
#
#  Cross-platform: scripts/configs are baked in via COPY + dos2unix so
#  the stack runs identically on Linux / macOS / Windows Docker Desktop.
# =====================================================================
FROM postgres:17.2-bookworm

ENV DEBIAN_FRONTEND=noninteractive

# Install Patroni + etcd client + pgBackRest + utilities
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-venv \
      python3-psycopg2 python3-prettytable python3-yaml \
      curl ca-certificates jq gettext-base dos2unix tini \
      pgbackrest \
      gosu \
 && rm -rf /var/lib/apt/lists/*

# Install Patroni in an isolated venv (Debian 12 marks system Python as
# externally-managed; venv keeps things tidy and PEP 668 compliant).
RUN python3 -m venv --system-site-packages /opt/patroni-venv \
 && /opt/patroni-venv/bin/pip install --no-cache-dir \
      "patroni[etcd3]==4.0.4" \
      "psycopg2-binary>=2.9" \
 && ln -s /opt/patroni-venv/bin/patroni    /usr/local/bin/patroni \
 && ln -s /opt/patroni-venv/bin/patronictl /usr/local/bin/patronictl

# ── Bake configs and scripts ────────────────────────────────────────
COPY config/  /etc/patroni-templates/
COPY scripts/ /usr/local/bin/

# Strip CRLF defensively + chmod
RUN dos2unix /etc/patroni-templates/* /usr/local/bin/*.sh 2>/dev/null \
 && chmod +x /usr/local/bin/*.sh

# pgBackRest paths
RUN mkdir -p /var/lib/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest \
 && chown -R postgres:postgres /var/lib/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest

# Patroni data dir
RUN mkdir -p /var/lib/patroni \
 && chown -R postgres:postgres /var/lib/patroni

# Expose Patroni REST API + Postgres
EXPOSE 5432 8008

ENTRYPOINT ["/usr/bin/tini", "--"]
