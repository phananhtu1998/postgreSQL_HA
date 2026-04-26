# PostgreSQL HA với Patroni, etcd, HAProxy và PgBouncer

Repo này dựng một cụm PostgreSQL 17 có tính sẵn sàng cao bằng Docker Compose. Cụm gồm 3 node PostgreSQL do Patroni quản lý, 3 node etcd làm kho đồng thuận, HAProxy để tự động định tuyến vào primary/replica, PgBouncer để pooling kết nối, và các overlay tùy chọn cho monitoring, backup, pgAdmin.

Tài liệu này mô tả đúng theo các file `docker-compose*.yml`, cách chạy bằng `make.bat`, cách chạy trực tiếp bằng Docker CLI, ý nghĩa các tham số quan trọng và ví dụ kết nối từ Go, Node.js, Python, NestJS.

## Kiến trúc

```
                            apps
                              │
                       ┌──────┴──────┐
                       │  PgBouncer  │  6432  (rw + ro pools)
                       └──────┬──────┘
                              │
                       ┌──────┴──────┐
                       │   HAProxy   │  5000 (write → leader)
                       │             │  5001 (read  → replicas)
                       │             │  7000 (stats, auth)
                       └──┬───┬───┬──┘
              /leader 200 │   │   │ /replica 200
                          ▼   ▼   ▼
                    ┌────────┬────────┬────────┐
                    │  pg-1  │  pg-2  │  pg-3  │   Patroni 4.x
                    │Patroni │Patroni │Patroni │   PG 17 + pgBackRest
                    └────┬───┴────┬───┴────┬───┘
                         │        │        │
                         ▼        ▼        ▼
                    ┌────────┬────────┬────────┐
                    │ etcd-1 │ etcd-2 │ etcd-3 │   etcd 3.5
                    └────────┴────────┴────────┘
```

```text
Ứng dụng
   |
   |  Khuyến nghị dùng cổng 6432 để có connection pooling
   v
PgBouncer :6432
   |
   |  app_db_rw -> HAProxy :5000
   |  app_db_ro -> HAProxy :5001
   v
HAProxy
   |-- :5000 ghi  -> node PostgreSQL đang là leader
   |-- :5001 đọc  -> các node replica khỏe mạnh
   |-- :7000 UI stats, có basic auth
   |
   v
Patroni + PostgreSQL
   |-- pg-1, REST :8011, PostgreSQL host port :54321
   |-- pg-2, REST :8012, PostgreSQL host port :54322
   |-- pg-3, REST :8013, PostgreSQL host port :54323
   |
   v
etcd
   |-- etcd-1
   |-- etcd-2
   |-- etcd-3
```

Các service chính:

| Service | File | Vai trò |
|---|---|---|
| `etcd-1`, `etcd-2`, `etcd-3` | `docker-compose.yml` | Lưu trạng thái cụm và leader lock cho Patroni |
| `pg-1`, `pg-2`, `pg-3` | `docker-compose.yml` | PostgreSQL 17 chạy dưới Patroni |
| `pg-haproxy` | `docker-compose.yml` | Route ghi/đọc dựa trên trạng thái Patroni REST API |
| `pg-pgbouncer` | `docker-compose.yml` | Pool kết nối, tạo database alias `app_db_rw`, `app_db_ro` |
| `postgres-exporter-*` | `docker-compose.monitoring.yml` | Xuất metrics PostgreSQL cho Prometheus |
| `prometheus` | `docker-compose.monitoring.yml` | Thu thập metrics và alert rules |
| `grafana` | `docker-compose.monitoring.yml` | Dashboard PostgreSQL HA |
| `pg-backup` | `docker-compose.backup.yml` | Chạy pgBackRest backup theo cron |
| `pgadmin` | `docker-compose.dev.yml` | Giao diện quản trị dev, bind `127.0.0.1:8080` |

## Cách hoạt động

Khi chạy stack, Docker Compose tạo network `pg-ha`, volume dữ liệu cho từng node, rồi khởi động 3 node etcd. Patroni trên `pg-1`, `pg-2`, `pg-3` kết nối vào etcd để bầu leader. Node giữ leader lock trong etcd sẽ là primary PostgreSQL. Các node còn lại clone dữ liệu và chạy streaming replication.

HAProxy không hard-code primary. Nó gọi Patroni REST API trên từng node:

| Endpoint | Ý nghĩa |
|---|---|
| `/leader` | Trả HTTP 200 nếu node hiện là leader |
| `/replica` | Trả HTTP 200 nếu node là replica khỏe mạnh |
| `/patroni` | Thông tin trạng thái Patroni |
| `/health` | Healthcheck container |

Cổng `5000` của HAProxy luôn trỏ đến leader để ghi. Cổng `5001` trỏ đến replica để đọc. Nếu failover xảy ra, Patroni chọn leader mới, HAProxy tự cập nhật backend dựa trên HTTP check.

PgBouncer nằm trước HAProxy để giảm số kết nối thật vào PostgreSQL. Trong PgBouncer có các alias:

| Database qua PgBouncer | Route |
|---|---|
| `app_db` | Mặc định route write qua HAProxy `5000` |
| `app_db_rw` | Route write qua HAProxy `5000` |
| `app_db_ro` | Route read qua HAProxy `5001` |

## Chuẩn bị `.env`

Compose bắt buộc có file `.env`. Nếu thiếu, bạn sẽ gặp lỗi kiểu:

```text
required variable PATRONI_REPLICATION_PASSWORD is missing a value
```

Cách tạo:

```powershell
Copy-Item .env.example .env
notepad .env
```

Các biến quan trọng:

