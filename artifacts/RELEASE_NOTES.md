# Release v0.1.6 - Batched Streaming + Publish Fixes

This release adds cursor-based batched streaming and fixes pub publishing so
native Dart sources under `lib/infrastructure/native/` are included correctly.

## What's Included

**Windows x86_64:**
- Pre-built binary: `odbc_engine.dll`
- Automatic download via Native Assets
- No compilation required

**Linux x86_64:**
- Pre-built binary: `libodbc_engine.so` (via GitHub Releases)
- Automatic download via Native Assets

## Installation

```yaml
dependencies:
  odbc_fast: ^0.1.6
```

Run: `dart pub get`

## Supported Platforms

* Windows x86_64
* Linux x86_64

## System Requirements

* Windows: ODBC Driver Manager (pre-installed)
* Linux: unixODBC (`sudo apt-get install unixodbc`)

## Highlights

- Added `streamQueryBatched` for efficient large result sets
- `executeQuery` now prefers batched streaming with safe fallback
- Fixed publish packaging so `dart analyze` / `dartdoc` work on pub.dev

