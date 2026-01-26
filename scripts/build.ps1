# ODBC Fast - Build Script for Windows
# This script builds the Rust library and generates FFI bindings

param(
    [switch]$SkipRust,
    [switch]$SkipBindings
)

$ErrorActionPreference = "Stop"

Write-Host "=== ODBC Fast Build Script ===" -ForegroundColor Cyan
Write-Host ""

# Step 1: Build Rust library
if (-not $SkipRust) {
    Write-Host "[1/3] Building Rust library..." -ForegroundColor Yellow
    
    $rustPath = Get-Command cargo -ErrorAction SilentlyContinue
    if (-not $rustPath) {
        Write-Host "ERROR: Rust/Cargo not found in PATH" -ForegroundColor Red
        Write-Host "Please install Rust from https://rustup.rs/" -ForegroundColor Yellow
        Write-Host "Or add Rust to your PATH" -ForegroundColor Yellow
        exit 1
    }
    
    Push-Location "native\odbc_engine"
    
    try {
        Write-Host "  Running: cargo build --release" -ForegroundColor Gray
        cargo build --release
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: Rust build failed" -ForegroundColor Red
            exit 1
        }
        
        Write-Host "  ✓ Rust library built successfully" -ForegroundColor Green
        
        # Verify header was generated
        if (Test-Path "include\odbc_engine.h") {
            Write-Host "  ✓ C header generated: include\odbc_engine.h" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: Header not found, but build succeeded" -ForegroundColor Yellow
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Host "[1/3] Skipping Rust build (--SkipRust)" -ForegroundColor Gray
}

# Step 2: Generate Dart bindings
if (-not $SkipBindings) {
    Write-Host ""
    Write-Host "[2/3] Generating Dart FFI bindings..." -ForegroundColor Yellow
    
    $dartPath = Get-Command dart -ErrorAction SilentlyContinue
    if (-not $dartPath) {
        Write-Host "ERROR: Dart SDK not found in PATH" -ForegroundColor Red
        Write-Host "Please install Dart SDK from https://dart.dev/get-dart" -ForegroundColor Yellow
        exit 1
    }
    
    # Check if header exists
    if (-not (Test-Path "native\odbc_engine\include\odbc_engine.h")) {
        Write-Host "ERROR: C header not found. Run Rust build first." -ForegroundColor Red
        exit 1
    }
    
    Write-Host "  Running: dart run ffigen" -ForegroundColor Gray
    dart run ffigen
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: FFI bindings generation failed" -ForegroundColor Red
        exit 1
    }
    
    Write-Host "  ✓ Dart bindings generated: lib\infrastructure\native\bindings\odbc_bindings.dart" -ForegroundColor Green
} else {
    Write-Host "[2/3] Skipping bindings generation" -ForegroundColor Gray
}

# Step 3: Verify
Write-Host ""
Write-Host "[3/3] Verifying build..." -ForegroundColor Yellow

$dllPath = "native\odbc_engine\target\release\odbc_engine.dll"
if (Test-Path $dllPath) {
    $dllSize = (Get-Item $dllPath).Length / 1MB
    Write-Host "  ✓ Library found: $dllPath ($([math]::Round($dllSize, 2)) MB)" -ForegroundColor Green
} else {
    Write-Host "  WARNING: Library not found at expected path" -ForegroundColor Yellow
}

$bindingsPath = "lib\infrastructure\native\bindings\odbc_bindings.dart"
if (Test-Path $bindingsPath) {
    Write-Host "  ✓ Bindings found: $bindingsPath" -ForegroundColor Green
} else {
    Write-Host "  WARNING: Bindings not found" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Build Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Run tests: dart test" -ForegroundColor Gray
Write-Host "  2. Run example: dart run example/main.dart" -ForegroundColor Gray
Write-Host ""