| Biến | Ý nghĩa |
|---|---|
| `PATRONI_SCOPE` | Tên logical cluster trong etcd, mặc định `pgcluster` |
| `PATRONI_SUPERUSER_NAME` | User superuser PostgreSQL, thường là `postgres` |
| `PATRONI_SUPERUSER_PASSWORD` | Mật khẩu superuser |
| `PATRONI_REPLICATION_USERNAME` | User dùng cho streaming replication |
| `PATRONI_REPLICATION_PASSWORD` | Mật khẩu replication user |
| `PATRONI_REST_USER` | User basic auth cho Patroni REST API |
| `PATRONI_REST_PASSWORD` | Password Patroni REST API |
| `APP_DB_NAME` | Database ứng dụng, ví dụ `app_db` |
| `APP_DB_USER` | User ứng dụng, ví dụ `app_user` |
| `APP_DB_PASSWORD` | Password user ứng dụng |
| `PG_HEALTHCHECK_USER` | User healthcheck |
| `PG_HEALTHCHECK_PASSWORD` | Password user healthcheck |
| `HAPROXY_STATS_PASSWORD` | Password trang HAProxy stats |
| `PGBOUNCER_POOL_MODE` | Pool mode, mặc định `transaction` |
| `PGBOUNCER_MAX_CLIENT_CONN` | Số client tối đa PgBouncer nhận |
| `PGBOUNCER_DEFAULT_POOL_SIZE` | Số connection backend mặc định mỗi pool |
| `PGBACKREST_STANZA` | Tên stanza pgBackRest, mặc định `main` |
| `GRAFANA_ADMIN_USER` | User Grafana |
| `GRAFANA_ADMIN_PASSWORD` | Password Grafana |
| `PGADMIN_DEFAULT_EMAIL` | Email đăng nhập pgAdmin |
| `PGADMIN_DEFAULT_PASSWORD` | Password pgAdmin |

Các biến port:

| Biến | Cổng host | Cổng container | Dùng để |
|---|---:|---:|---|
| `PG_1_PORT` | `54321` | `5432` | Kết nối trực tiếp `pg-1` |
| `PG_2_PORT` | `54322` | `5432` | Kết nối trực tiếp `pg-2` |
| `PG_3_PORT` | `54323` | `5432` | Kết nối trực tiếp `pg-3` |
| `PATRONI_1_REST_PORT` | `8011` | `8008` | Patroni REST `pg-1` |
| `PATRONI_2_REST_PORT` | `8012` | `8008` | Patroni REST `pg-2` |
| `PATRONI_3_REST_PORT` | `8013` | `8008` | Patroni REST `pg-3` |
| `HAPROXY_WRITE_PORT` | `5000` | `5000` | Kết nối write tới leader |
| `HAPROXY_READ_PORT` | `5001` | `5001` | Kết nối read tới replicas |
| `HAPROXY_STATS_PORT` | `7000` | `7000` | HAProxy stats UI |
| `PGBOUNCER_PORT` | `6432` | `6432` | PgBouncer pooling |

## Chạy bằng `make.bat` trên Windows

Mở Command Prompt hoặc PowerShell tại thư mục repo:

```bat
make.bat help
make.bat up
make.bat status
```

Nếu double-click `make.bat`, file sẽ mở chế độ tương tác. Tại dòng:

```text
Nhap lenh (vd: up, status, logs, exit):
```

nhập một target như `up`, `up-all`, `status`, `logs`, `exit`.

Các target:

| Target | Lệnh Docker Compose tương ứng | Ý nghĩa |
|---|---|---|
| `up` | `docker compose -f docker-compose.yml up -d --build` | Chạy core stack |
| `up-monitoring` | Core + `docker-compose.monitoring.yml` | Chạy thêm Prometheus, Grafana, exporters |
| `up-backup` | Core + `docker-compose.backup.yml` | Chạy thêm cron backup |
| `up-dev` | Core + `docker-compose.dev.yml` | Chạy thêm pgAdmin |
| `up-all` | Core + monitoring + backup + dev | Chạy toàn bộ |
| `down` | `docker compose -f docker-compose.yml down` | Dừng core stack |
| `down-all` | Dừng tất cả overlay | Dừng toàn bộ |
| `status` hoặc `ps` | `docker compose ... ps` | Xem trạng thái container |
| `logs` | `docker compose ... logs -f --tail=100` | Theo dõi log |
| `build` | Build image core và backup | Build image |
| `rebuild` | Build `--no-cache` | Build lại sạch |
| `patroni-list` | `docker exec pg-1 patronictl ... list` | Xem topology Patroni |
| `failover-test` | `bash scripts/failover-test.sh` | Test failover tự động |
| `backup` | `BACKUP_TYPE=incr bash scripts/backup.sh` | Backup incremental |
| `backup-full` | `BACKUP_TYPE=full bash scripts/backup.sh` | Backup full |
| `restore NODE [SET]` | `bash scripts/restore.sh NODE SET` | Restore một node |
| `psql-write` | psql qua HAProxy `5000` | Mở psql vào leader |
| `psql-read` | psql qua HAProxy `5001` | Mở psql vào replica |
| `nuke` | `docker compose ... down -v` | Xóa container và volume, mất dữ liệu |

Ví dụ:

```bat
make.bat up
make.bat patroni-list
make.bat psql-write
make.bat logs
make.bat down
```

Chạy full stack:

```bat
make.bat up-all
```

Restore:

```bat
make.bat restore pg-2 latest
```

## Chạy trực tiếp bằng Docker CLI

Core stack:

```powershell
docker compose -f docker-compose.yml up -d --build
```

Core + monitoring:

```powershell
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d --build
```

Core + backup:

```powershell
docker compose -f docker-compose.yml -f docker-compose.backup.yml up -d --build
```

Core + pgAdmin:

