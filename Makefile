# =====================================================================
#  PostgreSQL HA — operations shortcuts.
# =====================================================================

COMPOSE       ?= docker compose
COMPOSE_CORE  := -f docker-compose.yml
COMPOSE_MON   := -f docker-compose.monitoring.yml
COMPOSE_BAK   := -f docker-compose.backup.yml
COMPOSE_DEV   := -f docker-compose.dev.yml
COMPOSE_MINIO := -f docker-compose.minio.yml

ALL = $(COMPOSE) $(COMPOSE_CORE) $(COMPOSE_MON) $(COMPOSE_BAK) $(COMPOSE_DEV) $(COMPOSE_MINIO)

.PHONY: help up up-monitoring up-backup up-dev up-all down down-all status logs \
        ps build rebuild patroni-list failover-test backup backup-full restore \
        psql-write psql-read clean nuke up-minio backup-s3 restore-s3 minio-console \
        create-admin

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS=":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

up: ## Start core stack (etcd × 3 + Patroni × 3 + HAProxy + PgBouncer)
	$(COMPOSE) $(COMPOSE_CORE) up -d --build

up-monitoring: ## Start core + Prometheus + Grafana + exporters
	$(COMPOSE) $(COMPOSE_CORE) $(COMPOSE_MON) up -d --build

up-backup: ## Start core + cron backup runner
	$(COMPOSE) $(COMPOSE_CORE) $(COMPOSE_BAK) up -d --build

up-dev: ## Start core + pgAdmin (localhost only)
	$(COMPOSE) $(COMPOSE_CORE) $(COMPOSE_DEV) up -d --build

up-minio: ## Start core + MinIO (S3-compatible pgBackRest repo)
	$(COMPOSE) $(COMPOSE_CORE) $(COMPOSE_MINIO) up -d --build

up-all: ## Start everything (core + monitoring + backup + dev + minio)
	$(ALL) up -d --build

down: ## Stop core stack
	$(COMPOSE) $(COMPOSE_CORE) down

down-all: ## Stop everything
	$(ALL) down

status: ## Container status
	$(ALL) ps

logs: ## Tail all logs
	$(ALL) logs -f --tail=100

ps: status

build: ## Build all images
	$(COMPOSE) $(COMPOSE_CORE) $(COMPOSE_BAK) build

rebuild: ## Rebuild from scratch (no cache)
	$(COMPOSE) $(COMPOSE_CORE) $(COMPOSE_BAK) build --no-cache

patroni-list: ## Show Patroni cluster topology
	docker exec pg-1 patronictl -c /etc/patroni/patroni.yml list

create-admin: ## Create/update DBA superuser ADMIN_DB_USER on existing cluster
	bash scripts/create-admin.sh

failover-test: ## Run automated failover test
	bash scripts/failover-test.sh

backup: ## Run an incremental pgBackRest backup against the current leader
	BACKUP_TYPE=incr BACKUP_REPO=1 bash scripts/backup.sh

backup-full: ## Run a FULL pgBackRest backup against the current leader
	BACKUP_TYPE=full BACKUP_REPO=1 bash scripts/backup.sh

backup-s3: ## Run a FULL pgBackRest backup against MinIO repo2
	BACKUP_TYPE=full BACKUP_REPO=2 bash scripts/backup.sh

minio-console: ## Print MinIO console URL
	@. ./.env && echo "MinIO console: https://localhost:$${MINIO_CONSOLE_PORT:-9001} (user: $${MINIO_ROOT_USER:-minioadmin})"

restore: ## Restore a node from latest backup. Usage: make restore NODE=pg-2
	@if [ -z "$(NODE)" ]; then echo "Usage: make restore NODE=pg-2 [SET=latest]"; exit 1; fi
	RESTORE_REPO=1 bash scripts/restore.sh $(NODE) $(or $(SET),latest)

restore-s3: ## Restore a node from MinIO repo2. Usage: make restore-s3 NODE=pg-2
	@if [ -z "$(NODE)" ]; then echo "Usage: make restore-s3 NODE=pg-2 [SET=latest]"; exit 1; fi
	RESTORE_REPO=2 bash scripts/restore.sh $(NODE) $(or $(SET),latest)

psql-write: ## Open psql against HAProxy:5000 (write/leader)
	@. ./.env && docker run -it --rm --network pg-ha -e PGPASSWORD="$$APP_DB_PASSWORD" postgres:17.2-bookworm psql -h pg-haproxy -p 5000 -U $$APP_DB_USER -d $$APP_DB_NAME

psql-read: ## Open psql against HAProxy:5001 (read/replicas)
	@. ./.env && docker run -it --rm --network pg-ha -e PGPASSWORD="$$APP_DB_PASSWORD" postgres:17.2-bookworm psql -h pg-haproxy -p 5001 -U $$APP_DB_USER -d $$APP_DB_NAME

clean: ## Stop containers (keeps volumes)
	$(ALL) down

nuke: ## DANGER: stop and remove all containers AND volumes (data loss)
	$(ALL) down -v
