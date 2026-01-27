# Runs cargo-tarpaulin to generate Rust code coverage (HTML + LCOV).
# Requires: cargo install cargo-tarpaulin
# Output: native/coverage/tarpaulin-report.html and native/coverage/lcov.info

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $PSCommandPath
$engineDir = Split-Path -Parent $scriptDir
$workspaceRoot = Split-Path -Parent $engineDir
$coverageDir = Join-Path $workspaceRoot "coverage"

Write-Host "=== Rust Code Coverage (cargo tarpaulin) ===" -ForegroundColor Cyan
Write-Host "Workspace: $workspaceRoot" -ForegroundColor Gray
Write-Host "Package:   odbc_engine" -ForegroundColor Gray
Write-Host "Output:    $coverageDir" -ForegroundColor Gray
Write-Host ""

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Error "cargo not found. Install Rust from https://rustup.rs"
}

$tarpaulin = cargo tarpaulin --version 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Installing cargo-tarpaulin..." -ForegroundColor Yellow
    cargo install cargo-tarpaulin
}

Push-Location $workspaceRoot
try {
    New-Item -ItemType Directory -Force -Path $coverageDir | Out-Null
    cargo tarpaulin -p odbc_engine --lib --out Html --out Lcov --output-dir coverage
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($exitCode -eq 0) {
    $htmlPath = Join-Path $coverageDir "tarpaulin-report.html"
    Write-Host ""
    Write-Host "Coverage report: $htmlPath" -ForegroundColor Green
    Write-Host "Open in browser: file:///$($htmlPath -replace '\\', '/')" -ForegroundColor Gray
} else {
    exit $exitCode
}
