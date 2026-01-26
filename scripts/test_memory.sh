#!/bin/bash
set -e

echo "Running memory leak tests with ASan..."

export RUSTFLAGS="-C link-arg=-fsanitize=address -C link-arg=-fsanitize=undefined"
export ASAN_OPTIONS="detect_leaks=1"

cd native/odbc_engine
cargo test --release

echo "✓ Memory tests passed"
