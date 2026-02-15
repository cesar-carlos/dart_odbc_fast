# Native Assets validation script
# Validates whether hook/build.dart and related setup are correctly configured.

Write-Host "=== Native Assets Validation ===" -ForegroundColor Cyan
Write-Host ""

# 1. Check hook/build.dart exists
Write-Host "1. Checking hook/build.dart..." -ForegroundColor Yellow
if (Test-Path "hook\build.dart") {
    Write-Host "   OK hook/build.dart found" -ForegroundColor Green
} else {
    Write-Host "   ERROR hook/build.dart not found" -ForegroundColor Red
    exit 1
}

# 2. Analyze hook/build.dart
Write-Host ""
Write-Host "2. Analyzing hook/build.dart..." -ForegroundColor Yellow
$analyzeResult = dart analyze hook/build.dart 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "   OK Analyze completed with no issues" -ForegroundColor Green
} else {
    Write-Host "   ERROR Issues found:" -ForegroundColor Red
    Write-Host $analyzeResult
    exit 1
}

# 3. Check whether Rust library exists (optional for this validation)
Write-Host ""
Write-Host "3. Checking Rust library..." -ForegroundColor Yellow
$dllPath = "native\odbc_engine\target\release\odbc_engine.dll"
if (Test-Path $dllPath) {
    Write-Host "   OK Rust library found: $dllPath" -ForegroundColor Green
    $fileInfo = Get-Item $dllPath
    Write-Host "   Size: $([math]::Round($fileInfo.Length / 1MB, 2)) MB" -ForegroundColor Gray
} else {
    Write-Host "   WARNING Rust library not found" -ForegroundColor Yellow
    Write-Host "   Build command: cd native\odbc_engine; cargo build --release" -ForegroundColor Gray
}

# 4. Check pubspec dependencies relevant to hook/native assets
Write-Host ""
Write-Host "4. Checking pubspec.yaml..." -ForegroundColor Yellow
$pubspecContent = Get-Content "pubspec.yaml" -Raw

if ($pubspecContent -match "\bcode_assets:\s*") {
    Write-Host "   OK code_assets dependency found" -ForegroundColor Green
} else {
    Write-Host "   ERROR code_assets dependency not found" -ForegroundColor Red
    exit 1
}

if ($pubspecContent -match "\bhooks:\s*") {
    Write-Host "   OK hooks dependency found" -ForegroundColor Green
} else {
    Write-Host "   ERROR hooks dependency not found" -ForegroundColor Red
    exit 1
}

# 5. Check library_loader.dart native-assets support
Write-Host ""
Write-Host "5. Checking library_loader.dart..." -ForegroundColor Yellow
$loaderContent = Get-Content "lib\infrastructure\native\bindings\library_loader.dart" -Raw
if ($loaderContent -match "package:odbc_fast" -or $loaderContent -match "Native Assets") {
    Write-Host "   OK Native Assets support detected" -ForegroundColor Green
} else {
    Write-Host "   ERROR Native Assets support not detected" -ForegroundColor Red
    exit 1
}

# 6. Check release workflow
Write-Host ""
Write-Host "6. Checking release workflow..." -ForegroundColor Yellow
if (Test-Path ".github\workflows\release.yml") {
    Write-Host "   OK release.yml found" -ForegroundColor Green
} else {
    Write-Host "   ERROR release.yml not found" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== Validation complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Suggested next steps:" -ForegroundColor Yellow
Write-Host "1. Build Rust: cd native\odbc_engine; cargo build --release" -ForegroundColor White
Write-Host "2. Validate hook path: dart analyze hook/build.dart" -ForegroundColor White
Write-Host "3. Run tests: dart test" -ForegroundColor White
Write-Host "4. Run release flow: see doc/RELEASE_AUTOMATION.md" -ForegroundColor White
