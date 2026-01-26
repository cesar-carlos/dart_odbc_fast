#!/bin/bash
set -e

echo "Verifying builds on all platforms..."

# Linux
echo "Building for Linux..."
cd native/odbc_engine
cargo build --release --target x86_64-unknown-linux-gnu
echo "✓ Linux build successful"

# Windows (if on Windows or cross-compiling)
if command -v x86_64-w64-mingw32-gcc &> /dev/null; then
    echo "Building for Windows..."
    cargo build --release --target x86_64-pc-windows-msvc
    echo "✓ Windows build successful"
fi

# macOS (if on macOS)
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "Building for macOS (x86_64)..."
    cargo build --release --target x86_64-apple-darwin
    echo "✓ macOS x86_64 build successful"
    
    echo "Building for macOS (aarch64)..."
    cargo build --release --target aarch64-apple-darwin
    echo "✓ macOS aarch64 build successful"
fi

echo "All builds verified!"