```powershell
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

Tất cả:

```powershell
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.backup.yml -f docker-compose.dev.yml up -d --build
```

Xem trạng thái:

```powershell
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.backup.yml -f docker-compose.dev.yml ps
```

Xem log:

```powershell
docker compose -f docker-compose.yml logs -f --tail=100
```

Dừng core:

```powershell
docker compose -f docker-compose.yml down
```

Dừng tất cả:

```powershell
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.backup.yml -f docker-compose.dev.yml down
```

Xóa cả volume dữ liệu:

```powershell
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.backup.yml -f docker-compose.dev.yml down -v
```

Lưu ý: `down -v` xóa dữ liệu PostgreSQL, etcd, backup repo local, Prometheus, Grafana, pgAdmin.

## Giải thích tham số Docker Compose

Trong các lệnh:

```powershell
docker compose -f docker-compose.yml up -d --build
```

Ý nghĩa:

| Tham số | Giải thích |
|---|---|
| `docker compose` | Chạy Docker Compose V2 |
| `-f docker-compose.yml` | Chọn file compose chính |
| `-f docker-compose.monitoring.yml` | Gộp thêm overlay monitoring |
| `-f docker-compose.backup.yml` | Gộp thêm overlay backup |
| `-f docker-compose.dev.yml` | Gộp thêm overlay dev |
| `up` | Tạo network, volume, container và khởi động |
| `-d` | Chạy detached, trả terminal lại ngay |
| `--build` | Build image trước khi chạy |
| `down` | Dừng và xóa container/network do Compose tạo |
| `down -v` | Dừng và xóa cả named volumes |
| `ps` | Xem trạng thái container |
| `logs -f` | Theo dõi log liên tục |
| `--tail=100` | Chỉ lấy 100 dòng log cuối lúc bắt đầu xem |

## Endpoint và URL cần nhớ

| Mục đích | Host | Port | Database |
|---|---|---:|---|
| App ghi trực tiếp qua HAProxy | `localhost` | `5000` | `app_db` |
| App đọc trực tiếp qua HAProxy | `localhost` | `5001` | `app_db` |
| App qua PgBouncer write pool | `localhost` | `6432` | `app_db_rw` |
| App qua PgBouncer read pool | `localhost` | `6432` | `app_db_ro` |
| App qua PgBouncer mặc định | `localhost` | `6432` | `app_db` |
| HAProxy stats | `http://localhost:7000/stats` | | user `admin` |
| Prometheus | `http://localhost:9090` | | |
| Grafana | `http://localhost:3000` | | `.env` |
| pgAdmin | `http://localhost:8080` | | `.env` |
| Patroni pg-1 | `http://localhost:8011/patroni` | | basic auth |
| Patroni pg-2 | `http://localhost:8012/patroni` | | basic auth |
| Patroni pg-3 | `http://localhost:8013/patroni` | | basic auth |

Chuỗi kết nối khuyến nghị cho ứng dụng:

```text
postgres://app_user:APP_DB_PASSWORD@localhost:6432/app_db_rw?sslmode=disable
postgres://app_user:APP_DB_PASSWORD@localhost:6432/app_db_ro?sslmode=disable
```

Nếu ứng dụng tự tách read/write, dùng `app_db_rw` cho ghi và `app_db_ro` cho đọc. Nếu ứng dụng chỉ có một datasource, dùng `app_db_rw` hoặc `app_db`.

## Kết nối bằng Go

Cài driver:

```bash
go get github.com/jackc/pgx/v5/pgxpool
```

Ví dụ write pool:

```go
package main

import (
	"context"
	"fmt"
	"log"
	"os"

	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	ctx := context.Background()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		dsn = "postgres://app_user:Local_App_ChangeMe_2026_J8rT2mW5qZ9nP4v@localhost:6432/app_db_rw?sslmode=disable"
	}

	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		log.Fatal(err)
	}
	defer pool.Close()

	var now string
	if err := pool.QueryRow(ctx, "select now()::text").Scan(&now); err != nil {
		log.Fatal(err)
	}

	fmt.Println("postgres time:", now)
}
```

Ví dụ tách read/write:

```go
writeDSN := "postgres://app_user:password@localhost:6432/app_db_rw?sslmode=disable"
readDSN := "postgres://app_user:password@localhost:6432/app_db_ro?sslmode=disable"
```

## Kết nối bằng Node.js

Cài package:

```bash
npm install pg
```

Ví dụ:

```js
const { Pool } = require("pg");

const writePool = new Pool({
  connectionString:
    process.env.DATABASE_WRITE_URL ||
    "postgres://app_user:Local_App_ChangeMe_2026_J8rT2mW5qZ9nP4v@localhost:6432/app_db_rw?sslmode=disable",
});

const readPool = new Pool({
  connectionString:
    process.env.DATABASE_READ_URL ||
    "postgres://app_user:Local_App_ChangeMe_2026_J8rT2mW5qZ9nP4v@localhost:6432/app_db_ro?sslmode=disable",
});

async function main() {
  const writeResult = await writePool.query("select now() as now");
  console.log("write endpoint:", writeResult.rows[0]);

  const readResult = await readPool.query("select now() as now");
  console.log("read endpoint:", readResult.rows[0]);

  await writePool.end();
  await readPool.end();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
```

## Kết nối bằng Python

Cài package:

```bash
pip install psycopg[binary]
```

Ví dụ:

```python
import os
import psycopg

write_dsn = os.getenv(
    "DATABASE_WRITE_URL",
    "postgres://app_user:Local_App_ChangeMe_2026_J8rT2mW5qZ9nP4v@localhost:6432/app_db_rw?sslmode=disable",
)

read_dsn = os.getenv(
    "DATABASE_READ_URL",
    "postgres://app_user:Local_App_ChangeMe_2026_J8rT2mW5qZ9nP4v@localhost:6432/app_db_ro?sslmode=disable",
)

with psycopg.connect(write_dsn) as conn:
    with conn.cursor() as cur:
        cur.execute("select now()")
        print("write endpoint:", cur.fetchone())

with psycopg.connect(read_dsn) as conn:
    with conn.cursor() as cur:
        cur.execute("select now()")
        print("read endpoint:", cur.fetchone())
```

