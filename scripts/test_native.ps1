# Run native Rust tests (all module tests)
# Usage: .\scripts\test_native.ps1 [-Release] [-FFIOnly] (from project root)

param(
    [switch]$Release,
    [switch]$FFIOnly
)

$ErrorActionPreference = "Stop"
$root = if ($PSScriptRoot) {
    Split-Path -Parent $PSScriptRoot
} else {
    (Get-Location).Path
}

$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"

Push-Location "$root\native"

$exitCode = 1
try {
    Write-Host "=== ODBC Fast - Native Rust Tests ===" -ForegroundColor Cyan
    Write-Host ""

    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    if (-not $cargo) {
        Write-Host "ERROR: Cargo not found. Install Rust from https://rustup.rs/" -ForegroundColor Red
        exit 1
    }

    $extraArgs = if ($Release) { "--release" } else { "" }

    if ($FFIOnly) {
        Write-Host "Running: cargo test --lib ffi::tests $extraArgs" -ForegroundColor Yellow
        
        if ($Release) {
            cargo test --lib ffi::tests --release
        } else {
            cargo test --lib ffi::tests
        }
    } else {
        Write-Host "Running: cargo test --lib $extraArgs" -ForegroundColor Yellow
        
        if ($Release) {
            cargo test --lib --release
        } else {
            cargo test --lib
        }
    }
    
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($exitCode -eq 0) {
    Write-Host ""
    Write-Host "All native tests passed." -ForegroundColor Green
    Write-Host ""
    Write-Host "Test coverage:" -ForegroundColor Cyan
    Write-Host "  - FFI Layer (20 tests)" -ForegroundColor Gray
    Write-Host "  - Error Handling (10 tests)" -ForegroundColor Gray
    Write-Host "  - Protocol Types (16 tests)" -ForegroundColor Gray
    Write-Host "  - Protocol Encoder (9 tests)" -ForegroundColor Gray
    Write-Host "  - Security Buffer (13 tests)" -ForegroundColor Gray
    Write-Host "  - Protocol Version (17 tests)" -ForegroundColor Gray
    Write-Host "  - Engine Core (3 tests)" -ForegroundColor Gray
} else {
    Write-Host ""
    Write-Host "Some tests failed." -ForegroundColor Red
}
exit $exitCode
