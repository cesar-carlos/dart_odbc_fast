# Native Assets Implementation

## Overview

This package uses Dart Native Assets to automatically bundle and load
platform-specific Rust libraries.

## How it Works

1. **Development**: Libraries are loaded from `native/odbc_engine/target/release/`
2. **Production**: Libraries are bundled via GitHub Releases
3. **Fallback**: System library paths (PATH/LD_LIBRARY_PATH)

## Supported Platforms

- Windows x86_64
- Linux x86_64
- macOS x86_64 (Intel)
- macOS aarch64 (Apple Silicon)

## Build Process

1. GitHub Actions compiles for all platforms
2. Binaries are uploaded to GitHub Releases
3. Native Assets downloads the correct binary at install time
4. Library is loaded automatically

## Troubleshooting

### Library not found

Ensure you have ODBC drivers installed:
- Windows: Usually pre-installed
- Linux: `sudo apt-get install unixodbc`
- macOS: `brew install unixodbc`

### Build from source

```bash
cd native/odbc_engine
cargo build --release
```
