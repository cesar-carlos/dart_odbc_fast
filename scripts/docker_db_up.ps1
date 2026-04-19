# Bring up the Docker DB stack used by the E2E suite, wait for every
# container to report healthy, and print one-liner DSN snippets ready to
# paste into `.env`.
#
# Usage:
#   pwsh scripts/docker_db_up.ps1                # PG + MySQL + MariaDB + MSSQL + Oracle
#   pwsh scripts/docker_db_up.ps1 -IncludeDb2    # also start IBM Db2 (slow, ~2 min)
#   pwsh scripts/docker_db_up.ps1 -Down          # tear everything down

[CmdletBinding()]
param(
    [switch]$IncludeDb2,
    [switch]$Down,
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'

function Write-Info($msg)  { Write-Host "[docker_db_up] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "[docker_db_up] $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "[docker_db_up] $msg" -ForegroundColor Yellow }
function Write-Err2($msg)  { Write-Host "[docker_db_up] $msg" -ForegroundColor Red }

# -- Sanity check ---------------------------------------------------------

try {
    $dockerVersion = docker version --format '{{.Server.Version}}' 2>$null
    if (-not $dockerVersion) { throw "docker did not return a server version" }
    Write-Info "Docker server: $dockerVersion"
}
catch {
    Write-Err2 "Docker daemon is not reachable. Is Docker Desktop running?"
    exit 1
}

# -- Down path -----------------------------------------------------------

if ($Down) {
    Write-Info "Stopping the DB stack..."
    docker compose --profile db2 down --volumes --remove-orphans
    Write-Ok "All containers + volumes removed."
    exit 0
}

# -- Compose up ----------------------------------------------------------

$services = @('postgres', 'mysql', 'mariadb', 'mssql', 'oracle')
$composeArgs = @('compose')
if ($IncludeDb2) {
    $composeArgs += @('--profile', 'db2')
    $services += 'db2'
}
$composeArgs += @('up', '-d')
$composeArgs += $services

Write-Info "Bringing up: $($services -join ', ')"
& docker @composeArgs
if ($LASTEXITCODE -ne 0) {
    Write-Err2 "docker compose up failed (exit $LASTEXITCODE)."
    exit $LASTEXITCODE
}

# -- Wait for healthchecks -----------------------------------------------

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
# Use a plain ArrayList for PS5 / PS7 compatibility (no generic HashSet ctor).
$pending = New-Object System.Collections.ArrayList
foreach ($svc in $services) { [void]$pending.Add($svc) }
Write-Info "Waiting for healthchecks (timeout: $TimeoutSeconds s)..."

while ($pending.Count -gt 0) {
    if ((Get-Date) -gt $deadline) {
        Write-Err2 "Timed out waiting for: $($pending -join ', ')"
        Write-Err2 "Check 'docker compose ps' and 'docker logs <service>' for details."
        exit 2
    }

    # Snapshot to a fixed array so we can mutate $pending safely.
    $snapshot = @($pending)
    foreach ($svc in $snapshot) {
        $container = "odbc_test_$svc"
        $state = docker inspect --format '{{.State.Health.Status}}' $container 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $state) {
            # container not yet created or no healthcheck output
            continue
        }
        switch ($state) {
            'healthy' {
                Write-Ok ("  {0,-9} healthy" -f $svc)
                [void]$pending.Remove($svc)
            }
            'unhealthy' {
                Write-Err2 ("  {0,-9} unhealthy. Last 10 log lines:" -f $svc)
                docker logs --tail 10 $container | ForEach-Object { Write-Err2 "      $_" }
                exit 3
            }
            default {
                # starting — keep waiting
            }
        }
    }
    Start-Sleep -Milliseconds 1500
}

Write-Ok "All services are healthy."

# -- Print DSN cheatsheet ------------------------------------------------

Write-Host ""
Write-Host "=== DSN cheatsheet (host -> container) ===========================" -ForegroundColor Magenta
Write-Host "Add ONE of these to your .env (or copy from .env.docker):" -ForegroundColor Magenta
Write-Host ""
Write-Host "PostgreSQL:"
Write-Host "  ODBC_TEST_DSN=Driver={PostgreSQL Unicode};Server=localhost;Port=5432;Database=odbc_test;UID=postgres;PWD=postgres;"
Write-Host ""
Write-Host "MySQL 8:"
Write-Host "  ODBC_TEST_DSN=Driver={MySQL ODBC 8.0 Unicode Driver};Server=localhost;Port=3306;Database=odbc_test;UID=odbc;PWD=odbc;"
Write-Host ""
Write-Host "MariaDB 11 (note port 3307 to avoid clash with mysql):"
Write-Host "  ODBC_TEST_DSN=Driver={MariaDB ODBC 3.1 Driver};Server=localhost;Port=3307;Database=odbc_test;UID=odbc;PWD=odbc;"
Write-Host ""
Write-Host "SQL Server 2022:"
Write-Host "  ODBC_TEST_DSN=Driver={ODBC Driver 18 for SQL Server};Server=localhost,1433;Database=master;UID=sa;PWD=OdbcTest123!;TrustServerCertificate=yes;"
Write-Host ""
Write-Host "Oracle XE 21 (needs Oracle Instant Client + ODBC driver on host):"
Write-Host "  ODBC_TEST_DSN=Driver={Oracle in OraClient19Home1};DBQ=localhost:1521/XEPDB1;UID=system;PWD=OdbcTest123!;"
Write-Host ""
if ($IncludeDb2) {
    Write-Host "IBM Db2 (needs IBM Data Server Driver Package on host):"
    Write-Host "  ODBC_TEST_DSN=Driver={IBM DB2 ODBC DRIVER};HostName=localhost;Port=50000;Database=TESTDB;Protocol=TCPIP;UID=db2inst1;PWD=OdbcTest123;"
    Write-Host ""
}
Write-Host "=================================================================" -ForegroundColor Magenta
Write-Host "Tip: install missing ODBC drivers on the host, OR run inside the" -ForegroundColor Magenta
Write-Host "     test-runner container which has them all baked in:" -ForegroundColor Magenta
Write-Host "     docker compose --profile test build test-runner" -ForegroundColor Magenta
Write-Host "     docker compose --profile test run --rm test-runner" -ForegroundColor Magenta
Write-Host "=================================================================" -ForegroundColor Magenta
