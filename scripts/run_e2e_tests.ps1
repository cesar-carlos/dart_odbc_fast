# Run all Rust E2E integration tests (native/odbc_engine/tests/e2e_*.rs).
#
# Prerequisites: cargo, ODBC driver, SQL Server (or DSN in .env).
# Loads repo-root .env (ENABLE_E2E_TESTS, ODBC_TEST_DSN). Maps RUN_SKIPPED_TESTS
# to ENABLE_SLOW_E2E_TESTS when the latter is unset so slow #[ignore] tests run.
#
# Usage:
#   powershell scripts/run_e2e_tests.ps1           # full suite incl. slow stress tests
#   powershell scripts/run_e2e_tests.ps1 -Quick    # live E2E only (slow stress self-skip)
#   pwsh scripts/run_e2e_tests.ps1 -Release  # release build

param(
    [switch]$Quick,
    [switch]$Release
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$EngineDir = Join-Path $Root 'native\odbc_engine'
$EnvFile = Join-Path $Root '.env'

function Import-DotEnv([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    Get-Content $Path | ForEach-Object {
        if ($_ -match '^\s*#|^\s*$') { return }
        if ($_ -match '^\s*([^=]+)=(.*)$') {
            $name = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            if ($value -match '^["''](.+)["'']$') { $value = $Matches[1] }
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
}

Import-DotEnv $EnvFile

if (-not $env:ENABLE_E2E_TESTS) {
    Write-Error 'ENABLE_E2E_TESTS is not set. Set ENABLE_E2E_TESTS=1 in .env or the environment.'
}

if ($Quick) {
    $env:ENABLE_SLOW_E2E_TESTS = '0'
} elseif (-not $env:ENABLE_SLOW_E2E_TESTS -and $env:RUN_SKIPPED_TESTS) {
    $env:ENABLE_SLOW_E2E_TESTS = $env:RUN_SKIPPED_TESTS
}

if (-not $env:ODBC_TEST_DSN) {
    Write-Warning 'ODBC_TEST_DSN not set; live tests will self-skip.'
}

$e2eTests = @(
    'e2e_async_api_test', 'e2e_basic_connection_test', 'e2e_batch_executor_test',
    'e2e_bcp_fallback_test', 'e2e_bcp_native_numeric_test', 'e2e_bulk_compare_benchmark_test',
    'e2e_bulk_operations_test', 'e2e_bulk_transaction_stress_test', 'e2e_catalog_test',
    'e2e_driver_capabilities_test', 'e2e_execution_engine_test', 'e2e_ffi_refactor_regression_test',
    'e2e_multi_db_basic_test', 'e2e_oracle_ref_cursor_test', 'e2e_pool_test',
    'e2e_savepoint_test', 'e2e_sqlserver_test', 'e2e_statement_reuse_test',
    'e2e_streaming_test', 'e2e_structured_error_test', 'e2e_test', 'e2e_timeout_test',
    'e2e_transaction_access_mode_test', 'e2e_transaction_lock_timeout_test', 'e2e_xa_transaction_test'
)

$cargoArgs = @('test', '--features', 'test-helpers')
if ($Release) { $cargoArgs += '--release' }
foreach ($t in $e2eTests) { $cargoArgs += @('--test', $t) }
$cargoArgs += '--', '--test-threads=1', '--include-ignored'

Push-Location $EngineDir
try {
    & cargo @cargoArgs
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
