# Run end-to-end native Rust tests
# Usage: .\scripts\test_e2e.ps1 (from project root)
# Requires: ODBC_TEST_DSN environment variable or .env file

$ErrorActionPreference = "Stop"
$root = if ($PSScriptRoot) {
    Split-Path -Parent $PSScriptRoot
} else {
    (Get-Location).Path
}

$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"

# Try to load ODBC_TEST_DSN / ENABLE_E2E_TESTS from .env file if not set
if (-not $env:ODBC_TEST_DSN -or -not $env:ENABLE_E2E_TESTS) {
    $envFile = Join-Path $root ".env"
    if (Test-Path $envFile) {
        $content = Get-Content $envFile -Raw
        if (-not $env:ODBC_TEST_DSN -and $content -match '(?m)^[ \t]*ODBC_TEST_DSN=(.+)$') {
            $env:ODBC_TEST_DSN = $matches[1].Trim()
            Write-Host "Loaded ODBC_TEST_DSN from .env file" -ForegroundColor Gray
        }
        if (-not $env:ENABLE_E2E_TESTS -and $content -match '(?m)^[ \t]*ENABLE_E2E_TESTS=(.+)$') {
            $env:ENABLE_E2E_TESTS = $matches[1].Trim()
            Write-Host "Loaded ENABLE_E2E_TESTS from .env file" -ForegroundColor Gray
        }
    }
}

function ParseEnvBool([string]$raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $v = $raw.Trim().ToLowerInvariant()
    if ($v -in @("1", "true", "yes", "y")) { return $true }
    if ($v -in @("0", "false", "no", "n")) { return $false }
    return $null
}

$enableE2E = ParseEnvBool $env:ENABLE_E2E_TESTS
if ($enableE2E -eq $false) {
    Write-Host "ENABLE_E2E_TESTS is disabled. Skipping end-to-end native tests." -ForegroundColor Yellow
    exit 0
}
if ($enableE2E -ne $true) {
    Write-Host "ENABLE_E2E_TESTS is not enabled. Skipping end-to-end native tests." -ForegroundColor Yellow
    exit 0
}

Push-Location "$root\native"

$exitCode = 1
try {
    Write-Host "=== ODBC Fast - End-to-End Native Tests ===" -ForegroundColor Cyan
    Write-Host ""

    if (-not $env:ODBC_TEST_DSN) {
        Write-Host "WARNING: ODBC_TEST_DSN not set. Tests will be ignored." -ForegroundColor Yellow
        Write-Host "Set ODBC_TEST_DSN environment variable or configure in .env file" -ForegroundColor Yellow
        Write-Host ""
    } else {
        Write-Host "Using ODBC_TEST_DSN: $($env:ODBC_TEST_DSN.Substring(0, [Math]::Min(50, $env:ODBC_TEST_DSN.Length)))..." -ForegroundColor Gray
        Write-Host ""
    }

    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    if (-not $cargo) {
        Write-Host "ERROR: Cargo not found. Install Rust from https://rustup.rs/" -ForegroundColor Red
        exit 1
    }

    Write-Host "Running: cargo test --test e2e_test -- --ignored" -ForegroundColor Yellow
    cargo test --test e2e_test -- --ignored
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($exitCode -eq 0) {
    Write-Host ""
    Write-Host "All end-to-end tests passed." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Some tests failed." -ForegroundColor Red
}
exit $exitCode