## Kết nối bằng NestJS

Ví dụ dưới đây dùng TypeORM. Nếu dùng Prisma, bạn vẫn dùng cùng `DATABASE_URL`.

Cài package:

```bash
npm install @nestjs/typeorm typeorm pg
```

`.env` của ứng dụng NestJS:

```env
DATABASE_HOST=localhost
DATABASE_PORT=6432
DATABASE_USER=app_user
DATABASE_PASSWORD=Local_App_ChangeMe_2026_J8rT2mW5qZ9nP4v
DATABASE_NAME=app_db_rw
```

`app.module.ts`:

```ts
import { Module } from "@nestjs/common";
import { TypeOrmModule } from "@nestjs/typeorm";

@Module({
  imports: [
    TypeOrmModule.forRoot({
      type: "postgres",
      host: process.env.DATABASE_HOST || "localhost",
      port: Number(process.env.DATABASE_PORT || 6432),
      username: process.env.DATABASE_USER || "app_user",
      password:
        process.env.DATABASE_PASSWORD ||
        "Local_App_ChangeMe_2026_J8rT2mW5qZ9nP4v",
      database: process.env.DATABASE_NAME || "app_db_rw",
      autoLoadEntities: true,
      synchronize: false,
      ssl: false,
    }),
  ],
})
export class AppModule {}
```

Nếu muốn tách read/write trong NestJS, cấu hình 2 connection:

```ts
TypeOrmModule.forRoot({
  name: "write",
  type: "postgres",
  host: "localhost",
  port: 6432,
  username: "app_user",
  password: process.env.DATABASE_PASSWORD,
  database: "app_db_rw",
});

TypeOrmModule.forRoot({
  name: "read",
  type: "postgres",
  host: "localhost",
  port: 6432,
  username: "app_user",
  password: process.env.DATABASE_PASSWORD,
  database: "app_db_ro",
});
```

## Kiểm tra cụm sau khi chạy

Xem container:

```bat
make.bat status
```

Xem topology Patroni:

```bat
make.bat patroni-list
```

Hoặc dùng Docker CLI:

```powershell
docker exec pg-1 patronictl -c /etc/patroni/patroni.yml list
```

Mở psql vào leader:

```bat
make.bat psql-write
```

Mở psql vào replica:

```bat
make.bat psql-read
```

Test failover:

```bat
make.bat failover-test
```

## Backup và restore

Chạy stack có backup overlay:

```bat
make.bat up-backup
```

Backup incremental:

```bat
make.bat backup
```

Backup full:

```bat
make.bat backup-full
```

Xem backup inventory:

```powershell
docker exec -u postgres pg-1 pgbackrest --stanza=main info
```

Restore một node:

```bat
make.bat restore pg-2 latest
```

Backup hiện dùng volume local `pg-backup-repo`. Khi chạy production, nên chuyển pgBackRest sang S3, GCS hoặc MinIO và bật mã hóa.

### Backup lên MinIO

Repo này có thêm overlay `docker-compose.minio.yml` để chạy MinIO như S3-compatible storage cho pgBackRest. Khi bật MinIO:

| Repo pgBackRest | Nơi lưu | Target |
|---|---|---|
| `repo1` | Volume local `pg-backup-repo` | `backup`, `backup-full`, `restore` |
| `repo2` | MinIO bucket `PGBACKREST_S3_BUCKET` | `backup-s3`, `restore-s3` |

Chạy core + MinIO:

```bat
make.bat up-minio
```

Chạy tất cả gồm MinIO:

```bat
make.bat up-all
```

Mở MinIO console:

```bat
make.bat minio-console
```

URL mặc định:

```text
https://localhost:9001
```

Đăng nhập bằng:

| Field | Biến `.env` |
|---|---|
| User | `MINIO_ROOT_USER` |
| Password | `MINIO_ROOT_PASSWORD` |

Chạy full backup vào MinIO `repo2`:

```bat
make.bat backup-s3
```

Xem inventory repo2:

```powershell
docker exec -u postgres pg-1 pgbackrest --stanza=main --repo=2 info
```

Restore từ MinIO `repo2`:

```bat
make.bat restore-s3 pg-2 latest
```

Các biến cấu hình MinIO/S3 nằm trong `.env`:

| Biến | Ý nghĩa |
|---|---|
| `MINIO_ROOT_USER` | User admin MinIO |
| `MINIO_ROOT_PASSWORD` | Password admin MinIO |
| `MINIO_API_PORT` | Cổng S3 API trên host, mặc định `9000` |
| `MINIO_CONSOLE_PORT` | Cổng MinIO console trên host, mặc định `9001` |
| `PGBACKREST_S3_ENDPOINT` | Endpoint nội bộ cho pgBackRest, mặc định `minio:9000` |
| `PGBACKREST_S3_BUCKET` | Bucket lưu backup |
| `PGBACKREST_S3_KEY` | Access key pgBackRest |
| `PGBACKREST_S3_KEY_SECRET` | Secret key pgBackRest |
| `PGBACKREST_S3_REGION` | Region S3, mặc định `us-east-1` |
| `PGBACKREST_S3_PATH` | Path prefix trong bucket |
| `PGBACKREST_S3_URI_STYLE` | Mặc định `path`, phù hợp MinIO |
| `PGBACKREST_S3_VERIFY_TLS` | `n` vì MinIO local dùng self-signed cert |

## Cấu hình Prometheus và Grafana

Monitoring nằm trong file `docker-compose.monitoring.yml`. Overlay này thêm 5 service:

