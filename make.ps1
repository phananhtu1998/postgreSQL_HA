# =====================================================================
#  make.ps1 — PowerShell dispatcher for the Postgres HA stack.
#  Mirrors every target in the GNU Makefile so Windows users without
#  `make` installed can do the same operations from PowerShell.
#
#  Usage:
#     .\make.ps1 help
#     .\make.ps1 up
#     .\make.ps1 up-monitoring
#     .\make.ps1 up-backup
#     .\make.ps1 up-dev
#     .\make.ps1 up-all
#     .\make.ps1 down
#     .\make.ps1 down-all
#     .\make.ps1 status
#     .\make.ps1 logs
#     .\make.ps1 patroni-list
#     .\make.ps1 failover-test
#     .\make.ps1 backup
#     .\make.ps1 backup-full
#     .\make.ps1 restore pg-2 [latest]
#     .\make.ps1 psql-write
#     .\make.ps1 psql-read
#     .\make.ps1 build
#     .\make.ps1 rebuild
#     .\make.ps1 nuke
#
#  Requires Docker Desktop. Targets that run shell scripts also need
#  `bash` on PATH (install Git for Windows: https://git-scm.com/download/win).
#
#  If PowerShell blocks the script, run once:
#     Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
# =====================================================================
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Target = "help",
    [Parameter(Position=1, ValueFromRemainingArguments=$true)][string[]]$Rest
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

$Compose  = @("docker","compose")
$CoreF    = @("-f","docker-compose.yml")
$MonF     = @("-f","docker-compose.monitoring.yml")
$BakF     = @("-f","docker-compose.backup.yml")
$DevF     = @("-f","docker-compose.dev.yml")
$MinioF   = @("-f","docker-compose.minio.yml")
$AllF     = $CoreF + $MonF + $BakF + $DevF + $MinioF

function Run-Compose {
    param([string[]]$Files,[string[]]$Args)
    & $Compose[0] $Compose[1..($Compose.Count-1)] @Files @Args
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Require-Bash {
    if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
        Write-Error "bash not found on PATH. Install Git for Windows: https://git-scm.com/download/win"
        exit 1
    }
}

function Load-Env {
    $envFile = Join-Path $PSScriptRoot ".env"
    if (-not (Test-Path $envFile)) { Write-Error ".env not found"; exit 1 }
    $h = @{}
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*#') { return }
        if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $h[$Matches[1]] = $Matches[2].Trim('"').Trim("'")
        }
    }
    return $h
}

function Show-Help {
@"

PostgreSQL HA -- PowerShell dispatcher
======================================
  up               Start core stack (etcd x3 + Patroni x3 + HAProxy + PgBouncer)
  up-monitoring    Start core + Prometheus + Grafana + exporters
  up-backup        Start core + cron pgBackRest runner
  up-dev           Start core + pgAdmin (localhost only)
  up-minio         Start core + MinIO (S3-compatible pgBackRest repo)
  up-all           Start everything
  down             Stop core stack
  down-all         Stop everything
  status           Container status
  logs             Tail all logs
  patroni-list     Show Patroni cluster topology
  failover-test    Run automated failover chaos test (needs bash)
  backup           Incremental pgBackRest backup (needs bash)
  backup-full      Full pgBackRest backup (needs bash)
  backup-s3        Full pgBackRest backup targeting MinIO repo2 (needs bash)
  minio-console    Print MinIO console URL
  restore NODE [SET]  Restore a node (default SET=latest, needs bash)
  restore-s3 NODE [SET]  Restore a node from MinIO repo2
  psql-write       psql against HAProxy:5000 (write/leader)
  psql-read        psql against HAProxy:5001 (read/replicas)
  build            Build all images
  rebuild          Rebuild without cache
  nuke             DANGER: stop and remove containers AND volumes

Requires Docker Desktop + Git for Windows (bash on PATH for shell-script targets).
"@ | Write-Host
}

