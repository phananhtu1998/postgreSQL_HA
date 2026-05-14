# PostgreSQL HA + Redis Sentinel với Patroni, etcd, HAProxy và PgBouncer

Repo này dựng một cụm PostgreSQL 17 có tính sẵn sàng cao bằng Docker Compose, tích hợp sẵn Redis Sentinel HA. Cụm gồm 3 node PostgreSQL do Patroni quản lý, 3 node etcd làm kho đồng thuận, HAProxy để tự động định tuyến vào primary/replica, PgBouncer để pooling kết nối, Redis Sentinel (1 master + 2 replicas + 3 sentinels) cho caching/session, và các overlay tùy chọn cho monitoring, backup, pgAdmin.

Tài liệu này mô tả đúng theo các file `docker-compose*.yml`, cách chạy bằng `make.bat`, cách chạy trực tiếp bằng Docker CLI, ý nghĩa các tham số quan trọng, hướng dẫn kết nối qua **pgAdmin**, ví dụ kết nối từ Go, Node.js, Python, NestJS (kèm Express CRUD demo trong `src/server.js`), và hướng dẫn sử dụng Redis Sentinel HA.

## Mục lục

- [Kiến trúc](#kiến-trúc) — sơ đồ cụm
- [Bắt đầu nhanh](#bắt-đầu-nhanh-up--login-pgadmin--query) — up cluster, login pgAdmin, query đầu tiên trong < 5 phút
- [Tạo admin DBA superuser](#tạo-admin-dba-superuser) — login pgAdmin với quyền `CREATE DATABASE`
- [Thêm database mới](#thêm-database-mới) — auto qua sidecar hoặc manual qua `.env`
- [Chuẩn bị `.env`](#chuẩn-bị-env) — bảng đầy đủ các biến môi trường
- [Endpoint và URL cần nhớ](#endpoint-và-url-cần-nhớ) — host/port để app/tool dùng
- [Kết nối từ Go / Node.js / Python / NestJS](#kết-nối-bằng-go) — ví dụ DSN
- [pgAdmin chi tiết](#pgadmin-cho-môi-trường-dev) — register server, query rw/ro, troubleshooting
- [Redis Sentinel HA](#redis-sentinel-ha) — kiến trúc, kết nối, failover, Makefile targets
- [Redis Insight](#redis-insight) — GUI quản trị Redis qua trình duyệt
- [Backup / Monitoring / Production checklist / Troubleshooting](#backup-và-restore)

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

                    ┌───────────────────────────────┐
                    │      Redis Sentinel HA       │
                    │  sentinel-1  sentinel-2       │
                    │       sentinel-3 (quorum 2)   │
                    └─────────┬─────────┬──────────┘
                              │         │
                    ┌─────────┴─────────┴──────────┐
                    │ redis-   redis-     redis-    │
                    │ master   replica-1  replica-2 │
                    │ :6379    :6380      :6381     │
                    └───────────────────────────────┘
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

Redis Sentinel HA (cùng network pg-ha)
   |-- redis-master   :6379  (ghi + đọc)
   |-- redis-replica-1 :6380  (chỉ đọc, replicaof master)
   |-- redis-replica-2 :6381  (chỉ đọc, replicaof master)
   |-- sentinel-1      :26379 (giám sát + failover)
   |-- sentinel-2      :26380
   |-- sentinel-3      :26381
   Quorum: 2/3 sentinel đồng ý = trigger failover
```

Các service chính:

| Service | File | Vai trò |
|---|---|---|
| `etcd-1`, `etcd-2`, `etcd-3` | `docker-compose.yml` | Lưu trạng thái cụm và leader lock cho Patroni |
| `pg-1`, `pg-2`, `pg-3` | `docker-compose.yml` | PostgreSQL 17 chạy dưới Patroni |
| `pg-haproxy` | `docker-compose.yml` | Route ghi/đọc dựa trên trạng thái Patroni REST API |
| `pg-pgbouncer` | `docker-compose.yml` | Pool kết nối, tạo database alias `app_db_rw`, `app_db_ro` |
| `pg-pgbouncer-autosync` | `docker-compose.yml` | Sidecar tự discover DB mới, re-render `pgbouncer.ini` + RELOAD online |
| `postgres-exporter-*` | `docker-compose.monitoring.yml` | Xuất metrics PostgreSQL cho Prometheus |
| `prometheus` | `docker-compose.monitoring.yml` | Thu thập metrics và alert rules |
| `grafana` | `docker-compose.monitoring.yml` | Dashboard PostgreSQL HA |
| `pg-backup` | `docker-compose.backup.yml` | Chạy pgBackRest backup theo cron |
| `pgadmin` | `docker-compose.dev.yml` | Giao diện quản trị dev, mặc định bind `127.0.0.1:8080` (đổi `PGADMIN_HOST=0.0.0.0` để truy cập từ ngoài) |
| `redis-insight` | `docker-compose.dev.yml` | Redis Insight — GUI quản trị Redis qua trình duyệt, mặc định bind `127.0.0.1:5540` |
| `redis-master` | `docker-compose.yml` | Redis master node, ghi + đọc |
| `redis-replica-1`, `redis-replica-2` | `docker-compose.yml` | Redis replicas, chỉ đọc, tự đồng replicaof master |
| `redis-sentinel-1`, `redis-sentinel-2`, `redis-sentinel-3` | `docker-compose.yml` | Redis Sentinel, giám sát master và tự động failover (quorum 2) |

## Bắt đầu nhanh: up + login pgAdmin + query

Mục tiêu: từ repo sạch tới kết nối được qua pgAdmin trong < 5 phút.

### 1. Tạo `.env` từ template

```powershell
Copy-Item .env.example .env
notepad .env
```

Sửa **tối thiểu** các password sau (không để giá trị `ChangeMe_...`):

```ini
PATRONI_SUPERUSER_PASSWORD=...    # mật khẩu superuser PostgreSQL
PATRONI_REPLICATION_PASSWORD=...  # mật khẩu replication user
PATRONI_REST_PASSWORD=...         # mật khẩu Patroni REST API
APP_DB_PASSWORD=...               # mật khẩu app user (sẽ dùng trong pgAdmin)
PG_HEALTHCHECK_PASSWORD=...       # mật khẩu healthcheck user
HAPROXY_STATS_PASSWORD=...        # mật khẩu HAProxy stats UI
PGADMIN_DEFAULT_PASSWORD=...      # mật khẩu login pgAdmin
REDIS_PASSWORD=...                # mật khẩu Redis master + replicas
REDIS_SENTINEL_PASSWORD=...       # mật khẩu Sentinel nodes
GRAFANA_ADMIN_PASSWORD=...        # nếu bật monitoring
MINIO_ROOT_PASSWORD=...           # nếu bật MinIO
PGBACKREST_REPO2_CIPHER_PASS=...  # nếu bật MinIO/S3 backup
PGBACKREST_S3_KEY_SECRET=...      # nếu bật MinIO/S3 backup
```

> **Lưu ý**: KHÔNG dùng password chỉ chứa số (vd. `123`) — YAML parse thành integer và Patroni crash khi bootstrap. Password cũng không được chứa ký tự `"`. Xem [Troubleshooting](#troubleshooting).

### 2. Up cluster + pgAdmin

```bat
make.bat up-dev
```

Hoặc Docker CLI:

```powershell
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

Đợi 60-90s lần đầu để Patroni initdb + clone replica. Verify:

```bat
make.bat status
make.bat patroni-list
```

`patroni-list` phải có 1 row `Role=Leader Status=running` và 2 row `Role=Replica Status=streaming`.

### 3. Mở pgAdmin

Trình duyệt: <http://localhost:8080>

| Field | Lấy từ `.env` |
|---|---|
| Email | `PGADMIN_DEFAULT_EMAIL` (mặc định `admin@example.com`) |
| Password | `PGADMIN_DEFAULT_PASSWORD` |

> Truy cập pgAdmin từ **máy khác** (LAN/VPN): set `PGADMIN_HOST=0.0.0.0` + `PGADMIN_SERVER_MODE=True` trong `.env` rồi `docker compose ... up -d --force-recreate pgadmin`. Chi tiết: [Truy cập pgAdmin từ máy khác](#truy-cập-pgadmin-từ-máy-khác-laninternet).

### 4. Register server "Postgres HA — Write" (qua PgBouncer)

Sau khi đăng nhập, trong panel trái:

1. Right-click **Servers → Register → Server**.
2. Tab **General**:
   - Name: `Postgres HA - Write`
3. Tab **Connection**:
   - Host name/address: **`pgbouncer`** *(tên service Docker, KHÔNG dùng `localhost` vì pgAdmin chạy trong container)*
   - Port: **`6432`**
   - Maintenance database: **`app_db_rw`** *(alias PgBouncer route ghi qua HAProxy 5000 → leader)*
   - Username: `app_user` (giá trị `APP_DB_USER`)
   - Password: giá trị `APP_DB_PASSWORD` trong `.env`
   - ☑ Save password
4. Bấm **Save**.

> Lý do dùng `pgbouncer` thay vì `localhost`: pgAdmin chạy trong container, `localhost` là chính nó. PostgreSQL/PgBouncer/HAProxy nằm cùng Docker network `pg-ha` nên dùng tên service. Nếu connect từ tool ngoài Docker (DBeaver/TablePlus trên host), mới dùng `localhost`.

> **Muốn CREATE DATABASE trong pgAdmin?** `app_user` chỉ là owner của `app_db`, **không** có quyền `CREATEDB`. Login bằng user **`admin`** thay vì `app_user` (xem [Tạo admin DBA superuser](#tạo-admin-dba-superuser)) — sau đó pgAdmin sẽ cho menu *Create → Database*.

### 5. Tạo server thứ 2 "Postgres HA — Read" (rw/ro pattern)

Lặp lại bước 4 với:

| Field | Giá trị |
|---|---|
| Name | `Postgres HA - Read` |
| Host | `pgbouncer` |
| Port | `6432` |
| Maintenance database | `app_db_ro` *(route đọc qua HAProxy 5001 → replica)* |
| Username | `app_user` |
| Password | `APP_DB_PASSWORD` |

### 6. Query đầu tiên — verify routing

Click chuột vào server `Postgres HA - Write` → **Tools → Query Tool**, paste:

```sql
SELECT
  CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'leader' END AS role,
  inet_server_addr() AS server_ip,
  current_database() AS db,
  current_user AS user_name;
```

Kỳ vọng: `role = leader`. Lặp tương tự ở `Postgres HA - Read` → kỳ vọng `role = replica`.

Tới đây bạn đã connect thành công. Đọc tiếp [Thêm database mới](#thêm-database-mới) để dùng autosync khi tạo DB qua pgAdmin, hoặc [pgAdmin chi tiết](#pgadmin-cho-môi-trường-dev) cho test failover, query show pools, troubleshooting.

## Tạo admin DBA superuser

`APP_DB_USER` (mặc định `app_user`) chỉ là owner của `APP_DB_NAME` — pgAdmin sẽ ẩn menu *Create → Database / Login Role / Tablespace*. Để có toàn quyền quản trị, repo sinh thêm role `ADMIN_DB_USER` (mặc định `admin`) với `LOGIN SUPERUSER CREATEDB CREATEROLE`.

| Cluster đang ở trạng thái | Cách bật admin |
|---|---|
| **Mới**, chưa từng `up` lần nào | Khai báo `ADMIN_DB_USER`/`ADMIN_DB_PASSWORD` trong `.env` rồi `make up-dev`. `post-init.sh` sẽ tự tạo trong lần initdb đầu tiên. |
| **Đang chạy** (đã initdb) | Khai báo 2 biến trong `.env` rồi chạy `make create-admin` (Linux/macOS) / `make.bat create-admin` (Windows cmd) / `.\make.ps1 create-admin` (PowerShell). Script idempotent: lần sau nếu đổi password chỉ cần chạy lại. |

```ini
# .env
ADMIN_DB_USER=admin
ADMIN_DB_PASSWORD=123        # CHỈ DEV. Production: dùng password mạnh.
```

Sau đó login pgAdmin bằng:

| Field | Giá trị |
|---|---|
| Host | `pgbouncer` (trong pgAdmin container) hoặc `localhost` (DBeaver/TablePlus trên host) |
| Port | `6432` (qua PgBouncer) hoặc `5000` (HAProxy write trực tiếp) |
| Maintenance database | `postgres` *(superuser nên có thể browse mọi DB)* |
| Username | `admin` |
| Password | `123` |

> Khi đổi `ADMIN_DB_PASSWORD` trong `.env`: chạy `make create-admin` để cập nhật role trong Postgres, rồi `docker compose up -d --force-recreate pgbouncer` để PgBouncer pick up password mới trong `userlist.txt`.

> **Cảnh báo bảo mật**: `admin` có quyền tương đương `postgres` (superuser). Đừng dùng password `123` trên cluster có public IP / shared LAN — đổi sang password mạnh trước khi expose.

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

### Thêm database mới

Có 2 cách: **(1) auto** qua sidecar `pgbouncer-autosync` (mặc định bật), hoặc **(2) manual** qua biến `APP_DBS_EXTRA` trong `.env`. Cả hai đều sinh đúng 3 alias `<db>`, `<db>_rw`, `<db>_ro`.

#### Cách 1 — Auto (recommended): pgbouncer-autosync sidecar

Sidecar `pg-pgbouncer-autosync` chạy song song với pgbouncer, mỗi `PGBOUNCER_AUTOSYNC_INTERVAL` giây (mặc định 30s) query `pg_database` qua HAProxy write port → so với `pgbouncer.ini` → có DB mới thì re-render và gửi `RELOAD;` qua PgBouncer admin (online, không disconnect client).

```bash
# 1. Tạo DB trong Postgres — qua pgAdmin, code, hoặc psql:
docker exec -it pg-1 psql -U postgres -c "CREATE DATABASE shop_db OWNER app_user;"
# (hoặc click chuột trong pgAdmin → Create → Database)

# 2. Đợi tối đa 30s. Hết. Không cần sửa .env, không restart gì.
docker logs pg-pgbouncer-autosync | tail -3
# 2026-... [autosync] drift detected — added: [shop_db], removed: [<none>]
# 2026-... [autosync] RELOAD ok — pgbouncer.ini now routes: app_db shop_db

# 3. Connect ngay:
psql -h <host> -p 6432 -U app_user -d shop_db_rw   # write → leader
psql -h <host> -p 6432 -U app_user -d shop_db_ro   # read  → replicas
```

DROP DATABASE cũng được xử lý — autosync xoá entry tương ứng và RELOAD.

##### Tạo DB qua pgAdmin GUI (no-CLI)

1. Trong pgAdmin, kết nối server `Postgres HA - Write` (xem [Bắt đầu nhanh](#bắt-đầu-nhanh-up--login-pgadmin--query) bước 4 để register).
2. Right-click **Databases → Create → Database…**.
3. Tab **General**:
   - Database: `shop_db` *(tên DB mới — chỉ ký tự `[a-zA-Z0-9_]`, không dùng `-` hay khoảng trắng)*
   - Owner: `app_user` *(user ứng dụng đã có trong PgBouncer userlist)*
4. Bấm **Save**. DB mới xuất hiện trong cây bên trái.
5. Đợi ≤ 30 giây (theo `PGBOUNCER_AUTOSYNC_INTERVAL`). Verify ở terminal:
   ```bash
   docker logs pg-pgbouncer-autosync | tail -3
   # → [autosync] drift detected — added: [shop_db]
   # → [autosync] RELOAD ok — pgbouncer.ini now routes: app_db shop_db
   ```
6. Trong pgAdmin, register thêm 1 server mới qua PgBouncer alias mới (vì pgAdmin connect 1 maintenance database tại 1 server):

   | Field | Giá trị |
   |---|---|
   | Name | `shop_db (rw)` |
   | Host | `pgbouncer` |
   | Port | `6432` |
   | Maintenance database | `shop_db_rw` |
   | Username | `app_user` |
   | Password | `APP_DB_PASSWORD` |

   Lặp lại với `shop_db_ro` cho read endpoint nếu cần.

> Khi DROP DATABASE qua pgAdmin (right-click DB → Delete/Drop), autosync cũng tự xoá 3 alias `<db>`, `<db>_rw`, `<db>_ro` khỏi `pgbouncer.ini` trong vòng 30s.

##### Tinh chỉnh sidecar trong `.env`

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `PGBOUNCER_AUTOSYNC_ENABLED` | `true` | `false` → tắt sidecar (sleep infinity, 0 reload) |
| `PGBOUNCER_AUTOSYNC_INTERVAL` | `30` | Giây giữa các lần poll |
| `PGBOUNCER_AUTOSYNC_EXCLUDE` | `postgres,template0,template1` | DB không expose qua PgBouncer |
| `PGBOUNCER_AUTOSYNC_INITIAL_DELAY` | `15` | Giây đợi sau khi start trước khi poll lần đầu |

#### Cách 2 — Manual: biến `APP_DBS_EXTRA`

Nếu tắt sidecar (`PGBOUNCER_AUTOSYNC_ENABLED=false`) hoặc muốn pre-route DB **chưa tồn tại** trong Postgres:

```bash
# 1. Tạo DB (nếu chưa)
docker exec -it pg-1 psql -U postgres -c "CREATE DATABASE shop_db OWNER app_user;"

# 2. Sửa .env
APP_DBS_EXTRA=shop_db,billing_db,analytics_db

# 3. Force-recreate pgbouncer (~3s, không động core)
docker compose up -d --force-recreate pgbouncer
docker logs pgbouncer | tail -3
# log dòng: databases routed (each with _rw/_ro alias): app_db shop_db ...
```

Sidecar bật mặc định nên `APP_DBS_EXTRA` ít khi cần. Khi sidecar bật **đồng thời** với `APP_DBS_EXTRA`, sidecar coi `APP_DBS_EXTRA` là override list và luôn giữ các DB đó trong `pgbouncer.ini` kể cả khi chưa tồn tại trong Postgres.

#### Lưu ý chung

- Tên DB chỉ chấp nhận `[a-zA-Z0-9_]`. Tên có `-` hoặc ký tự đặc biệt → skip kèm WARNING trong log.
- User `app_user` (`APP_DB_PASSWORD`) dùng chung cho mọi DB. Muốn user riêng → `APP_USERS_EXTRA="user1:pass1,user2:pass2"` + `GRANT` thủ công trong Postgres.
- pgBackRest backup ở mức cluster → DB mới được backup tự động ngay.
- Streaming replication ở mức cluster → DB mới sync sang `pg-2`/`pg-3` ngay khi `CREATE DATABASE` xong.

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
| `APP_DB_USER` | User ứng dụng, ví dụ `app_user` (chỉ owner `APP_DB_NAME`, không có CREATEDB) |
| `APP_DB_PASSWORD` | Password user ứng dụng |
| `ADMIN_DB_USER` | Tên DBA superuser tạo bởi `post-init.sh` / `make create-admin`, ví dụ `admin`. Bỏ trống = bỏ qua. Xem [Tạo admin DBA superuser](#tạo-admin-dba-superuser). |
| `ADMIN_DB_PASSWORD` | Password DBA superuser. **Mặc định `123` chỉ phù hợp dev local** — production phải đổi thành password mạnh. |
| `PG_HEALTHCHECK_USER` | User healthcheck |
| `PG_HEALTHCHECK_PASSWORD` | Password user healthcheck |
| `HAPROXY_STATS_PASSWORD` | Password trang HAProxy stats |
| `PGBOUNCER_POOL_MODE` | Pool mode, mặc định `transaction` |
| `PGBOUNCER_MAX_CLIENT_CONN` | Số client tối đa PgBouncer nhận |
| `PGBOUNCER_DEFAULT_POOL_SIZE` | Số connection backend mặc định mỗi pool |
| `PGBOUNCER_RESERVE_POOL_SIZE` | Số connection dự phòng khi pool đầy, mặc định `20` |
| `APP_DBS_EXTRA` | Pre-route DB chưa tồn tại trong Postgres (vd. `shop_db,billing_db`). Mỗi entry sinh `<db>`, `<db>_rw`, `<db>_ro`. Khi sidecar autosync bật, biến này CHỈ cần khi muốn pre-route DB chưa CREATE. Xem [Thêm database mới](#thêm-database-mới). |
| `PGBACKREST_STANZA` | Tên stanza pgBackRest, mặc định `main` |
| `GRAFANA_ADMIN_USER` | User Grafana (chỉ overlay monitoring) |
| `GRAFANA_ADMIN_PASSWORD` | Password Grafana (chỉ overlay monitoring) |
| `PGADMIN_DEFAULT_EMAIL` | Email đăng nhập pgAdmin (chỉ overlay dev) |
| `PGADMIN_DEFAULT_PASSWORD` | Password pgAdmin (chỉ overlay dev) |

Các biến cho **pgbouncer-autosync sidecar** (auto detect DB mới):

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `PGBOUNCER_AUTOSYNC_ENABLED` | `true` | `false` → tắt sidecar (sleep infinity, 0 reload) |
| `PGBOUNCER_AUTOSYNC_INTERVAL` | `30` | Số giây giữa các lần poll `pg_database` |
| `PGBOUNCER_AUTOSYNC_EXCLUDE` | `postgres,template0,template1` | DB nội bộ không expose qua PgBouncer (comma-separated) |
| `PGBOUNCER_AUTOSYNC_INITIAL_DELAY` | `15` | Số giây đợi sau khi start trước khi poll lần đầu (cho pgbouncer kịp render config) |

Các biến **Redis Sentinel HA**:

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `REDIS_PASSWORD` | `CHANGE_ME` | Password cho Redis nodes (master + replicas). Dùng `openssl rand -base64 32` |
| `REDIS_SENTINEL_PASSWORD` | `CHANGE_ME` | Password cho Sentinel nodes (client phải AUTH để query sentinel) |
| `REDIS_MAXMEMORY` | `512mb` | Memory limit cho mỗi Redis node |
| `REDIS_SENTINEL_DOWN_AFTER_MS` | `5000` | Thời gian sentinel đợi trước khi đánh dấu master down (ms). Production: 10000–30000 |
| `REDIS_SENTINEL_FAILOVER_TIMEOUT_MS` | `30000` | Tổng deadline cho failover (ms) |
| `REDIS_SENTINEL_PARALLEL_SYNCS` | `1` | Số replica được reconfig song song sau promote (1 = an toàn nhất) |
| `REDIS_SENTINEL_QUORUM` | `2` | Tối thiểu sentinel đồng ý master down. Luôn (N/2)+1 |
| `REDIS_REPLICA_1_PRIORITY` | `100` | Replica priority — thấp hơn = ưu tiên promote (0 = không bao giờ) |
| `REDIS_REPLICA_2_PRIORITY` | `90` | Replica 2 được ưu tiên promote hơn replica 1 |
| `REDIS_SENTINEL_ANNOUNCE_IP` | *(trống)* | Chỉ cần nếu client ở NGOÀI docker network. Ví dụ: `192.168.1.50` |

Các biến **pgAdmin + Redis Insight** (overlay dev):

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `PGADMIN_HOST` | `127.0.0.1` | Interface host bind cổng pgAdmin. Set `0.0.0.0` để truy cập từ máy khác (LAN/VPN) |
| `PGADMIN_PORT` | `8080` | Cổng host map vào pgAdmin (đổi nếu trùng cổng khác) |
| `PGADMIN_SERVER_MODE` | `False` | `True` → multi-user + login bắt buộc (recommended khi expose ra ngoài). `False` → desktop mode (single-user) |
| `REDIS_INSIGHT_HOST` | `127.0.0.1` | Interface host bind cổng Redis Insight. Set `0.0.0.0` để truy cập từ máy khác |
| `REDIS_INSIGHT_PORT` | `5540` | Cổng host map vào Redis Insight (đổi nếu trùng cổng khác) |

Các biến **backup repo selector** (chỉ cần khi dùng overlay backup/MinIO):

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `BACKUP_REPO` | `1` | Repo dùng cho `make.bat backup` thủ công (`1` local, `2` MinIO/S3) |
| `BACKUP_REPOS` | `1` | Repo cron tự động ghi (có thể `1`, `2`, hoặc `1,2`) |
| `RESTORE_REPO` | `1` | Repo dùng cho `make.bat restore` |

Các biến **MinIO + S3** (chỉ cần khi bật `docker-compose.minio.yml`): `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`, `MINIO_API_PORT`, `MINIO_CONSOLE_PORT`, `PGBACKREST_S3_*`, `PGBACKREST_REPO2_CIPHER_*`. Xem chi tiết tại [Backup lên MinIO](#backup-lên-minio).

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
| `REDIS_MASTER_PORT` | `6379` | `6379` | Redis master |
| `REDIS_REPLICA_1_PORT` | `6380` | `6379` | Redis replica 1 |
| `REDIS_REPLICA_2_PORT` | `6381` | `6379` | Redis replica 2 |
| `REDIS_SENTINEL_1_PORT` | `26379` | `26379` | Redis Sentinel 1 |
| `REDIS_SENTINEL_2_PORT` | `26380` | `26379` | Redis Sentinel 2 |
| `REDIS_SENTINEL_3_PORT` | `26381` | `26379` | Redis Sentinel 3 |

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
| `redis-status` | `redis-cli info replication` | Xem replication info Redis master |
| `redis-healthcheck` | master role + sentinel discovery | Kiểm tra toàn bộ Redis cluster |
| `redis-cli` | `redis-cli` vào master | Mở redis-cli kết nối master |

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
| Redis master | `localhost` | `6379` | password `REDIS_PASSWORD` |
| Redis replica 1 | `localhost` | `6380` | password `REDIS_PASSWORD` |
| Redis replica 2 | `localhost` | `6381` | password `REDIS_PASSWORD` |
| Sentinel 1 | `localhost` | `26379` | password `REDIS_SENTINEL_PASSWORD` |
| Sentinel 2 | `localhost` | `26380` | password `REDIS_SENTINEL_PASSWORD` |
| Sentinel 3 | `localhost` | `26381` | password `REDIS_SENTINEL_PASSWORD` |
| Redis Insight | `http://localhost:5540` | | GUI quản trị Redis (dev overlay) |

Chuỗi kết nối khuyến nghị cho ứng dụng:

```text
postgres://app_user:APP_DB_PASSWORD@localhost:6432/app_db_rw?sslmode=disable
postgres://app_user:APP_DB_PASSWORD@localhost:6432/app_db_ro?sslmode=disable
```

Nếu ứng dụng tự tách read/write, dùng `app_db_rw` cho ghi và `app_db_ro` cho đọc. Nếu ứng dụng chỉ có một datasource, dùng `app_db_rw` hoặc `app_db`.

Chuỗi kết nối Redis (sentinel-aware):

```text
redis://:<REDIS_PASSWORD>@localhost:6379          # direct master
redis-sentinel://localhost:26379,localhost:26380,localhost:26381/mymaster  # sentinel discovery
```

App nên dùng sentinel-aware client để tự phát hiện master mới sau failover. Xem [Redis Sentinel HA](#redis-sentinel-ha) để biết cách kết nối từ code.

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

## Redis Sentinel HA

Stack tích hợp sẵn Redis Sentinel HA gồm 1 master + 2 replicas + 3 sentinels, chạy chung network `pg-ha` với PostgreSQL. Sentinel tự giám sát master và trigger failover khi master down (quorum 2/3).

### Kiến trúc Redis Sentinel

```text
Sentinel-1 (:26379)  Sentinel-2 (:26380)  Sentinel-3 (:26381)
     │                    │                    │
     └────────────────────┼────────────────────┘
                          │  monitor "mymaster"
                          ▼
                   ┌─────────────┐
                   │ redis-master│  :6379  (ghi + đọc)
                   └──────┬──────┘
                          │ replication
              ┌───────────┴───────────┐
              ▼                       ▼
      ┌───────────────┐       ┌───────────────┐
      │ redis-replica-1│      │ redis-replica-2│
      │   :6380        │      │   :6381        │
      └───────────────┘       └───────────────┘
```

- **Sentinel group name**: `mymaster` (hardcoded, phù hợp với repo redis_sentinel gốc)
- **Quorum**: 2 — tối thiểu 2/3 sentinel đồng ý master down mới trigger failover
- **Failover timeout**: 30s (tuỳ chỉnh qua `REDIS_SENTINEL_FAILOVER_TIMEOUT_MS`)
- **Replica priority**: replica-2 (priority 90) được ưu tiên promote trước replica-1 (priority 100)

### Chạy Redis cùng PostgreSQL

Redis nằm trong `docker-compose.yml` (core stack), nên khi chạy `make up` hoặc `docker compose up -d`, Redis tự động được khởi động cùng PostgreSQL:

```bash
# Linux/macOS
make up

# Windows
make.bat up

# Hoặc Docker CLI
docker compose up -d --build
```

Kiểm tra Redis healthy:

```bash
# Linux/macOS
make redis-healthcheck

# Hoặc thủ công
docker compose ps | grep redis
```

Output mong đợi: tất cả 6 Redis containers ở trạng thái `healthy`.

### Kết nối Redis từ code

#### Kết nối trực tiếp (direct)

Phù hợp cho dev/test — kết nối thẳng vào master đã biết:

```text
redis://:<REDIS_PASSWORD>@localhost:6379
```

#### Kết nối qua Sentinel (recommended cho production)

Sentinel-aware client tự phát hiện master hiện tại và chuyển sang master mới sau failover:

**Node.js** (ioredis):

```bash
npm install ioredis
```

```js
const Redis = require("ioredis");

const redis = new Redis({
  sentinels: [
    { host: "localhost", port: 26379 },
    { host: "localhost", port: 26380 },
    { host: "localhost", port: 26381 },
  ],
  name: "mymaster",
  password: process.env.REDIS_PASSWORD || "CHANGE_ME",
  sentinelPassword: process.env.REDIS_SENTINEL_PASSWORD || "CHANGE_ME",
});

redis.on("connect", () => console.log("Redis connected"));
redis.on("error", (err) => console.error("Redis error:", err));

// Ví dụ set/get
await redis.set("hello", "world");
const val = await redis.get("hello");
console.log(val); // "world"
```

> **Lưu ý**: nếu Redis chạy trong Docker và app chạy ngoài Docker trên cùng host, dùng `localhost` với các port đã bind (6379, 26379-26381). Nếu app cũng chạy trong Docker cùng network `pg-ha`, dùng tên service: `redis-master`, `redis-sentinel-1`, v.v.

**Python** (redis-py):

```bash
pip install redis
```

```python
import os
from redis.sentinel import Sentinel

sentinel = Sentinel(
    [("localhost", 26379), ("localhost", 26380), ("localhost", 26381)],
    sentinel_kwargs={"password": os.getenv("REDIS_SENTINEL_PASSWORD", "CHANGE_ME")},
    password=os.getenv("REDIS_PASSWORD", "CHANGE_ME"),
)

# Lấy master connection
master = sentinel.master_for("mymaster")
master.set("hello", "world")
print(master.get("hello"))  # b"world"

# Lấy replica connection (chỉ đọc)
replica = sentinel.slave_for("mymaster")
print(replica.get("hello"))  # b"world"
```

**Go** (go-redis):

```bash
go get github.com/redis/go-redis/v9
```

```go
package main

import (
	"context"
	"fmt"
	"log"
	"os"

	"github.com/redis/go-redis/v9"
)

func main() {
	ctx := context.Background()

	password := os.Getenv("REDIS_PASSWORD")
	if password == "" {
		password = "CHANGE_ME"
	}
	sentinelPassword := os.Getenv("REDIS_SENTINEL_PASSWORD")
	if sentinelPassword == "" {
		sentinelPassword = "CHANGE_ME"
	}

	rdb := redis.NewFailoverClient(&redis.FailoverOptions{
		MasterName:       "mymaster",
		SentinelAddrs:    []string{"localhost:26379", "localhost:26380", "localhost:26381"},
		Password:         password,
		SentinelPassword: sentinelPassword,
	})
	defer rdb.Close()

	if err := rdb.Set(ctx, "hello", "world", 0).Err(); err != nil {
		log.Fatal(err)
	}
	val, _ := rdb.Get(ctx, "hello").Result()
	fmt.Println(val) // "world"
}
```

**NestJS** (ioredis + @nestjs/cache-manager hoặc trực tiếp):

```bash
npm install ioredis
```

```ts
// redis.provider.ts
import Redis from "ioredis";

export const redisProvider = {
  provide: "REDIS_CLIENT",
  useFactory: () => {
    return new Redis({
      sentinels: [
        { host: "localhost", port: 26379 },
        { host: "localhost", port: 26380 },
        { host: "localhost", port: 26381 },
      ],
      name: "mymaster",
      password: process.env.REDIS_PASSWORD || "CHANGE_ME",
      sentinelPassword: process.env.REDIS_SENTINEL_PASSWORD || "CHANGE_ME",
    });
  },
};
```

### Makefile targets cho Redis

| Target | Ý nghĩa |
|---|---|
| `make redis-status` | Hiện replication info từ master (`role`, `connected_slaves`, danh sách slave) |
| `make redis-healthcheck` | Kiểm tra toàn bộ cluster: master role + sentinel master discovery |
| `make redis-cli` | Mở `redis-cli` kết nối trực tiếp vào master (đã auth sẵn) |

Ví dụ:

```bash
# Kiểm tra cluster
make redis-healthcheck

# Output mong đợi:
# --- Redis Master role ---
# role:master
# connected_slaves:2
# slave0:ip=...,port=6379,state=online,...
# slave1:ip=...,port=6379,state=online,...
#
# --- Sentinel master discovery ---
# 1) "redis-master"
# 2) "6379"
```

### Test Redis failover

```bash
# 1. Kiểm tra master hiện tại
make redis-healthcheck

# 2. Dừng master
docker stop redis-master

# 3. Đợi ~10s cho sentinel phát hiện + failover
sleep 10

# 4. Kiểm tra master mới — sentinel sẽ promote 1 replica
docker exec redis-sentinel-1 redis-cli -p 26379 \
  -a "$REDIS_SENTINEL_PASSWORD" --no-auth-warning \
  sentinel get-master-addr-by-name mymaster

# 5. Khởi động lại master cũ — tự rejoin làm replica
docker start redis-master

# 6. Verify lại cluster
make redis-healthcheck
```

### Cấu hình Redis chi tiết

Config files nằm trong `redis/config/`:

| File | Vai trò |
|---|---|
| `redis-master.conf` | Config master: RDB + AOF persistence, memory management, defrag, replication tuning |
| `redis-replica.conf` | Config replica: noeviction policy, replication settings, persistence |

Scripts nằm trong `redis/scripts/`:

| File | Vai trò |
|---|---|
| `master-entrypoint.sh` | Khởi động redis-server với password và maxmemory |
| `replica-entrypoint.sh` | Khởi động redis-server với replicaof, password, priority |
| `sentinel-entrypoint.sh` | Bootstrap sentinel.conf từ env vars, bảo toàn state khi restart |
| `healthcheck-master.sh` | Kiểm tra PING + role (chấp nhận cả master và slave để tránh kill container sau demote) |
| `healthcheck-replica.sh` | Kiểm tra PING + master_link_status + replication lag |
| `healthcheck-sentinel.sh` | Kiểm tra PING + ACL + master discovery |

### Lỗi thường gặp Redis

| Lỗi | Nguyên nhân | Cách xử lý |
|---|---|---|
| `NOAUTH Authentication required` | Thiếu password khi kết nối | Thêm `-a "$REDIS_PASSWORD"` hoặc set password trong client config |
| `READONLY You can't write against a read only replica` | App đang ghi vào replica | Dùng sentinel-aware client để tự route vào master |
| Sentinel không phát hiện master | Sentinel chưa healthy hoặc sai config | Kiểm tra `docker logs redis-sentinel-1`, verify `REDIS_PASSWORD` và `REDIS_SENTINEL_PASSWORD` |
| Container redis-master restart loop | Password chứa ký tự đặc biệt shell không escape được | Dùng password chỉ chứa alphanumeric + `_-=+` |
| Failover không xảy ra sau khi stop master | Quorum chưa đủ (< 2 sentinel healthy) | Kiểm tra `docker compose ps` — cần ít nhất 2/3 sentinel healthy |
| `OOM command not allowed` trên replica | Replica dùng `noeviction` policy và hết memory | Tăng `REDIS_MAXMEMORY` hoặc giảm data size |

### Lưu ý production cho Redis

- Đổi `REDIS_PASSWORD` và `REDIS_SENTINEL_PASSWORD` sang password mạnh (dùng `openssl rand -base64 32`)
- Tăng `REDIS_SENTINEL_DOWN_AFTER_MS` lên 10000–30000ms trong môi trường network không ổn định
- Không public port Redis (6379-6381) và Sentinel (26379-26381) ra Internet — dùng firewall/private network
- Nếu client nằm ngoài Docker network, set `REDIS_SENTINEL_ANNOUNCE_IP` thành IP host để sentinel trả đúng address
- Monitor Redis bằng `redis-cli info` hoặc tích hợp redis-exporter vào Prometheus (chưa có sẵn trong repo)
- Compose này phù hợp single-host. Production thật nên trải Redis nodes qua nhiều host/AZ giống PostgreSQL

## Redis Insight

[Redis Insight](https://redis.io/insight/) là GUI chính thức của Redis để quản trị, debug và tối ưu Redis qua trình duyệt. Service nằm trong `docker-compose.dev.yml` (cùng overlay với pgAdmin).

### Khởi động Redis Insight

```bash
# Chạy cùng pgAdmin (dev overlay)
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d

# Hoặc Windows
make.bat up-dev
```

Mở trình duyệt: <http://localhost:5540>

> Truy cập Redis Insight từ **máy khác** (LAN/VPN): set `REDIS_INSIGHT_HOST=0.0.0.0` trong `.env` rồi `docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --force-recreate redis-insight`.

### Thêm database Redis vào Insight

Sau khi mở Redis Insight, bấm **+ Add Redis Database** và điền:

#### Kết nối Redis master (trong Docker network)

| Field | Giá trị |
|---|---|
| Host | `redis-master` *(tên service Docker, vì Redis Insight chạy cùng network `pg-ha`)* |
| Port | `6379` |
| Password | Giá trị `REDIS_PASSWORD` trong `.env` |
| Database Alias | `Redis Master` |

#### Kết nối Redis replica (read-only)

| Field | Giá trị |
|---|---|
| Host | `redis-replica-1` hoặc `redis-replica-2` |
| Port | `6379` *(port container, KHÔNG phải host port 6380/6381)* |
| Password | Giá trị `REDIS_PASSWORD` trong `.env` |
| Database Alias | `Redis Replica 1` hoặc `Redis Replica 2` |

> **Lưu ý**: Redis Insight chạy trong cùng Docker network `pg-ha`, nên dùng **tên service** (`redis-master`, `redis-replica-1`) và **port container** (`6379`), KHÔNG dùng `localhost` hay port host (`6380`, `6381`). Nếu kết nối từ tool ngoài Docker (trên host), mới dùng `localhost:6379/6380/6381`.

### Tính năng chính của Redis Insight

| Tính năng | Mô tả |
|---|---|
| **Browser** | Duyệt tất cả keys, filter theo pattern, xem/sửa giá trị (string, hash, list, set, sorted set, stream, JSON) |
| **Workbench** | Chạy lệnh Redis trực tiếp (như redis-cli nhưng có autocomplete, syntax highlight) |
| **Slow Log** | Xem các lệnh chậm (> `slowlog-log-slower-than`) để tối ưu performance |
| **Pub/Sub** | Subscribe channel và xem message real-time |
| **Streams** | Quản lý Redis Streams, xem consumer groups, pending entries |
| **Profiler** | Monitor tất cả lệnh Redis real-time (tương đương `MONITOR` command) |
| **Cluster Overview** | Xem topology replication, memory usage, connected clients |

### Biến môi trường Redis Insight

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `REDIS_INSIGHT_HOST` | `127.0.0.1` | Interface host bind cổng Redis Insight. Set `0.0.0.0` để truy cập từ máy khác |
| `REDIS_INSIGHT_PORT` | `5540` | Cổng host map vào Redis Insight (đổi nếu trùng cổng khác) |

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

### Production MinIO/S3 backup

Trong production, không nên coi Docker volume local là backup chính. Nên dùng object storage bên ngoài host PostgreSQL:

```text
PostgreSQL HA cluster -> pgBackRest repo2 -> external MinIO/S3
```

Khuyến nghị:

| Thành phần | Cấu hình production |
|---|---|
| `repo1` | Local volume, tùy chọn, dùng để restore nhanh trong cùng host |
| `repo2` | MinIO/S3 bên ngoài cluster PostgreSQL, dùng làm backup chính |
| MinIO | Multi-node multi-drive, khác host/rack/AZ với PostgreSQL |
| TLS | Dùng certificate thật và `PGBACKREST_S3_VERIFY_TLS=y` |
| Mã hóa | Bật pgBackRest client-side encryption cho repo2 |
| Restore | Test restore định kỳ, không chỉ test backup thành công |

Ví dụ `.env` cho production dùng repo2 làm backup chính:

```env
BACKUP_REPO=2
RESTORE_REPO=2
BACKUP_REPOS=2

PGBACKREST_S3_ENDPOINT=minio-prod.example.com:9000
PGBACKREST_S3_BUCKET=postgres-backup-prod
PGBACKREST_S3_REGION=us-east-1
PGBACKREST_S3_KEY=pgbackrest-prod
PGBACKREST_S3_KEY_SECRET=<strong-secret>
PGBACKREST_S3_PATH=/postgres-ha
PGBACKREST_S3_URI_STYLE=path
PGBACKREST_S3_VERIFY_TLS=y

PGBACKREST_REPO2_RETENTION_FULL=7
PGBACKREST_REPO2_RETENTION_DIFF=14
PGBACKREST_REPO2_CIPHER_TYPE=aes-256-cbc
PGBACKREST_REPO2_CIPHER_PASS=<very-strong-backup-encryption-key>
```

Nếu muốn vừa giữ local backup ngắn hạn vừa đẩy lên MinIO/S3 trong cùng một lịch cron:

```env
BACKUP_REPOS=1,2
RESTORE_REPO=2
```

`BACKUP_REPOS=1,2` sẽ chạy pgBackRest backup lần lượt vào repo1 và repo2. Cách này tốn thêm I/O, CPU và dung lượng, nhưng có hai lợi ích: repo1 restore nhanh trong sự cố nhỏ, repo2 dùng cho disaster recovery khi mất host/local volume.

Sau khi đổi các biến pgBackRest/S3, recreate các node PostgreSQL và backup scheduler để render lại `/etc/pgbackrest/pgbackrest.conf`:

```powershell
docker compose -f docker-compose.yml -f docker-compose.minio.yml -f docker-compose.backup.yml up -d --build --force-recreate pg-1 pg-2 pg-3 backup
```

Kiểm tra repo2:

```powershell
docker exec -u postgres pg-1 pgbackrest --stanza=main --repo=2 info
```

Chạy full backup thử vào repo2:

```bat
make.bat backup-s3
```

## Cấu hình Prometheus và Grafana

Monitoring nằm trong file `docker-compose.monitoring.yml`. Overlay này thêm 5 service:

| Service | Image | Vai trò |
|---|---|---|
| `postgres-exporter-1` | `prometheuscommunity/postgres-exporter:v0.19.1` | Lấy metrics từ `pg-1:5432` |
| `postgres-exporter-2` | `prometheuscommunity/postgres-exporter:v0.19.1` | Lấy metrics từ `pg-2:5432` |
| `postgres-exporter-3` | `prometheuscommunity/postgres-exporter:v0.19.1` | Lấy metrics từ `pg-3:5432` |
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

pgAdmin nằm trong overlay `docker-compose.dev.yml`. Mặc định bind `127.0.0.1:8080` (chỉ truy cập từ máy host) để an toàn. Overlay này phụ thuộc vào `pgbouncer`, nên khi chạy `up-dev` Compose sẽ chạy core stack trước rồi mới chạy pgAdmin.

### Truy cập pgAdmin từ máy khác (LAN/internet)

Mặc định pgAdmin chỉ nghe trên `127.0.0.1` của host. Để máy khác truy cập được, set 2 biến trong `.env`:

```ini
PGADMIN_HOST=0.0.0.0          # bind mọi interface (cho phép remote)
PGADMIN_PORT=8080             # cổng host (đổi nếu trùng)
PGADMIN_SERVER_MODE=True      # bật multi-user + login bắt buộc
```

Sau đó restart pgAdmin (volume `pgadmin-data` được giữ nguyên, không mất user/server đã save):

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --force-recreate pgadmin
```

Truy cập từ máy khác qua `http://<IP-host>:8080`. Kiểm tra cổng đã listen đúng:

```bash
docker port pgadmin
# ra: 80/tcp -> 0.0.0.0:8080
```

Nếu vẫn không vào được:
- Mở firewall của host (Linux: `sudo ufw allow 8080/tcp`; Windows: tạo Inbound Rule cho cổng `8080`).
- Nếu host có IP public, **không** để `0.0.0.0` trần — đặt phía sau VPN, hoặc dùng reverse proxy (Nginx/Caddy/Traefik) với TLS + auth tầng ngoài.
- Khi đã đặt `PGADMIN_SERVER_MODE=True` lần đầu, pgAdmin yêu cầu đăng ký lại admin từ container đã khởi tạo. Nếu cần reset sạch, xoá volume:
  ```bash
  docker compose -f docker-compose.yml -f docker-compose.dev.yml down
  docker volume rm postgresql_ha_pgadmin-data   # tên volume có thể khác tùy project name
  docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d
  ```

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

`app_user` đã được cấu hình là `stats_users` + `admin_users` trong `pgbouncer.ini` (xem [`scripts/build-pgbouncer-ini.sh`](scripts/build-pgbouncer-ini.sh)) nên có quyền chạy các lệnh quản trị `SHOW DATABASES`, `SHOW POOLS`, `SHOW CLIENTS`, `RELOAD`. Output `SHOW DATABASES` trả về toàn bộ alias đang được route — nếu autosync đã chạy xong, các DB tạo qua pgAdmin/CLI cũng xuất hiện ở đây:

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

Patroni crash khi bootstrap với lỗi `AttributeError: 'int' object has no attribute 'encode'`:

```text
File ".../patroni/postgresql/bootstrap.py", line 131, in _initdb
    os.write(fd, self._postgresql.config.superuser['password'].encode('utf-8'))
AttributeError: 'int' object has no attribute 'encode'
```

Nguyên nhân: password trong `.env` chỉ chứa số (vd. `PATRONI_SUPERUSER_PASSWORD=123`). Sau khi `envsubst` thay vào template YAML, YAML parse thành integer thay vì string. Template hiện tại đã bọc tất cả `${VAR}` password/username bằng dấu nháy YAML nên fix sẵn — nếu vẫn gặp lỗi:

1. Dừng và xoá volume cũ để Patroni bootstrap lại sạch:
   ```bash
   docker compose down -v
   docker compose up -d
   ```
2. Lưu ý: password **không được chứa ký tự `"`** (vì template dùng double-quote để bọc). Nếu cần `"` trong password, đổi sang ký tự khác hoặc escape thủ công.

Xem log tập trung:

```bat
make.bat logs
```

Build lại sạch khi nghi lỗi line ending hoặc image cũ:

```bat
make.bat rebuild
make.bat up
```