| Service | Image | Vai trò |
|---|---|---|
| `postgres-exporter-1` | `prometheuscommunity/postgres-exporter:v0.15.0` | Lấy metrics từ `pg-1:5432` |
| `postgres-exporter-2` | `prometheuscommunity/postgres-exporter:v0.15.0` | Lấy metrics từ `pg-2:5432` |
| `postgres-exporter-3` | `prometheuscommunity/postgres-exporter:v0.15.0` | Lấy metrics từ `pg-3:5432` |
| `prometheus` | `prom/prometheus:v2.55.1` | Scrape exporters và đánh giá alert rules |
| `grafana` | `grafana/grafana:11.3.0` | Hiển thị dashboard |

### Chạy monitoring

Chạy core + monitoring:

```bat
make.bat up-monitoring
```

Hoặc chạy trực tiếp:

```powershell
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d --build
```

Nếu muốn chạy toàn bộ stack gồm monitoring, backup và pgAdmin:

```bat
make.bat up-all
```

Mở UI:

| UI | URL | Tài khoản |
|---|---|---|
| Prometheus | `http://localhost:9090` | Không bật auth mặc định |
| Grafana | `http://localhost:3000` | `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` |
| HAProxy stats | `http://localhost:7000/stats` | `admin` / `HAPROXY_STATS_PASSWORD` |

### Biến môi trường cho Grafana

Cấu hình trong `.env`:

```env
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=ChangeMe_GrafanaAdmin
```

Trong `docker-compose.monitoring.yml`, hai biến này được map thành:

| Biến Grafana | Lấy từ `.env` | Ý nghĩa |
|---|---|---|
| `GF_SECURITY_ADMIN_USER` | `GRAFANA_ADMIN_USER` | User admin ban đầu |
| `GF_SECURITY_ADMIN_PASSWORD` | `GRAFANA_ADMIN_PASSWORD` | Password admin ban đầu |
| `GF_USERS_ALLOW_SIGN_UP` | `"false"` | Tắt đăng ký user tự do |
| `GF_INSTALL_PLUGINS` | `""` | Không cài plugin thêm khi boot |

Lưu ý: Grafana lưu state trong volume `grafana-data`. Nếu bạn đổi `GRAFANA_ADMIN_PASSWORD` sau khi Grafana đã khởi tạo, password có thể không đổi theo vì user admin đã nằm trong database Grafana. Cách reset nhanh trong môi trường local:

```powershell
docker exec -it grafana grafana cli admin reset-admin-password "<password-moi>"
```

### Prometheus scrape config

File chính:

```text
config/prometheus.yml
```

Cấu hình hiện tại:

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/alert-rules.yml

scrape_configs:
  - job_name: postgres
    static_configs:
      - targets:
          - postgres-exporter-1:9187
          - postgres-exporter-2:9187
          - postgres-exporter-3:9187
        labels:
          cluster: pgcluster

  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']
```

Ý nghĩa:

| Trường | Ý nghĩa |
|---|---|
| `scrape_interval: 15s` | Prometheus lấy metrics mỗi 15 giây |
| `evaluation_interval: 15s` | Prometheus đánh giá alert rules mỗi 15 giây |
| `rule_files` | Nạp rules từ `config/alert-rules.yml` |
| `job_name: postgres` | Job scrape 3 postgres exporters |
| `targets` | Tên container exporter trong Docker network `pg-ha` |
| `labels.cluster` | Gắn label `cluster=pgcluster` cho metrics |
| `job_name: prometheus` | Prometheus tự scrape chính nó |

Kiểm tra targets sau khi chạy:

```text
http://localhost:9090/targets
```

Bạn cần thấy các target `postgres-exporter-1:9187`, `postgres-exporter-2:9187`, `postgres-exporter-3:9187` ở trạng thái `UP`.

Kiểm tra metric nhanh trong Prometheus:

```promql
pg_up
```

```promql
pg_replication_is_replica
```

```promql
pg_stat_activity_count
```

```promql
pg_replication_lag_seconds
```

### Thêm PostgreSQL exporter mới

Nếu sau này thêm node PostgreSQL mới, ví dụ `pg-4`, cần làm 2 việc.

Thêm service exporter trong `docker-compose.monitoring.yml`:

```yaml
postgres-exporter-4:
  <<: *exporter
  container_name: postgres-exporter-4
  environment:
    DATA_SOURCE_NAME: "postgresql://${PATRONI_SUPERUSER_NAME}:${PATRONI_SUPERUSER_PASSWORD}@pg-4:5432/postgres?sslmode=disable"
    PG_EXPORTER_AUTO_DISCOVER_DATABASES: "true"
    PG_EXPORTER_EXCLUDE_DATABASES: "template0,template1"
  depends_on:
    pg-4: { condition: service_healthy }
```

Thêm target vào `config/prometheus.yml`:

```yaml
- postgres-exporter-4:9187
```

Sau đó recreate monitoring để Compose tạo exporter mới:

```powershell
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d --build
```

Nếu chỉ sửa `config/prometheus.yml` mà không thêm service mới, reload Prometheus là đủ:

```powershell
curl -X POST http://localhost:9090/-/reload
```

Nếu `curl` không có sẵn hoặc reload không nhận cấu hình, restart:

```powershell
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml restart prometheus
```

### Alert rules

File rules:

```text
config/alert-rules.yml
```

Các alert đang có:

| Alert | Điều kiện | Mức độ |
|---|---|---|
| `PostgresInstanceDown` | `pg_up == 0` trong 1 phút | `critical` |
| `PostgresPrimaryDown` | Không có node nào là primary trong 30 giây | `critical` |
| `PostgresReplicationLagHigh` | Lag replication > 30 giây trong 2 phút | `warning` |
| `PostgresTooManyConnections` | Active connections > 250 trong 5 phút | `warning` |
| `PostgresDeadlocksRising` | Deadlocks tăng trong 10 phút | `warning` |
| `PostgresLongRunningTransaction` | Transaction chạy > 10 phút | `warning` |
| `PostgresXIDWraparoundRisk` | Transaction ID tiến gần ngưỡng rủi ro | `critical` |
| `PostgresCheckpointsTooFrequent` | Requested checkpoints quá thường xuyên | `info` |

Xem trạng thái alert:

```text
http://localhost:9090/alerts
```

Sửa ngưỡng alert bằng cách chỉnh `expr` hoặc `for`. Ví dụ tăng ngưỡng replication lag từ 30 giây lên 60 giây:

```yaml
- alert: PostgresReplicationLagHigh
  expr: pg_replication_lag_seconds > 60
  for: 2m
