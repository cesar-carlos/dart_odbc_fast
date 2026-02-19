# Full validation script for Rust + Dart + artifacts.
# Use -ArtifactsOnly for a quick artifact check (replacement for old check_build.ps1).
#
# Usage:
#   .\scripts\validate_all.ps1
#   .\scripts\validate_all.ps1 -ArtifactsOnly

param(
    [switch]$ArtifactsOnly
)

$ErrorActionPreference = "Stop"
$env:Path += ";$env:USERPROFILE\.cargo\bin"

$root = if ($PSScriptRoot) {
    Split-Path -Parent $PSScriptRoot
}
else {
    (Get-Location).Path
}

Push-Location $root
try {
    Write-Host "=== ODBC Fast Validation ===" -ForegroundColor Cyan
    Write-Host ""

    $allPassed = $true
    $step = 1
    $totalSteps = if ($ArtifactsOnly) { 1 } else { 7 }

    if (-not $ArtifactsOnly) {
        if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
            Write-Host "ERROR: cargo not found in PATH." -ForegroundColor Red
            exit 1
        }
        if (-not (Get-Command dart -ErrorAction SilentlyContinue)) {
            Write-Host "ERROR: dart not found in PATH." -ForegroundColor Red
            exit 1
        }

        Write-Host "[$step/$totalSteps] Rust: cargo fmt --all -- --check" -ForegroundColor Yellow
        Push-Location "native"
        try {
            cargo fmt --all -- --check | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  OK" -ForegroundColor Green
            }
            else {
                Write-Host "  FAILED" -ForegroundColor Red
                $allPassed = $false
            }
        }
        finally {
            Pop-Location
        }
        $step++

        Write-Host "[$step/$totalSteps] Rust: cargo check --all-targets" -ForegroundColor Yellow
        Push-Location "native\odbc_engine"
        try {
            cargo check --all-targets | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  OK" -ForegroundColor Green
            }
            else {
                Write-Host "  FAILED" -ForegroundColor Red
                $allPassed = $false
            }
        }
        finally {
            Pop-Location
        }
        $step++

        Write-Host "[$step/$totalSteps] Rust: cargo test --lib" -ForegroundColor Yellow
        Push-Location "native\odbc_engine"
        try {
            cargo test --lib | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  OK" -ForegroundColor Green
            }
            else {
                Write-Host "  FAILED" -ForegroundColor Red
                $allPassed = $false
            }
        }
        finally {
            Pop-Location
        }
        $step++

        Write-Host "[$step/$totalSteps] Rust: cargo clippy --all-targets -- -D warnings" -ForegroundColor Yellow
        Push-Location "native\odbc_engine"
        try {
            cargo clippy --all-targets -- -D warnings | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  OK" -ForegroundColor Green
            }
            else {
                Write-Host "  FAILED" -ForegroundColor Red
                $allPassed = $false
            }
        }
        finally {
            Pop-Location
        }
        $step++

        Write-Host "[$step/$totalSteps] Dart: dart analyze --fatal-infos" -ForegroundColor Yellow
        dart analyze --fatal-infos | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  OK" -ForegroundColor Green
        }
        else {
            Write-Host "  FAILED" -ForegroundColor Red
            $allPassed = $false
        }
        $step++

        Write-Host "[$step/$totalSteps] Dart: unit-only test scope" -ForegroundColor Yellow
        dart test test/application test/domain test/infrastructure test/helpers/database_detection_test.dart | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  OK" -ForegroundColor Green
        }
        else {
            Write-Host "  FAILED" -ForegroundColor Red
            $allPassed = $false
        }
        $step++
    }

    Write-Host "[$step/$totalSteps] Build artifacts" -ForegroundColor Yellow

    $dllCandidates = @(
        "native\target\release\odbc_engine.dll",
        "native\odbc_engine\target\release\odbc_engine.dll"
    )

    $dllPath = $dllCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    $headerPath = "native\odbc_engine\include\odbc_engine.h"
    $bindingsPath = "lib\infrastructure\native\bindings\odbc_bindings.dart"

    if ($dllPath) {
        $size = (Get-Item $dllPath).Length / 1MB
        Write-Host "  OK DLL: $dllPath ($([math]::Round($size, 2)) MB)" -ForegroundColor Green
    }
    else {
        Write-Host "  FAILED DLL missing (checked native\\target and native\\odbc_engine\\target)" -ForegroundColor Red
        $allPassed = $false
    }

    if (Test-Path $headerPath) {
        Write-Host "  OK Header: $headerPath" -ForegroundColor Green
    }
    else {
        Write-Host "  FAILED Header missing: $headerPath" -ForegroundColor Red
        $allPassed = $false
    }

    if (Test-Path $bindingsPath) {
        Write-Host "  OK Bindings: $bindingsPath" -ForegroundColor Green
    }
    else {
        Write-Host "  FAILED Bindings missing: $bindingsPath" -ForegroundColor Red
        $allPassed = $false
    }

    Write-Host ""
    Write-Host "=== Summary ===" -ForegroundColor Cyan
    if ($allPassed) {
        Write-Host "ALL CHECKS PASSED" -ForegroundColor Green
        exit 0
    }

    Write-Host "SOME CHECKS FAILED" -ForegroundColor Red
    exit 1
}
finally {
    Pop-Location
}
