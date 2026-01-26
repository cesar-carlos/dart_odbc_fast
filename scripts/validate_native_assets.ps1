# Script de validacao do Native Assets
# Valida se o hook/build.dart esta funcionando corretamente

Write-Host "=== Validacao do Native Assets ===" -ForegroundColor Cyan
Write-Host ""

# 1. Verificar se o hook existe
Write-Host "1. Verificando hook/build.dart..." -ForegroundColor Yellow
if (Test-Path "hook\build.dart") {
    Write-Host "   OK hook/build.dart encontrado" -ForegroundColor Green
} else {
    Write-Host "   ERRO hook/build.dart nao encontrado" -ForegroundColor Red
    exit 1
}

# 2. Verificar analise do hook
Write-Host ""
Write-Host "2. Analisando hook/build.dart..." -ForegroundColor Yellow
$analyzeResult = dart analyze hook/build.dart 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "   OK Analise passou sem erros" -ForegroundColor Green
} else {
    Write-Host "   ERRO Erros encontrados:" -ForegroundColor Red
    Write-Host $analyzeResult
    exit 1
}

# 3. Verificar se a biblioteca Rust esta compilada
Write-Host ""
Write-Host "3. Verificando biblioteca Rust..." -ForegroundColor Yellow
$dllPath = "native\odbc_engine\target\release\odbc_engine.dll"
if (Test-Path $dllPath) {
    Write-Host "   OK Biblioteca Rust encontrada: $dllPath" -ForegroundColor Green
    $fileInfo = Get-Item $dllPath
    Write-Host "   Tamanho: $([math]::Round($fileInfo.Length / 1MB, 2)) MB" -ForegroundColor Gray
} else {
    Write-Host "   AVISO Biblioteca Rust nao encontrada" -ForegroundColor Yellow
    Write-Host "   Para compilar: cd native\odbc_engine; cargo build --release" -ForegroundColor Gray
}

# 4. Verificar configuracao do pubspec.yaml
Write-Host ""
Write-Host "4. Verificando pubspec.yaml..." -ForegroundColor Yellow
$pubspecContent = Get-Content "pubspec.yaml" -Raw
if ($pubspecContent -match "native_assets_cli") {
    Write-Host "   OK native_assets_cli encontrado nas dependencias" -ForegroundColor Green
} else {
    Write-Host "   ERRO native_assets_cli nao encontrado" -ForegroundColor Red
    exit 1
}

if ($pubspecContent -match "native_assets:") {
    Write-Host "   OK Configuracao native_assets encontrada" -ForegroundColor Green
} else {
    Write-Host "   ERRO Configuracao native_assets nao encontrada" -ForegroundColor Red
    exit 1
}

# 5. Verificar library_loader.dart
Write-Host ""
Write-Host "5. Verificando library_loader.dart..." -ForegroundColor Yellow
$loaderContent = Get-Content "lib\infrastructure\native\bindings\library_loader.dart" -Raw
if ($loaderContent -match "package:odbc_fast") {
    Write-Host "   OK Suporte a Native Assets encontrado" -ForegroundColor Green
} else {
    Write-Host "   ERRO Suporte a Native Assets nao encontrado" -ForegroundColor Red
    exit 1
}

# 6. Verificar workflow de release
Write-Host ""
Write-Host "6. Verificando workflow de release..." -ForegroundColor Yellow
if (Test-Path ".github\workflows\release.yml") {
    Write-Host "   OK release.yml encontrado" -ForegroundColor Green
} else {
    Write-Host "   ERRO release.yml nao encontrado" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== Validacao concluida ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Proximos passos:" -ForegroundColor Yellow
Write-Host "1. Compilar Rust: cd native\odbc_engine; cargo build --release" -ForegroundColor White
Write-Host "2. Testar hook: dart run hook/build.dart" -ForegroundColor White
Write-Host "3. Executar testes: dart test" -ForegroundColor White
Write-Host "4. Criar release: git tag v0.1.0; git push origin v0.1.0" -ForegroundColor White
