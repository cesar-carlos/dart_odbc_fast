# Script para analise de cobertura de codigo Rust
# Analisa a estrutura de arquivos e testes para estimar cobertura

$ErrorActionPreference = "Stop"

Write-Host "=== Analise de Cobertura de Codigo Rust ===" -ForegroundColor Cyan
Write-Host ""

$projectRoot = Split-Path -Parent $PSScriptRoot
$srcPath = Join-Path $projectRoot "src"
$testsPath = Join-Path $projectRoot "tests"

# Contar arquivos fonte
$sourceFiles = Get-ChildItem -Path $srcPath -Filter "*.rs" -Recurse | Where-Object { $_.Name -ne "mod.rs" -or (Get-Content $_.FullName | Measure-Object -Line).Lines -gt 10 }
$totalSourceFiles = $sourceFiles.Count

# Contar linhas de codigo (aproximado)
$totalLines = 0
$sourceFiles | ForEach-Object {
    $content = Get-Content $_.FullName -Raw
    $lines = ($content -split "`n").Count
    $totalLines += $lines
}

Write-Host "Estatisticas Gerais:" -ForegroundColor Yellow
Write-Host "  Arquivos fonte: $totalSourceFiles"
Write-Host "  Linhas de codigo (aproximado): $totalLines"
Write-Host ""

# Analisar módulos
$modules = @{
    "ffi" = @{ files = 0; tests = 0; description = "FFI Layer (C API)" }
    "engine" = @{ files = 0; tests = 0; description = "Engine Core" }
    "protocol" = @{ files = 0; tests = 0; description = "Binary Protocol" }
    "security" = @{ files = 0; tests = 0; description = "Security" }
    "error" = @{ files = 0; tests = 0; description = "Error Handling" }
    "observability" = @{ files = 0; tests = 0; description = "Observability" }
    "plugins" = @{ files = 0; tests = 0; description = "Driver Plugins" }
    "pool" = @{ files = 0; tests = 0; description = "Connection Pool" }
    "versioning" = @{ files = 0; tests = 0; description = "Versioning" }
    "handles" = @{ files = 0; tests = 0; description = "ODBC Handles" }
    "async_bridge" = @{ files = 0; tests = 0; description = "Async Bridge" }
}

# Contar arquivos por modulo
$sourceFiles | ForEach-Object {
    $fullPath = $_.FullName
    $relativePath = $fullPath.Replace($srcPath, "").Replace("\", "/").TrimStart("/")
    $parts = $relativePath -split "/"
    if ($parts.Count -gt 0) {
        $module = $parts[0]
        if ($modules.ContainsKey($module)) {
            $modules[$module].files++
        }
    }
}

# Contar testes inline
$testFiles = Get-ChildItem -Path $srcPath -Filter "*.rs" -Recurse
$testFiles | ForEach-Object {
    $content = Get-Content $_.FullName -Raw
    if ($content -match '#\[test\]') {
        $testCount = ([regex]::Matches($content, '#\[test\]')).Count
        $fullPath = $_.FullName
        $relativePath = $fullPath.Replace($srcPath, "").Replace("\", "/").TrimStart("/")
        $parts = $relativePath -split "/"
        if ($parts.Count -gt 0) {
            $module = $parts[0]
            if ($modules.ContainsKey($module)) {
                $modules[$module].tests += $testCount
            }
        }
    }
}

# Contar testes de integração
$integrationTests = Get-ChildItem -Path $testsPath -Filter "*.rs" -ErrorAction SilentlyContinue
$integrationTestCount = 0
if ($integrationTests) {
    $integrationTests | ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        $testCount = ([regex]::Matches($content, '#\[test\]')).Count
        $integrationTestCount += $testCount
    }
}

Write-Host "Cobertura por Modulo:" -ForegroundColor Yellow
Write-Host ""

$totalTests = 0
$modules.GetEnumerator() | Sort-Object Name | ForEach-Object {
    $module = $_.Key
    $info = $_.Value
    $totalTests += $info.tests
    
    $coverage = if ($info.files -gt 0) {
        [math]::Round(($info.tests / ($info.files * 3)) * 100, 1)  # Estimativa: 3 testes por arquivo
    } else {
        0
    }
    
    $coverageColor = if ($coverage -ge 80) { "Green" }
                     elseif ($coverage -ge 50) { "Yellow" }
                     else { "Red" }
    
    Write-Host "  $($info.description.PadRight(25)) " -NoNewline
    Write-Host "Arquivos: $($info.files.ToString().PadLeft(2)) " -NoNewline -ForegroundColor Cyan
    Write-Host "Testes: $($info.tests.ToString().PadLeft(3)) " -NoNewline -ForegroundColor Cyan
    Write-Host "Cobertura estimada: " -NoNewline
    Write-Host "$coverage%" -ForegroundColor $coverageColor
}

Write-Host ""
Write-Host "Testes de Integracao:" -ForegroundColor Yellow
Write-Host "  Testes E2E/Integracao: $integrationTestCount"
Write-Host ""

$totalTests += $integrationTestCount

Write-Host "Resumo Geral:" -ForegroundColor Yellow
Write-Host "  Total de testes: $totalTests"
Write-Host "  Testes unitários (inline): $($totalTests - $integrationTestCount)"
Write-Host "  Testes de integração: $integrationTestCount"
Write-Host ""

# Estimar cobertura geral
$estimatedCoverage = if ($totalSourceFiles -gt 0) {
    [math]::Round(($totalTests / ($totalSourceFiles * 2.5)) * 100, 1)  # Estimativa: 2.5 testes por arquivo
} else {
    0
}

$coverageColor = if ($estimatedCoverage -ge 80) { "Green" }
                 elseif ($estimatedCoverage -ge 50) { "Yellow" }
                 else { "Red" }

Write-Host "Cobertura Estimada Geral: " -NoNewline -ForegroundColor Yellow
Write-Host "$estimatedCoverage%" -ForegroundColor $coverageColor
Write-Host ""

Write-Host "Nota: Esta e uma estimativa baseada na estrutura de arquivos e testes." -ForegroundColor Gray
Write-Host "   Para cobertura precisa, use: cargo tarpaulin" -ForegroundColor Gray
Write-Host ""
