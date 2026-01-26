# Release v0.1.2 - Windows and Linux Only

This release removes macOS support and focuses on Windows and Linux platforms.

## What's Included

**Windows x86_64:**
* Pre-built binary: odbc_engine.dll (1.4 MB)
* Automatic download via Native Assets
* No compilation required

**Linux x86_64:**
* Build from source required
* Run: cargo build --release

## Installation

**Windows:**
```yaml
dependencies:
  odbc_fast: ^0.1.2
```

Run: `dart pub get`

**Linux:**
```bash
cd native/odbc_engine
cargo build --release
dart pub get
```

## Supported Platforms

* Windows x86_64
* Linux x86_64

## System Requirements

* Windows: ODBC Driver Manager (pre-installed)
* Linux: unixODBC (`sudo apt-get install unixodbc`)

## Changes from v0.1.1

* Removed macOS support entirely
* Simplified CI/CD workflows
* Optimized for 2 platforms only
