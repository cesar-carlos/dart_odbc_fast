# Heuristic coverage estimate (NOT real coverage).
# Counts .rs files and #[test], then applies formulas (for example: tests / (files * 3)).
# Does not execute tests and does not use instrumentation. Fast, but imprecise.
#
# For real coverage (HTML + LCOV), use: .\scripts\run_coverage.ps1
# (requires cargo install cargo-tarpaulin)

$ErrorActionPreference = "Stop"

Write-Host "=== Coverage Estimate (heuristic, does not execute tests) ===" -ForegroundColor Cyan
Write-Host ""

$projectRoot = Split-Path -Parent $PSScriptRoot
$srcPath = Join-Path $projectRoot "src"
$testsPath = Join-Path $projectRoot "tests"

# Count source files
$sourceFiles = Get-ChildItem -Path $srcPath -Filter "*.rs" -Recurse | Where-Object {
    $_.Name -ne "mod.rs" -or (Get-Content $_.FullName | Measure-Object -Line).Lines -gt 10
}
$totalSourceFiles = $sourceFiles.Count

# Count lines of code (approximate)
$totalLines = 0
$sourceFiles | ForEach-Object {
    $content = Get-Content $_.FullName -Raw
    $lines = ($content -split "`n").Count
    $totalLines += $lines
}

Write-Host "General Stats:" -ForegroundColor Yellow
Write-Host "  Source files: $totalSourceFiles"
Write-Host "  Lines of code (approx): $totalLines"
Write-Host ""

# Analyze modules
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

# Count files by module
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

# Count inline tests
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

# Count integration tests
$integrationTests = Get-ChildItem -Path $testsPath -Filter "*.rs" -ErrorAction SilentlyContinue
$integrationTestCount = 0
if ($integrationTests) {
    $integrationTests | ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        $testCount = ([regex]::Matches($content, '#\[test\]')).Count
        $integrationTestCount += $testCount
    }
}

Write-Host "Coverage by module:" -ForegroundColor Yellow
Write-Host ""

$totalTests = 0
$modules.GetEnumerator() | Sort-Object Name | ForEach-Object {
    $module = $_.Key
    $info = $_.Value
    $totalTests += $info.tests

    $coverage = if ($info.files -gt 0) {
        [math]::Round(($info.tests / ($info.files * 3)) * 100, 1)  # Estimate: 3 tests per file
    } else {
        0
    }

    $coverageColor = if ($coverage -ge 80) { "Green" }
                     elseif ($coverage -ge 50) { "Yellow" }
                     else { "Red" }

    Write-Host "  $($info.description.PadRight(25)) " -NoNewline
    Write-Host "Files: $($info.files.ToString().PadLeft(2)) " -NoNewline -ForegroundColor Cyan
    Write-Host "Tests: $($info.tests.ToString().PadLeft(3)) " -NoNewline -ForegroundColor Cyan
    Write-Host "Estimated coverage: " -NoNewline
    Write-Host "$coverage%" -ForegroundColor $coverageColor
}

Write-Host ""
Write-Host "Integration tests:" -ForegroundColor Yellow
Write-Host "  E2E/Integration tests: $integrationTestCount"
Write-Host ""

$totalTests += $integrationTestCount

Write-Host "Overall summary:" -ForegroundColor Yellow
Write-Host "  Total tests: $totalTests"
Write-Host "  Unit tests (inline): $($totalTests - $integrationTestCount)"
Write-Host "  Integration tests: $integrationTestCount"
Write-Host ""

# Estimate overall coverage
$estimatedCoverage = if ($totalSourceFiles -gt 0) {
    [math]::Round(($totalTests / ($totalSourceFiles * 2.5)) * 100, 1)  # Estimate: 2.5 tests per file
} else {
    0
}

$coverageColor = if ($estimatedCoverage -ge 80) { "Green" }
                 elseif ($estimatedCoverage -ge 50) { "Yellow" }
                 else { "Red" }

Write-Host "Estimated overall coverage: " -NoNewline -ForegroundColor Yellow
Write-Host "$estimatedCoverage%" -ForegroundColor $coverageColor
Write-Host ""

Write-Host "Note: This is an ESTIMATE (structure + #[test] count)." -ForegroundColor Gray
Write-Host "   REAL coverage: .\scripts\run_coverage.ps1 (cargo tarpaulin)" -ForegroundColor Gray
Write-Host ""
