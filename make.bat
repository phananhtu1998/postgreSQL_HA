@echo off
REM ====================================================================
REM  make.bat — Windows dispatcher for the Postgres HA stack.
REM  Mirrors every target in the GNU Makefile so Windows users without
REM  `make` installed can do the same operations.
REM
REM  Requirements:
REM    - Docker Desktop (with WSL2 backend recommended)
REM    - Git for Windows (provides `bash`, `curl`, `jq` on PATH)
REM      Download: https://git-scm.com/download/win
REM
REM  Usage:
REM     make.bat help
REM     make.bat up              REM core stack
REM     make.bat up-monitoring   REM core + Prometheus/Grafana/exporters
REM     make.bat up-backup       REM core + cron pgBackRest
REM     make.bat up-dev          REM core + pgAdmin (localhost only)
REM     make.bat up-all          REM everything
REM     make.bat down
REM     make.bat down-all
REM     make.bat status
REM     make.bat logs
REM     make.bat patroni-list
REM     make.bat failover-test
REM     make.bat backup
REM     make.bat backup-full
REM     make.bat restore pg-2 [latest]
REM     make.bat psql-write
REM     make.bat psql-read
REM     make.bat build
REM     make.bat rebuild
REM     make.bat nuke
REM ====================================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"

set "PAUSE_ON_EXIT=0"
echo(%CMDCMDLINE% | find /I " /c " >nul 2>&1 && set "PAUSE_ON_EXIT=1"
set "INTERACTIVE=0"

set "COMPOSE=docker compose"
set "C_CORE=-f docker-compose.yml"
set "C_MON=-f docker-compose.monitoring.yml"
set "C_BAK=-f docker-compose.backup.yml"
set "C_DEV=-f docker-compose.dev.yml"
set "C_MINIO=-f docker-compose.minio.yml"
set "C_ALL=%C_CORE% %C_MON% %C_BAK% %C_DEV% %C_MINIO%"

if "%~1"=="" (
  set "INTERACTIVE=1"
  goto :interactive_prompt
)
set "TARGET=%~1"

:dispatch
if /i "%TARGET%"=="help"             goto :help
if /i "%TARGET%"=="up"                goto :up
if /i "%TARGET%"=="up-monitoring"     goto :up_monitoring
if /i "%TARGET%"=="up-backup"         goto :up_backup
if /i "%TARGET%"=="up-dev"            goto :up_dev
if /i "%TARGET%"=="up-minio"          goto :up_minio
if /i "%TARGET%"=="up-all"            goto :up_all
if /i "%TARGET%"=="down"              goto :down
if /i "%TARGET%"=="down-all"          goto :down_all
if /i "%TARGET%"=="status"            goto :status
if /i "%TARGET%"=="ps"                goto :status
if /i "%TARGET%"=="logs"              goto :logs
if /i "%TARGET%"=="build"             goto :build
if /i "%TARGET%"=="rebuild"           goto :rebuild
if /i "%TARGET%"=="patroni-list"      goto :patroni_list
if /i "%TARGET%"=="create-admin"      goto :create_admin
if /i "%TARGET%"=="failover-test"     goto :failover_test
if /i "%TARGET%"=="backup"            goto :backup
if /i "%TARGET%"=="backup-full"       goto :backup_full
if /i "%TARGET%"=="backup-s3"         goto :backup_s3
if /i "%TARGET%"=="minio-console"     goto :minio_console
if /i "%TARGET%"=="restore"           goto :restore
if /i "%TARGET%"=="restore-s3"        goto :restore_s3
if /i "%TARGET%"=="psql-write"        goto :psql_write
if /i "%TARGET%"=="psql-read"         goto :psql_read
if /i "%TARGET%"=="clean"             goto :down_all
if /i "%TARGET%"=="nuke"              goto :nuke

echo Unknown target: %TARGET%
echo Run "make.bat help" to list targets.
goto :finish_error

:interactive_prompt
call :print_help
echo.
set /p "TARGET=Nhap lenh (vd: up, status, logs, exit): "
if /i "%TARGET%"=="exit" goto :finish_ok
if /i "%TARGET%"=="quit" goto :finish_ok
if "%TARGET%"=="" goto :interactive_prompt
goto :dispatch

:help
call :print_help
goto :finish_ok

:print_help
echo.
echo PostgreSQL HA -- Windows dispatcher
echo ===================================
echo   up               Start core stack (etcd x3 + Patroni x3 + HAProxy + PgBouncer)
echo   up-monitoring    Start core + Prometheus + Grafana + exporters
echo   up-backup        Start core + cron pgBackRest runner
echo   up-dev           Start core + pgAdmin (localhost only)
echo   up-minio         Start core + MinIO (S3-compatible pgBackRest repo)
echo   up-all           Start everything
echo   down             Stop core stack
echo   down-all         Stop everything
echo   status           Container status
echo   logs             Tail all logs
echo   patroni-list     Show Patroni cluster topology
echo   create-admin     Create/update DBA superuser admin (needs bash on PATH)
echo   failover-test    Run automated failover chaos test (needs bash on PATH)
echo   backup-s3        Full backup targeting MinIO repo only (needs bash)
echo   minio-console    Print MinIO console URL
echo   backup           Incremental pgBackRest backup (needs bash on PATH)
echo   backup-full      Full pgBackRest backup (needs bash on PATH)
echo   restore NODE [SET]  Restore a node (default SET=latest, needs bash)
echo   restore-s3 NODE [SET]  Restore a node from MinIO repo2
echo   psql-write       psql against HAProxy:5000 (write/leader)
echo   psql-read        psql against HAProxy:5001 (read/replicas)
echo   build            Build all images
echo   rebuild          Rebuild without cache
echo   nuke             DANGER: stop and remove containers AND volumes
echo.
echo Requires Docker Desktop + Git for Windows (bash on PATH).
exit /b 0

:up
%COMPOSE% %C_CORE% up -d --build
goto :finish_current

:up_monitoring
%COMPOSE% %C_CORE% %C_MON% up -d --build
goto :finish_current

:up_backup
%COMPOSE% %C_CORE% %C_BAK% up -d --build
goto :finish_current

:up_dev
%COMPOSE% %C_CORE% %C_DEV% up -d --build
goto :finish_current

:up_minio
%COMPOSE% %C_CORE% %C_MINIO% up -d --build
goto :finish_current

:up_all
%COMPOSE% %C_ALL% up -d --build
goto :finish_current

:down
%COMPOSE% %C_CORE% down
goto :finish_current

:down_all
%COMPOSE% %C_ALL% down
goto :finish_current

:status
%COMPOSE% %C_ALL% ps
goto :finish_current

:logs
%COMPOSE% %C_ALL% logs -f --tail=100
goto :finish_current

:build
%COMPOSE% %C_CORE% %C_BAK% build
goto :finish_current

:rebuild
%COMPOSE% %C_CORE% %C_BAK% build --no-cache
goto :finish_current

:patroni_list
docker exec pg-1 patronictl -c /etc/patroni/patroni.yml list
goto :finish_current

:create_admin
where bash >nul 2>&1
if errorlevel 1 (
  echo bash not found on PATH. Install Git for Windows: https://git-scm.com/download/win
  goto :finish_error
)
bash scripts/create-admin.sh
goto :finish_current

:failover_test
where bash >nul 2>&1
if errorlevel 1 (
  echo bash not found on PATH. Install Git for Windows: https://git-scm.com/download/win
  goto :finish_error
)
bash scripts/failover-test.sh
goto :finish_current

:backup
where bash >nul 2>&1
if errorlevel 1 (
  echo bash not found on PATH. Install Git for Windows: https://git-scm.com/download/win
  goto :finish_error
)
set "BACKUP_TYPE=incr"
set "BACKUP_REPO=1"
bash scripts/backup.sh
goto :finish_current

:backup_full
where bash >nul 2>&1
if errorlevel 1 (
  echo bash not found on PATH. Install Git for Windows: https://git-scm.com/download/win
  goto :finish_error
)
set "BACKUP_TYPE=full"
set "BACKUP_REPO=1"
bash scripts/backup.sh
goto :finish_current

:backup_s3
where bash >nul 2>&1
if errorlevel 1 (
  echo bash not found on PATH. Install Git for Windows: https://git-scm.com/download/win
  goto :finish_error
)
set "BACKUP_TYPE=full"
set "BACKUP_REPO=2"
bash scripts/backup.sh
goto :finish_current

:minio_console
call :load_env_var MINIO_CONSOLE_PORT
call :load_env_var MINIO_ROOT_USER
if "%MINIO_CONSOLE_PORT%"=="" set "MINIO_CONSOLE_PORT=9001"
if "%MINIO_ROOT_USER%"=="" set "MINIO_ROOT_USER=minioadmin"
echo MinIO console: https://localhost:%MINIO_CONSOLE_PORT% (user: %MINIO_ROOT_USER%)
echo   Browser will warn about the self-signed cert -- accept it to proceed.
goto :finish_ok

:restore
where bash >nul 2>&1
if errorlevel 1 (
  echo bash not found on PATH. Install Git for Windows: https://git-scm.com/download/win
  goto :finish_error
)
if "%~2"=="" (
  echo Usage: make.bat restore NODE [SET]
  echo Example: make.bat restore pg-2 latest
  goto :finish_error
)
set "NODE=%~2"
set "SET=%~3"
if "%SET%"=="" set "SET=latest"
set "RESTORE_REPO=1"
bash scripts/restore.sh %NODE% %SET%
goto :finish_current

:restore_s3
where bash >nul 2>&1
if errorlevel 1 (
  echo bash not found on PATH. Install Git for Windows: https://git-scm.com/download/win
  goto :finish_error
)
if "%~2"=="" (
  echo Usage: make.bat restore-s3 NODE [SET]
  echo Example: make.bat restore-s3 pg-2 latest
  goto :finish_error
)
set "NODE=%~2"
set "SET=%~3"
if "%SET%"=="" set "SET=latest"
set "RESTORE_REPO=2"
bash scripts/restore.sh %NODE% %SET%
goto :finish_current

:psql_write
call :load_env_var APP_DB_USER
call :load_env_var APP_DB_PASSWORD
call :load_env_var APP_DB_NAME
docker run -it --rm --network pg-ha -e PGPASSWORD=%APP_DB_PASSWORD% postgres:17.2-bookworm psql -h pg-haproxy -p 5000 -U %APP_DB_USER% -d %APP_DB_NAME%
goto :finish_current

:psql_read
call :load_env_var APP_DB_USER
call :load_env_var APP_DB_PASSWORD
call :load_env_var APP_DB_NAME
docker run -it --rm --network pg-ha -e PGPASSWORD=%APP_DB_PASSWORD% postgres:17.2-bookworm psql -h pg-haproxy -p 5001 -U %APP_DB_USER% -d %APP_DB_NAME%
goto :finish_current

:nuke
echo WARNING: this will remove all volumes (data loss).
set /p CONFIRM=Type "yes" to confirm: 
if /i not "%CONFIRM%"=="yes" (
  echo aborted.
  goto :finish_error
)
%COMPOSE% %C_ALL% down -v
goto :finish_current

:load_env_var
REM Reads %1 from .env into the variable named %1.
for /f "usebackq tokens=1,* delims==" %%A in (`type .env ^| findstr /b "%~1="`) do set "%~1=%%B"
exit /b 0

:finish_current
set "EXIT_CODE=%errorlevel%"
goto :finish

:finish_ok
set "EXIT_CODE=0"
goto :finish

:finish_error
set "EXIT_CODE=1"
goto :finish

:finish
if "%INTERACTIVE%"=="1" (
  echo.
  goto :interactive_prompt
)
if "%PAUSE_ON_EXIT%"=="1" (
  echo.
  pause
)
exit /b %EXIT_CODE%
