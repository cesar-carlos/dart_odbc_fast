# Build Rust, then run all Dart tests
# Usage: .\scripts\test_all.ps1 (from project root)

param(
    [switch]$SkipRust
)

$ErrorActionPreference = "Stop"
$root = if ($PSScriptRoot) {
    Split-Path -Parent $PSScriptRoot
}
else {
    (Get-Location).Path
}

$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"

Push-Location $root

$exitCode = 1
try {
    Write-Host "=== ODBC Fast - All Tests ===" -ForegroundColor Cyan
    Write-Host ""

    if (-not $SkipRust) {
        Write-Host "[1/2] Building Rust library..." -ForegroundColor Yellow
        $cargo = Get-Command cargo -ErrorAction SilentlyContinue
        if (-not $cargo) {
            Write-Host "ERROR: Cargo not found. Install Rust from https://rustup.rs/" -ForegroundColor Red
            exit 1
        }
        Push-Location "native"
        try {
            cmd /c "cargo build --release"
            if ($LASTEXITCODE -ne 0) {
                Write-Host "ERROR: Rust build failed" -ForegroundColor Red
                exit 1
            }
            Write-Host "  OK Rust built" -ForegroundColor Green
        }
        finally {
            Pop-Location
        }
        Write-Host ""
    }
    else {
        Write-Host "[1/2] Skipping Rust build (-SkipRust)" -ForegroundColor Gray
        Write-Host ""
    }

    Write-Host "[2/2] Running dart test..." -ForegroundColor Yellow
    # Run tests sequentially to avoid resource contention (ServiceLocator singleton, worker isolates)
    dart test --concurrency=1
    $exitCode = $LASTEXITCODE
}
finally {
    Pop-Location
}

if ($exitCode -eq 0) {
    Write-Host ""
    Write-Host "All tests passed." -ForegroundColor Green
}
else {
    Write-Host ""
    Write-Host "Some tests failed. Unit-only: .\scripts\test_unit.ps1" -ForegroundColor Yellow
}
exit $exitCode