switch -Regex ($Target) {
    '^(help|-h|--help)$' { Show-Help }

    '^up$'                { Run-Compose $CoreF                @("up","-d","--build") }
    '^up-monitoring$'     { Run-Compose ($CoreF + $MonF)      @("up","-d","--build") }
    '^up-backup$'         { Run-Compose ($CoreF + $BakF)      @("up","-d","--build") }
    '^up-dev$'            { Run-Compose ($CoreF + $DevF)      @("up","-d","--build") }
    '^up-minio$'          { Run-Compose ($CoreF + $MinioF)    @("up","-d","--build") }
    '^up-all$'            { Run-Compose $AllF                 @("up","-d","--build") }

    '^down$'              { Run-Compose $CoreF                @("down") }
    '^(down-all|clean)$'  { Run-Compose $AllF                 @("down") }

    '^(status|ps)$'       { Run-Compose $AllF                 @("ps") }
    '^logs$'              { Run-Compose $AllF                 @("logs","-f","--tail=100") }

    '^build$'             { Run-Compose ($CoreF + $BakF)      @("build") }
    '^rebuild$'           { Run-Compose ($CoreF + $BakF)      @("build","--no-cache") }

    '^patroni-list$' {
        & docker exec pg-1 patronictl -c /etc/patroni/patroni.yml list
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    '^failover-test$' {
        Require-Bash
        & bash scripts/failover-test.sh
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    '^backup$' {
        Require-Bash
        $env:BACKUP_TYPE = "incr"
        $env:BACKUP_REPO = "1"
        & bash scripts/backup.sh
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    '^backup-full$' {
        Require-Bash
        $env:BACKUP_TYPE = "full"
        $env:BACKUP_REPO = "1"
        & bash scripts/backup.sh
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    '^backup-s3$' {
        Require-Bash
        $env:BACKUP_TYPE = "full"
        $env:BACKUP_REPO = "2"
        & bash scripts/backup.sh
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    '^minio-console$' {
        $e = Load-Env
        $port = if ($e.MINIO_CONSOLE_PORT) { $e.MINIO_CONSOLE_PORT } else { "9001" }
        $user = if ($e.MINIO_ROOT_USER) { $e.MINIO_ROOT_USER } else { "minioadmin" }
        Write-Host "MinIO console: https://localhost:$port (user: $user)"
        Write-Host "Browser will warn about the self-signed cert; accept it to proceed."
    }

    '^restore$' {
        Require-Bash
        if ($Rest.Count -lt 1) {
            Write-Error "Usage: .\make.ps1 restore NODE [SET]"
            exit 1
        }
        $node = $Rest[0]
        $set  = if ($Rest.Count -ge 2) { $Rest[1] } else { "latest" }
        $env:RESTORE_REPO = "1"
        & bash scripts/restore.sh $node $set
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    '^restore-s3$' {
        Require-Bash
        if ($Rest.Count -lt 1) {
            Write-Error "Usage: .\make.ps1 restore-s3 NODE [SET]"
            exit 1
        }
        $node = $Rest[0]
        $set  = if ($Rest.Count -ge 2) { $Rest[1] } else { "latest" }
        $env:RESTORE_REPO = "2"
        & bash scripts/restore.sh $node $set
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    '^psql-write$' {
        $e = Load-Env
        & docker run -it --rm --network pg-ha `
            -e "PGPASSWORD=$($e.APP_DB_PASSWORD)" `
            postgres:17.2-bookworm `
            psql -h pg-haproxy -p 5000 -U $e.APP_DB_USER -d $e.APP_DB_NAME
    }

    '^psql-read$' {
        $e = Load-Env
        & docker run -it --rm --network pg-ha `
            -e "PGPASSWORD=$($e.APP_DB_PASSWORD)" `
            postgres:17.2-bookworm `
            psql -h pg-haproxy -p 5001 -U $e.APP_DB_USER -d $e.APP_DB_NAME
    }

    '^nuke$' {
        Write-Host "WARNING: this will remove all volumes (data loss)." -ForegroundColor Yellow
        $confirm = Read-Host 'Type "yes" to confirm'
        if ($confirm -ne "yes") { Write-Host "aborted."; exit 1 }
        Run-Compose $AllF @("down","-v")
    }

    default {
        Write-Host "Unknown target: $Target"
        Write-Host "Run '.\make.ps1 help' for the list of targets."
        exit 1
    }
}
