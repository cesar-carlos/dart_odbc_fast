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

# Try to load ODBC_TEST_DSN from .env file if not set
if (-not $env:ODBC_TEST_DSN) {
    $envFile = Join-Path $root ".env"
    if (Test-Path $envFile) {
        $content = Get-Content $envFile -Raw
        if ($content -match 'ODBC_TEST_DSN=(.+)') {
            $env:ODBC_TEST_DSN = $matches[1].Trim()
            Write-Host "Loaded ODBC_TEST_DSN from .env file" -ForegroundColor Gray
        }
    }
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
