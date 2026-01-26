# Run unit tests that do not require ODBC native bindings
# Usage: .\scripts\test_unit.ps1 (from project root)

$ErrorActionPreference = "Stop"
$root = if ($PSScriptRoot) {
    Split-Path -Parent $PSScriptRoot
} else {
    (Get-Location).Path
}

Push-Location $root

$exitCode = 1
try {
    Write-Host "=== ODBC Fast - Unit Tests ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Running: dart test test/infrastructure/native/protocol" -ForegroundColor Yellow
    dart test test/infrastructure/native/protocol
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($exitCode -eq 0) {
    Write-Host ""
    Write-Host "All unit tests passed." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Some tests failed." -ForegroundColor Red
}
exit $exitCode
