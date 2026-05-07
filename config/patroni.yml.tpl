# =====================================================================
#  Patroni configuration template — rendered per-node by entrypoint.
#  All ${VAR} are substituted via envsubst at container start.
# =====================================================================
scope: "${PATRONI_SCOPE}"
name: "${PATRONI_NAME}"
namespace: /service/

restapi:
  listen: 0.0.0.0:8008
  connect_address: "${PATRONI_NAME}:8008"
  authentication:
    username: "${PATRONI_REST_USER}"
    password: "${PATRONI_REST_PASSWORD}"

etcd3:
  hosts: "${ETCD_HOSTS}"
  protocol: http

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576           # 1 MB max replica lag to be promotable
    master_start_timeout: 300
    synchronous_mode: false                     # turn on for zero-data-loss
    synchronous_mode_strict: false
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        hot_standby_feedback: "on"
        wal_keep_size: 1024MB
        max_wal_senders: 10
        max_replication_slots: 10
        wal_log_hints: "on"
        archive_mode: "on"
        archive_command: "pgbackrest --stanza=${PGBACKREST_STANZA:-main} archive-push %p || true"
        archive_timeout: 60
        max_connections: 300
        shared_buffers: 1GB
        effective_cache_size: 3GB
        work_mem: 8MB
        maintenance_work_mem: 256MB
        wal_compression: "on"
        checkpoint_timeout: 15min
        checkpoint_completion_target: 0.9
        random_page_cost: 1.1
        log_min_duration_statement: 1000
        log_lock_waits: "on"
        log_temp_files: "0"
        log_checkpoints: "on"
        shared_preload_libraries: 'pg_stat_statements'
        track_io_timing: "on"
        default_statistics_target: 100
        password_encryption: scram-sha-256

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - host  replication  replicator  0.0.0.0/0  scram-sha-256
    - host  all          all         0.0.0.0/0  scram-sha-256
    - local all          all                    trust

  users:
    "${PATRONI_SUPERUSER_NAME}":
      password: "${PATRONI_SUPERUSER_PASSWORD}"
      options:
        - createrole
        - createdb
    "${PATRONI_REPLICATION_USERNAME}":
      password: "${PATRONI_REPLICATION_PASSWORD}"
      options:
        - replication

  post_init: /usr/local/bin/post-init.sh

postgresql:
  listen: 0.0.0.0:5432
  connect_address: "${PATRONI_NAME}:5432"
  data_dir: /var/lib/patroni/pgdata
  bin_dir: /usr/lib/postgresql/17/bin
  pgpass: /tmp/pgpass0
  authentication:
    superuser:
      username: "${PATRONI_SUPERUSER_NAME}"
      password: "${PATRONI_SUPERUSER_PASSWORD}"
    replication:
      username: "${PATRONI_REPLICATION_USERNAME}"
      password: "${PATRONI_REPLICATION_PASSWORD}"
    rewind:
      username: "${PATRONI_REPLICATION_USERNAME}"
      password: "${PATRONI_REPLICATION_PASSWORD}"
  parameters:
    unix_socket_directories: '/var/run/postgresql'

  create_replica_methods:
    - basebackup
  basebackup:
    max-rate: 100M
    checkpoint: fast

watchdog:
  mode: off

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
