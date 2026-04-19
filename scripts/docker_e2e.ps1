# Run the engine's E2E suite against the dockerised DB stack from inside
# the Linux `test-runner` container. Avoids having to install any ODBC
# driver on the Windows host.
#
# Usage:
#   pwsh scripts/docker_e2e.ps1                       # PostgreSQL (default)
#   pwsh scripts/docker_e2e.ps1 -Engine mysql
#   pwsh scripts/docker_e2e.ps1 -Engine mariadb
#   pwsh scripts/docker_e2e.ps1 -Engine mssql
#   pwsh scripts/docker_e2e.ps1 -Engine postgres -TestFilter xa_pg_

[CmdletBinding()]
param(
    [ValidateSet('postgres', 'mysql', 'mariadb', 'mssql')]
    [string]$Engine = 'postgres',

    # Filter passed to `cargo test` (substring match against test names).
    [string]$TestFilter = '',

    # Pass extra args to `cargo test --features` (defaults to ffi-tests).
    [string]$Features = 'ffi-tests',

    # Skip the docker compose build step (faster iteration when the image
    # is already up to date).
    [switch]$NoBuild,

    # Run a quick smoke test (cargo test --lib transaction) instead of the
    # full ignored E2E suite. Useful for CI smoke jobs.
    [switch]$SmokeOnly
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "[docker_e2e] $msg" -ForegroundColor Cyan }
function Write-Ok2($msg)  { Write-Host "[docker_e2e] $msg" -ForegroundColor Green }
function Write-Err2($msg) { Write-Host "[docker_e2e] $msg" -ForegroundColor Red }

# -- DSN per engine (using docker network hostnames) ---------------------

$dsnByEngine = @{
    postgres = 'Driver={PostgreSQL Unicode};Server=postgres;Port=5432;Database=odbc_test;UID=postgres;PWD=postgres;'
    mysql    = 'Driver={MySQL ODBC 8.0 Unicode Driver};Server=mysql;Port=3306;Database=odbc_test;UID=odbc;PWD=odbc;'
    mariadb  = 'Driver={MariaDB ODBC 3.1 Driver};Server=mariadb;Port=3306;Database=odbc_test;UID=odbc;PWD=odbc;'
    mssql    = 'Driver={ODBC Driver 18 for SQL Server};Server=mssql,1433;Database=master;UID=sa;PWD=OdbcTest123!;TrustServerCertificate=yes;'
}

$dsn = $dsnByEngine[$Engine]
Write-Step "Engine: $Engine"
Write-Step "DSN:    $dsn"

# -- Make sure the DB containers are up ---------------------------------

Write-Step 'Ensuring DB stack is up...'
& "$PSScriptRoot/docker_db_up.ps1" -TimeoutSeconds 240
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# -- Build runner image (cached) ----------------------------------------

if (-not $NoBuild) {
    Write-Step 'Building test-runner image (cached)...'
    docker compose --profile test build test-runner
    if ($LASTEXITCODE -ne 0) { Write-Err2 'test-runner image build failed.'; exit $LASTEXITCODE }
}

# -- Compose run --------------------------------------------------------

if ($SmokeOnly) {
    $cargoCmd = 'cargo test --lib --features ' + $Features + ' transaction -- --test-threads=1'
} else {
    $filterArg = if ($TestFilter) { " $TestFilter" } else { '' }
    $cargoCmd = "cargo test --features $Features$filterArg -- --include-ignored --test-threads=1"
}

Write-Step "Inside container: $cargoCmd"

docker compose --profile test run --rm `
    -e "ODBC_TEST_DSN=$dsn" `
    -e 'ENABLE_E2E_TESTS=1' `
    test-runner bash -c $cargoCmd

$exit = $LASTEXITCODE
if ($exit -eq 0) {
    Write-Ok2 "All requested tests passed for engine=$Engine."
} else {
    Write-Err2 "Test run failed for engine=$Engine (exit $exit)."
}
exit $exit