```

Reload Prometheus sau khi sửa:

```powershell
curl -X POST http://localhost:9090/-/reload
```

Prometheus hiện chỉ đánh giá alert trong UI. Repo chưa cấu hình Alertmanager. Nếu muốn gửi cảnh báo ra Slack, Telegram, Email, PagerDuty, cần thêm service `alertmanager`, mount `alertmanager.yml`, rồi thêm khối `alerting` trong `config/prometheus.yml`.

### Grafana provisioning

Grafana được cấu hình tự động bằng thư mục:

```text
grafana/provisioning
```

Datasource:

```text
grafana/provisioning/datasources/prometheus.yml
```

Nội dung chính:

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
```

Ý nghĩa:

| Trường | Ý nghĩa |
|---|---|
| `name: Prometheus` | Tên datasource trong Grafana |
| `type: prometheus` | Loại datasource |
| `access: proxy` | Grafana server gọi Prometheus thay browser |
| `url: http://prometheus:9090` | Tên service Prometheus trong Docker network |
| `isDefault: true` | Datasource mặc định |
| `editable: false` | Không sửa datasource từ UI |

Dashboard provider:

```text
grafana/provisioning/dashboards/default.yml
```

Nội dung chính:

```yaml
apiVersion: 1
providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
```

Grafana đọc dashboard JSON từ:

```text
grafana/dashboards/postgres-ha.json
```

Dashboard hiện có tên:

```text
Postgres HA Overview
```

Các panel chính:

| Panel | Metric |
|---|---|
| `PG Up` | `pg_up` |
| `Role (1=primary, 0=replica)` | `pg_replication_is_replica` |
| `Active Connections` | `pg_stat_activity_count` |
| `Replication Lag (s)` | `pg_replication_lag_seconds` |
| `Transactions / sec` | `pg_stat_database_xact_commit`, `pg_stat_database_xact_rollback` |
| `Cache Hit Ratio (%)` | hit ratio từ `pg_stat_database_*` |
| `Database Size (bytes)` | `pg_database_size_bytes` |
| `Deadlocks /s` | `pg_stat_database_deadlocks` |

Sau khi sửa dashboard JSON, Grafana sẽ tự quét lại theo `updateIntervalSeconds: 30`. Nếu muốn chắc chắn:

```powershell
docker restart grafana
```

### Import dashboard thủ công

Nếu muốn tự import dashboard trong UI:

1. Mở `http://localhost:3000`.
2. Đăng nhập bằng `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD`.
3. Vào `Dashboards` -> `New` -> `Import`.
4. Upload file `grafana/dashboards/postgres-ha.json`.
5. Chọn datasource `Prometheus`.

Với provisioning hiện tại, bước import thủ công thường không cần thiết vì dashboard đã được mount read-only vào container.

### Lưu dữ liệu Prometheus và Grafana

Hai named volume được khai báo trong `docker-compose.monitoring.yml`:

| Volume | Dùng cho |
|---|---|
| `prometheus-data` | Dữ liệu time-series Prometheus |
| `grafana-data` | Database Grafana, user, session, setting |

Prometheus retention hiện là 30 ngày:

```yaml
--storage.tsdb.retention.time=30d
```

Muốn đổi retention, sửa command của service `prometheus`, ví dụ 15 ngày:

```yaml
--storage.tsdb.retention.time=15d
```

Sau đó recreate Prometheus:

```powershell
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d prometheus
```

### Kiểm tra lỗi monitoring

Xem log exporter:

```powershell
docker logs postgres-exporter-1
docker logs postgres-exporter-2
docker logs postgres-exporter-3
```

Xem log Prometheus:

```powershell
docker logs prometheus
```

Xem log Grafana:

```powershell
docker logs grafana
```

Lỗi thường gặp:

| Lỗi | Nguyên nhân | Cách xử lý |
|---|---|---|
| Target exporter `DOWN` | PostgreSQL node chưa healthy hoặc exporter không kết nối được DB | Chờ cluster lên xong, kiểm tra `docker logs postgres-exporter-*` |
| Grafana không thấy dashboard | Provisioning path sai hoặc container chưa reload | Kiểm tra `grafana/provisioning/dashboards/default.yml`, restart `grafana` |
| Grafana không query được Prometheus | Datasource URL sai | Trong Docker network phải dùng `http://prometheus:9090`, không dùng `localhost` |
| Đổi password Grafana nhưng không đăng nhập được | Volume `grafana-data` đã có user cũ | Dùng `grafana cli admin reset-admin-password` |
| Alert không đổi sau khi sửa file | Prometheus chưa reload config | Gọi `curl -X POST http://localhost:9090/-/reload` hoặc restart `prometheus` |

## pgAdmin cho môi trường dev

pgAdmin nằm trong overlay `docker-compose.dev.yml`, chỉ bind ra `127.0.0.1:8080` để dùng local. Overlay này phụ thuộc vào `pgbouncer`, nên khi chạy `up-dev` Compose sẽ chạy core stack trước rồi mới chạy pgAdmin.

### Chạy pgAdmin

```bat
make.bat up-dev
```

