# Complete validation script for Rust + Dart
$env:Path += ";$env:USERPROFILE\.cargo\bin"

Write-Host "=== ODBC Dart Fast - Complete Validation ===" -ForegroundColor Cyan
Write-Host ""

$allPassed = $true

# ============================================
# RUST VALIDATION
# ============================================
Write-Host "[1/5] Rust: cargo check..." -ForegroundColor Yellow
Push-Location native\odbc_engine
$result = cargo check --all-targets 2>&1 | Out-String
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✅ OK" -ForegroundColor Green
} else {
    Write-Host "  ❌ FAILED" -ForegroundColor Red
    $allPassed = $false
}
Pop-Location

Write-Host "[2/5] Rust: cargo test..." -ForegroundColor Yellow
Push-Location native\odbc_engine
$testOutput = cargo test --lib 2>&1 | Out-String
if ($LASTEXITCODE -eq 0) {
    $testLine = $testOutput | Select-String "test result:"
    Write-Host "  ✅ $testLine" -ForegroundColor Green
} else {
    Write-Host "  ❌ FAILED" -ForegroundColor Red
    $allPassed = $false
}
Pop-Location

Write-Host "[3/5] Rust: cargo clippy..." -ForegroundColor Yellow
Push-Location native\odbc_engine
$clippy = cargo clippy --all-targets 2>&1 | Out-String
$errors = $clippy | Select-String "^error" | Measure-Object
if ($errors.Count -eq 0) {
    Write-Host "  ✅ OK (no errors)" -ForegroundColor Green
} else {
    Write-Host "  ❌ FAILED ($($errors.Count) errors)" -ForegroundColor Red
    $allPassed = $false
}
Pop-Location

# ============================================
# DART VALIDATION
# ============================================
Write-Host "[4/5] Dart: dart analyze..." -ForegroundColor Yellow
$analyze = dart analyze --fatal-infos 2>&1 | Out-String
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✅ OK (no issues)" -ForegroundColor Green
} else {
    Write-Host "  ❌ FAILED" -ForegroundColor Red
    $allPassed = $false
}

# ============================================
# BUILD ARTIFACTS CHECK
# ============================================
Write-Host "[5/5] Build artifacts..." -ForegroundColor Yellow
$dllOk = Test-Path "native\target\release\odbc_engine.dll"
$headerOk = Test-Path "native\odbc_engine\include\odbc_engine.h"
$bindingsOk = Test-Path "lib\infrastructure\native\bindings\odbc_bindings.dart"

if ($dllOk) {
    $size = (Get-Item "native\target\release\odbc_engine.dll").Length / 1MB
    Write-Host "  ✅ DLL: $([math]::Round($size, 2)) MB" -ForegroundColor Green
} else {
    Write-Host "  ❌ DLL missing" -ForegroundColor Red
    $allPassed = $false
}

if ($headerOk) {
    Write-Host "  ✅ Header: odbc_engine.h" -ForegroundColor Green
} else {
    Write-Host "  ❌ Header missing" -ForegroundColor Red
    $allPassed = $false
}

if ($bindingsOk) {
    Write-Host "  ✅ Bindings: odbc_bindings.dart" -ForegroundColor Green
} else {
    Write-Host "  ❌ Bindings missing" -ForegroundColor Red
    $allPassed = $false
}

Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Cyan

if ($allPassed) {
    Write-Host "✅ ALL CHECKS PASSED" -ForegroundColor Green
    Write-Host ""
    Write-Host "Project is ready!" -ForegroundColor Green
    Write-Host "  - Rust engine: compiled and tested" -ForegroundColor Gray
    Write-Host "  - Dart API: analyzed, no issues" -ForegroundColor Gray
    Write-Host "  - FFI artifacts: complete" -ForegroundColor Gray
} else {
    Write-Host "❌ SOME CHECKS FAILED" -ForegroundColor Red
    Write-Host ""
    Write-Host "Please review errors above." -ForegroundColor Yellow
}
