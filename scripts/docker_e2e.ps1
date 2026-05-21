# Run the engine's E2E suite against the dockerised DB stack from inside
# the Linux `test-runner` container. Avoids having to install any ODBC
# driver on the Windows host.
#
# Usage:
#   pwsh scripts/docker_e2e.ps1                       # PostgreSQL (default)
#   pwsh scripts/docker_e2e.ps1 -Engine mysql
#   pwsh scripts/docker_e2e.ps1 -Engine mariadb
#   pwsh scripts/docker_e2e.ps1 -Engine mssql
#   pwsh scripts/docker_e2e.ps1 -Engine db2        # (starts Db2 profile; use test_multi_db_ filter for smoke)
#   pwsh scripts/docker_e2e.ps1 -Engine postgres -TestFilter xa_pg_
#   pwsh scripts/docker_e2e.ps1 -Quick              # no --include-ignored (skips long #[ignore] stress)
#   pwsh scripts/docker_e2e.ps1 -Full               # entire cargo test matrix (~10-15 min, single-threaded)

[CmdletBinding()]
param(
    [ValidateSet('postgres', 'mysql', 'mariadb', 'mssql', 'db2', 'oracle')]
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
    [switch]$SmokeOnly,

    # Run `cargo test` without `--include-ignored` so `#[ignore]` cases (e.g.
    # 10k-row bulk transaction stress) stay skipped.
    [switch]$Quick,

    # Run the full `cargo test --features ffi-tests` matrix with
    # `--include-ignored --test-threads=1` (slow; local default uses CI filters).
    [switch]$Full
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
    db2      = 'Driver={IBM DB2 ODBC DRIVER};HostName=db2;Port=50000;Database=TESTDB;Protocol=TCPIP;UID=db2inst1;PWD=OdbcTest123;'
    oracle   = 'Driver={Oracle Instant Client ODBC};DBQ=oracle:1521/XEPDB1;UID=system;PWD=OdbcTest123!;'
}

$dsn = $dsnByEngine[$Engine]
Write-Step "Engine: $Engine"
Write-Step "DSN:    $dsn"

# Oracle uses a different runner image (test-runner-oracle) because the
# Instant Client + ODBC driver are licensed and add ~150 MB to the layer.
$useOracleRunner = ($Engine -eq 'oracle')
$composeProfile = if ($useOracleRunner) { 'oracle-test' } else { 'test' }
$runnerService  = if ($useOracleRunner) { 'test-runner-oracle' } else { 'test-runner' }

# -- Make sure the DB containers are up ---------------------------------

Write-Step 'Ensuring DB stack is up...'
$includeDb2 = ($Engine -eq 'db2')
$waitSeconds = if ($includeDb2) { 600 } else { 240 }
& "$PSScriptRoot/docker_db_up.ps1" -IncludeDb2:$includeDb2 -TimeoutSeconds $waitSeconds
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# -- Build runner image (cached) ----------------------------------------

if (-not $NoBuild) {
    Write-Step "Building $runnerService image (cached)..."
    docker compose --profile $composeProfile build $runnerService
    if ($LASTEXITCODE -ne 0) { Write-Err2 "$runnerService image build failed."; exit $LASTEXITCODE }
}

# -- Compose run --------------------------------------------------------

# CI uses focused filters per engine; the old unfiltered default ran 1200+ lib
# tests plus every integration target serially (~10-15 min).
$filterByEngine = @{
    postgres = 'test_e2e_xa_postgresql'
    mysql    = 'test_e2e_xa_mysql'
    mariadb  = 'test_e2e_xa_mysql'
    mssql    = 'test_e2e_transaction_access_mode'
    db2      = 'test_multi_db_'
    oracle   = 'test_e2e_xa_oracle'
}

if ($SmokeOnly) {
    $cargoCmd = 'cargo test --lib --features ' + $Features + ' transaction -- --test-threads=1'
} else {
    $effectiveFilter = $TestFilter
    if (-not $effectiveFilter -and -not $Full) {
        $effectiveFilter = $filterByEngine[$Engine]
        Write-Step "Filter: $effectiveFilter (CI scope; use -Full for entire suite, -TestFilter to override)"
    } elseif ($Full) {
        Write-Step 'Mode: Full suite (all integration targets, --include-ignored, --test-threads=1)'
    }

    $filterArg = if ($effectiveFilter) { " $effectiveFilter" } else { '' }
    if ($Full) {
        $extraArgs = '--include-ignored --test-threads=1'
    } elseif ($Quick) {
        $extraArgs = '--test-threads=1'
    } else {
        $extraArgs = '--test-threads=4'
    }
    $cargoCmd = "cargo test --features $Features$filterArg -- $extraArgs"
}

Write-Step "Inside container: $cargoCmd"

docker compose --profile $composeProfile run --rm `
    -e "ODBC_TEST_DSN=$dsn" `
    -e 'ENABLE_E2E_TESTS=1' `
    -e 'RUSTUP_TOOLCHAIN=1.93.0-x86_64-unknown-linux-gnu' `
    $runnerService bash -c $cargoCmd

$exit = $LASTEXITCODE
if ($exit -eq 0) {
    Write-Ok2 "All requested tests passed for engine=$Engine."
} else {
    Write-Err2 "Test run failed for engine=$Engine (exit $exit)."
}
exit $exit
