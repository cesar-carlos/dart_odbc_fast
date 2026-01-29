# Copy odbc_engine.dll from odbc_fast package (pub cache or repo) to the consumer project.
# Run from your project root, or pass -ProjectRoot.
# Example (from your project): & "$env:LOCALAPPDATA\Pub\Cache\hosted\pub.dev\odbc_fast-0.2.7\scripts\copy_odbc_dll.ps1"

param(
    [string]$ProjectRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"

$packageRoot = (Get-Item $PSScriptRoot).Parent.FullName
$dllSource = Join-Path $packageRoot "artifacts\windows-x64\odbc_engine.dll"

if (-not (Test-Path $dllSource)) {
    Write-Host "ERROR: DLL not found at $dllSource" -ForegroundColor Red
    Write-Host "Run 'dart pub get' in your project first so odbc_fast is in the pub cache." -ForegroundColor Yellow
    exit 1
}

$targets = @(
    (Join-Path $ProjectRoot "odbc_engine.dll"),
    (Join-Path $ProjectRoot "build\windows\x64\runner\Debug\odbc_engine.dll"),
    (Join-Path $ProjectRoot "build\windows\x64\runner\Release\odbc_engine.dll")
)

foreach ($dest in $targets) {
    $dir = Split-Path $dest -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Copy-Item -Path $dllSource -Destination $dest -Force
    Write-Host "Copied to $dest" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done. You can run 'flutter run -d windows' or 'dart test'." -ForegroundColor Cyan
