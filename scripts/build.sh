#!/bin/bash
# ODBC Fast - Build Script for Linux/macOS
# This script builds the Rust library and generates FFI bindings

set -e

SKIP_RUST=false
SKIP_BINDINGS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-rust)
            SKIP_RUST=true
            shift
            ;;
        --skip-bindings)
            SKIP_BINDINGS=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "=== ODBC Fast Build Script ==="
echo ""

# Step 1: Build Rust library
if [ "$SKIP_RUST" = false ]; then
    echo "[1/3] Building Rust library..."
    
    if ! command -v cargo &> /dev/null; then
        echo "ERROR: Rust/Cargo not found in PATH"
        echo "Please install Rust from https://rustup.rs/"
        exit 1
    fi
    
    cd native/odbc_engine
    
    echo "  Running: cargo build --release"
    cargo build --release
    
    if [ $? -ne 0 ]; then
        echo "ERROR: Rust build failed"
        exit 1
    fi
    
    echo "  ✓ Rust library built successfully"
    
    # Verify header was generated
    if [ -f "include/odbc_engine.h" ]; then
        echo "  ✓ C header generated: include/odbc_engine.h"
    else
        echo "  WARNING: Header not found, but build succeeded"
    fi
    
    cd ../..
else
    echo "[1/3] Skipping Rust build (--skip-rust)"
fi

# Step 2: Generate Dart bindings
if [ "$SKIP_BINDINGS" = false ]; then
    echo ""
    echo "[2/3] Generating Dart FFI bindings..."
    
    if ! command -v dart &> /dev/null; then
        echo "ERROR: Dart SDK not found in PATH"
        echo "Please install Dart SDK from https://dart.dev/get-dart"
        exit 1
    fi
    
    # Check if header exists
    if [ ! -f "native/odbc_engine/include/odbc_engine.h" ]; then
        echo "ERROR: C header not found. Run Rust build first."
        exit 1
    fi
    
    echo "  Running: dart run ffigen"
    dart run ffigen
    
    if [ $? -ne 0 ]; then
        echo "ERROR: FFI bindings generation failed"
        exit 1
    fi
    
    echo "  ✓ Dart bindings generated: lib/infrastructure/native/bindings/odbc_bindings.dart"
else
    echo "[2/3] Skipping bindings generation (--skip-bindings)"
fi

# Step 3: Verify
echo ""
echo "[3/3] Verifying build..."

# Determine library extension based on OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    LIB_PATH="native/odbc_engine/target/release/libodbc_engine.dylib"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    LIB_PATH="native/odbc_engine/target/release/libodbc_engine.so"
else
    LIB_PATH=""
fi

if [ -n "$LIB_PATH" ] && [ -f "$LIB_PATH" ]; then
    LIB_SIZE=$(du -h "$LIB_PATH" | cut -f1)
    echo "  ✓ Library found: $LIB_PATH ($LIB_SIZE)"
else
    echo "  WARNING: Library not found at expected path"
fi

BINDINGS_PATH="lib/infrastructure/native/bindings/odbc_bindings.dart"
if [ -f "$BINDINGS_PATH" ]; then
    echo "  ✓ Bindings found: $BINDINGS_PATH"
else
    echo "  WARNING: Bindings not found"
fi

echo ""
echo "=== Build Complete ==="
echo ""
echo "Next steps:"
echo "  1. Run tests: dart test"
echo "  2. Run example: dart run example/main.dart"
echo ""