Hoặc chạy trực tiếp bằng Docker CLI:

```powershell
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

Mở pgAdmin:

```text
http://localhost:8080
```

Đăng nhập bằng thông tin trong `.env`:

| Trường | Biến `.env` | Ví dụ |
|---|---|---|
| Email | `PGADMIN_DEFAULT_EMAIL` | `admin@example.com` |
| Password | `PGADMIN_DEFAULT_PASSWORD` | `Local_pgAdmin_ChangeMe_2026_T6nP2vK9qS4xW8r` |

### Host nào dùng trong pgAdmin

Điểm dễ nhầm: pgAdmin chạy trong container Docker, nên connection từ pgAdmin tới PostgreSQL đi qua Docker network `pg-ha`, không đi từ browser của bạn. Vì vậy trong pgAdmin nên dùng tên service nội bộ:

| Muốn kết nối tới | Host trong pgAdmin | Port | Database |
|---|---|---:|---|
| PgBouncer write pool | `pgbouncer` | `6432` | `app_db_rw` |
| PgBouncer read pool | `pgbouncer` | `6432` | `app_db_ro` |
| PgBouncer mặc định | `pgbouncer` | `6432` | `app_db` |
| HAProxy write endpoint | `haproxy` | `5000` | `app_db` |
| HAProxy read endpoint | `haproxy` | `5001` | `app_db` |
| Trực tiếp node `pg-1` | `pg-1` | `5432` | `app_db` |
| Trực tiếp node `pg-2` | `pg-2` | `5432` | `app_db` |
| Trực tiếp node `pg-3` | `pg-3` | `5432` | `app_db` |

Nếu bạn dùng DBeaver, TablePlus, DataGrip hoặc app chạy ngoài Docker trên máy host, khi đó mới dùng:

| Endpoint ngoài Docker | Host | Port | Database |
|---|---|---:|---|
| PgBouncer | `localhost` | `6432` | `app_db_rw` hoặc `app_db_ro` |
| HAProxy write | `localhost` | `5000` | `app_db` |
| HAProxy read | `localhost` | `5001` | `app_db` |

### Tạo server write trong pgAdmin

Trong pgAdmin:

1. Right click `Servers`.
2. Chọn `Register` -> `Server`.
3. Tab `General`:
   - `Name`: `Postgres HA - Write`
4. Tab `Connection`:
   - `Host name/address`: `pgbouncer`
   - `Port`: `6432`
   - `Maintenance database`: `app_db_rw`
   - `Username`: giá trị `APP_DB_USER`
   - `Password`: giá trị `APP_DB_PASSWORD`
   - Bật `Save password` nếu muốn.
5. Bấm `Save`.

Với `.env` local hiện tại, thông tin thường là:

| Field | Giá trị |
|---|---|
| Host name/address | `pgbouncer` |
| Port | `6432` |
| Maintenance database | `app_db_rw` |
| Username | `app_user` |
| Password | `APP_DB_PASSWORD` trong `.env` |

### Tạo server read trong pgAdmin

Tạo thêm một server nữa để kiểm tra read endpoint:

1. Right click `Servers`.
2. Chọn `Register` -> `Server`.
3. Tab `General`:
   - `Name`: `Postgres HA - Read`
4. Tab `Connection`:
   - `Host name/address`: `pgbouncer`
   - `Port`: `6432`
   - `Maintenance database`: `app_db_ro`
   - `Username`: giá trị `APP_DB_USER`
   - `Password`: giá trị `APP_DB_PASSWORD`
5. Bấm `Save`.

Server này đi qua `PgBouncer -> HAProxy:5001 -> replica khỏe mạnh`.

### Tạo server HAProxy trực tiếp

Nếu muốn bỏ qua PgBouncer để kiểm tra HAProxy trực tiếp, tạo 2 server:

| Name | Host | Port | Maintenance database | Ý nghĩa |
|---|---|---:|---|---|
| `HAProxy - Write` | `haproxy` | `5000` | `app_db` | Luôn vào leader |
| `HAProxy - Read` | `haproxy` | `5001` | `app_db` | Vào replica, fallback leader nếu không còn replica |

Vẫn dùng:

| Field | Giá trị |
|---|---|
| Username | `APP_DB_USER` |
| Password | `APP_DB_PASSWORD` |

### Kiểm tra endpoint write

Mở Query Tool trên server `Postgres HA - Write`, chạy:

```sql
select
  inet_server_addr() as server_ip,
  inet_server_port() as server_port,
  pg_is_in_recovery() as is_replica,
  current_database() as database_name,
  current_user as user_name;
```

Kết quả kỳ vọng:

| Cột | Giá trị |
|---|---|
| `is_replica` | `false` |
| `database_name` | `app_db` |
| `user_name` | `app_user` |

Tạo bảng test:

```sql
create table if not exists ha_rw_test (
  id bigserial primary key,
  source text not null,
  created_at timestamptz not null default now()
);
```

Insert dữ liệu qua write endpoint:

```sql
insert into ha_rw_test (source)
values ('inserted from pgadmin write endpoint')
returning *;
```

Đọc lại:

```sql
select * from ha_rw_test order by id desc limit 10;
```

### Kiểm tra endpoint read

Mở Query Tool trên server `Postgres HA - Read`, chạy:

```sql
select
  inet_server_addr() as server_ip,
  inet_server_port() as server_port,
  pg_is_in_recovery() as is_replica,
  current_database() as database_name,
  current_user as user_name;
```

Kết quả kỳ vọng trong trạng thái bình thường:

| Cột | Giá trị |
|---|---|
| `is_replica` | `true` |
| `database_name` | `app_db` |
| `user_name` | `app_user` |

Đọc dữ liệu vừa insert từ write endpoint:

```sql
select * from ha_rw_test order by id desc limit 10;
```

Nếu replication đã chạy ổn, bạn sẽ thấy row vừa insert. Có thể có độ trễ rất ngắn vì dữ liệu đi từ leader sang replica bằng streaming replication.

Thử ghi nhầm vào read endpoint:

```sql
insert into ha_rw_test (source)
values ('this should fail on read endpoint');
```

Kết quả kỳ vọng nếu HAProxy đang route tới replica:

```text
ERROR: cannot execute INSERT in a read-only transaction
```

Nếu câu insert không lỗi, nghĩa là read endpoint đang fallback về leader. Trường hợp này có thể xảy ra khi toàn bộ replica đang down hoặc chưa healthy; HAProxy config có backend fallback để ứng dụng vẫn đọc được trong chế độ degraded.

### Kiểm tra node hiện tại là leader hay replica

Trong Query Tool, chạy:

```sql
select
  case when pg_is_in_recovery() then 'replica' else 'leader' end as node_role,
  inet_server_addr() as server_ip,
  inet_server_port() as server_port;
```

Bạn cũng có thể xem bằng Patroni:

```bat
make.bat patroni-list
```

Hoặc:

```powershell
docker exec pg-1 patronictl -c /etc/patroni/patroni.yml list
```

### Kiểm tra PgBouncer đang nối tới database alias nào

Kết nối vào server `Postgres HA - Write` hoặc `Postgres HA - Read`, rồi chạy:

```sql
show databases;
```

Vì `APP_DB_USER` được cấu hình là `stats_users` và `admin_users` trong PgBouncer, bạn có thể xem các alias:

| Alias | Backend |
|---|---|
| `app_db` | HAProxy write port `5000` |
| `app_db_rw` | HAProxy write port `5000` |
| `app_db_ro` | HAProxy read port `5001` |

Xem pool:

```sql
show pools;
```

Xem clients:

```sql
show clients;
```

### Kết nối trực tiếp từng PostgreSQL node để kiểm tra replication

Trong pgAdmin, có thể tạo server trực tiếp tới từng node:

| Name | Host | Port | Database |
|---|---|---:|---|
| `Direct pg-1` | `pg-1` | `5432` | `app_db` |
| `Direct pg-2` | `pg-2` | `5432` | `app_db` |
| `Direct pg-3` | `pg-3` | `5432` | `app_db` |

User/password vẫn là `APP_DB_USER` và `APP_DB_PASSWORD`. Sau khi kết nối từng node, chạy:

```sql
select
  case when pg_is_in_recovery() then 'replica' else 'leader' end as role,
  inet_server_addr() as server_ip,
  now() as checked_at;
```

Cách này hữu ích để đối chiếu với `make.bat patroni-list`.

### Lỗi thường gặp khi kết nối pgAdmin

| Lỗi | Nguyên nhân | Cách xử lý |
|---|---|---|
| `could not translate host name "localhost"` hoặc không vào đúng DB | Trong pgAdmin container, `localhost` là chính container pgAdmin | Dùng `pgbouncer`, `haproxy`, `pg-1`, `pg-2`, `pg-3` |
| `password authentication failed` | Sai `APP_DB_PASSWORD` hoặc PgBouncer chưa render lại userlist | Kiểm tra `.env`, restart `pg-pgbouncer` |
| `database "app_db_rw" does not exist` khi nối trực tiếp node | `app_db_rw` chỉ là alias của PgBouncer, không phải database thật trong PostgreSQL | Direct node/HAProxy dùng `app_db`; PgBouncer mới dùng `app_db_rw`, `app_db_ro` |
| Insert vào read endpoint vẫn thành công | HAProxy read đang fallback về leader vì replica chưa healthy | Kiểm tra `make.bat patroni-list`, đợi replica healthy rồi thử lại |
| Không thấy row mới ở read endpoint | Replication lag hoặc replica chưa healthy | Chờ vài giây, kiểm tra `patroni-list` và logs |


## Lưu ý production

- Đổi toàn bộ password trong `.env`, không dùng giá trị `ChangeMe` hoặc giá trị local.
- Không public cổng PostgreSQL, PgBouncer, HAProxy stats ra Internet.
- Dùng firewall/private network cho `5000`, `5001`, `6432`, `7000`.
- Chuyển backup repo sang S3/GCS/MinIO và test restore định kỳ.
- Bật TLS nếu traffic đi qua nhiều host, subnet hoặc vùng mạng.
- Giám sát Prometheus alert bằng Alertmanager, Slack, PagerDuty hoặc hệ thống tương đương.
- Compose này phù hợp demo/single-host. Production thật nên trải `etcd` và PostgreSQL node qua nhiều host/AZ.
- Nếu cần zero data loss, cân nhắc `synchronous_mode: true` trong `config/patroni.yml.tpl`, đổi lại sẽ giảm availability khi replica không sẵn sàng.

## Troubleshooting

Thiếu `.env` hoặc thiếu biến:

```text
required variable PATRONI_REPLICATION_PASSWORD is missing a value
```

Tạo `.env` từ `.env.example` và điền đủ password.

Container PostgreSQL `unhealthy` khi boot lần đầu:

```text
Chờ 60-90 giây
```

Lần đầu Patroni cần initdb, tạo leader và clone replica.

HAProxy báo backend down:

```powershell
docker logs pg-haproxy
docker logs pg-1
docker logs pg-2
docker logs pg-3
```

Kiểm tra Patroni REST:

```powershell
curl -u patroni_rest:<PATRONI_REST_PASSWORD> http://localhost:8011/patroni
```

PgBouncer báo sai password:

```text
Kiểm tra APP_DB_PASSWORD trong .env và restart pg-pgbouncer.
```

Xem log tập trung:

```bat
make.bat logs
```

Build lại sạch khi nghi lỗi line ending hoặc image cũ:

```bat
make.bat rebuild
make.bat up
```
