# ODBC Fast - Enterprise ODBC Data Platform

[![M1 Validation](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/m1_validation.yml/badge.svg)](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/m1_validation.yml)
[![CI](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/ci.yml/badge.svg)](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/ci.yml)

Enterprise-grade ODBC data platform built with **Rust (native engine)** and
**Dart (clean, testable API)**.

## Why a Rust native engine?

This project uses Rust at the lowest level to communicate directly with the
ODBC driver manager / ODBC drivers (via native ODBC APIs), and exposes a stable
C-ABI surface to Dart through `dart:ffi`.

Benefits:

- **Performance**: low overhead (no platform channels), streaming results, and
  binary protocol buffers to reduce allocations and copying.
- **Memory safety**: Rust ownership + borrow checker help prevent common native
  issues (use-after-free, double-free, buffer overflows) in the engine layer.
- **Thread safety**: safer concurrency primitives and a design that isolates
  errors per connection to avoid cross-thread races.
- **Portability**: build once per target (Windows / Linux), load as a
  native library from Dart.

## No third‑party ODBC packages

Instead of relying on platform-specific ODBC “plugins” or third-party bindings,
the ODBC engine is implemented in-repo (Rust) and the Dart side uses FFI
bindings + a clean architecture façade (`OdbcService` / `IOdbcRepository`).

## Features

- High-performance Rust engine
- Clean Architecture Dart API
- Multi-driver ODBC support
- 64-bit only architecture
- **Connection-specific error isolation** - Thread-safe error handling prevents race conditions in concurrent scenarios
- **Intelligent error categorization** - Automatic classification (Transient, Fatal, Validation, ConnectionLost) for smart retry logic
- **Structured error information** - SQLSTATE, native codes, and detailed messages for better diagnostics
- **Streaming queries** (chunked results)
- **Prepared statements** + typed parameters
- **Parameterized queries** (positional parameters)
- **Metadata/catalog queries** (tables / columns / type info)
- **Connection pooling** helpers (create/get/release/health/state/close)
- **Bulk insert payload builder** (binary protocol) + bulk insert execution
- **Metrics/observability** (query count, errors, latency, uptime)

## Requirements

- Dart SDK >=3.0.0
- ODBC Driver Manager (unixODBC on Linux)

## Installation

### 1. Add dependency

```yaml
dependencies:
  odbc_fast: ^0.1.1
```

### 2. Install ODBC drivers

- **Windows**: Pre-installed
- **Linux**: `sudo apt-get install unixodbc`

### 3. Run pub get

```bash
dart pub get
```

The native library will be **automatically downloaded** from GitHub Releases
on first run and cached locally (~/.cache/odbc_fast/).

## How It Works

### Native Assets with Automatic Download

This package uses Dart Native Assets to automatically manage the native
Rust library:

1. **Automatic Download**: On first `dart pub get`, the appropriate binary
   for your platform is downloaded from GitHub Releases
2. **Local Cache**: Binaries are cached in `~/.cache/odbc_fast/`
3. **Development**: When building from source, the local build is used
4. **Multi-Platform**: Supports Windows (x64) and Linux (x64)

### Supported Platforms

- ✅ Windows x86_64
- ✅ Linux x86_64

## Building

### For Development

If you want to build from source:

**Windows:**
```powershell
.\scripts\build.ps1
```

**Linux:**
```bash
chmod +x scripts/build.sh
./scripts/build.sh
```

### Manual Build

```bash
# Build Rust library (generates C header automatically)
cd native/odbc_engine
cargo build --release

# Dart bindings are hand-maintained; ffigen is optional (see doc/BUILD.md)
cd ../..
dart test
```

📖 **Para instruções detalhadas, veja [doc/BUILD.md](doc/BUILD.md)**

## Status

✅ **PROJETO COMPLETO & COMPILÁVEL** - Todas as 16 fases implementadas  
✅ **Rust Engine**: 0 erros, build OK, 3 tests passando  
✅ **Dart API**: 0 erros, análise limpa  
✅ **FFI Artifacts**: DLL (1.06 MB), Header, Bindings OK  

### Milestones

✅ **M1 Complete** - Functional Binding  
✅ **M2 Complete** - Production Engine (Binary Protocol, Streaming, Pooling)  
✅ **M3 Complete** - Enterprise Platform (Columnar, Compression, Plugins, Observability)

### Quick Validation

```powershell
# Validar tudo de uma vez
.\scripts\validate_all.ps1
```

## Architecture

This project follows Clean Architecture principles:

- **Domain**: Pure business logic (entities, repositories interfaces)
- **Application**: Use cases and services
- **Infrastructure**: Native ODBC implementation, FFI bindings
- **Presentation**: Public Dart API

## Project Structure

```
dart_odbc_fast/
├── native/              # Rust workspace
│   └── odbc_engine/     # ODBC engine library
├── lib/                 # Dart package
│   ├── domain/         # Domain layer
│   ├── application/    # Application layer
│   ├── infrastructure/ # Infrastructure layer
│   └── core/           # Core utilities
├── hook/               # Native Assets build hooks
├── test/               # Tests
└── doc/                # Documentation
```

## Documentation

- **Build**: [doc/BUILD.md](doc/BUILD.md)
- **Native Assets**: [doc/NATIVE_ASSETS.md](doc/NATIVE_ASSETS.md)
- **Milestones**: [doc/m1_milestone.md](doc/m1_milestone.md), [doc/m2_milestone.md](doc/m2_milestone.md), [doc/m3_milestone.md](doc/m3_milestone.md)
- **API governance**: [doc/api_governance.md](doc/api_governance.md)
- **Index**: [doc/README.md](doc/README.md)

## Testing

```bash
# Run all tests
dart test

# Integration tests (use ODBC_TEST_DSN from .env or environment)
dart test test/integration/

# Stress tests
dart test test/stress/

# Validation tests
dart test test/validation/

# Benchmarks
dart run benchmarks/m1_baseline.dart
dart run benchmarks/m2_performance.dart
```

Configure `ODBC_TEST_DSN` in project root `.env` (see `.env` example comments) or as environment variable for integration/stress/validation tests.

## Examples

You can run the bundled example:

```bash
dart run example/main.dart
```

It reads `ODBC_TEST_DSN` (or `ODBC_DSN`) from:

- project root `.env` (see `.env.example`)
- or environment variables

### High-level API (Clean Architecture)

Most features are exposed via `OdbcService` (which wraps `IOdbcRepository` and
returns `Result`):

```dart
import 'package:odbc_fast/odbc_fast.dart';

Future<void> demo(OdbcService service, String dsn) async {
  await service.initialize();

  final connResult = await service.connect(dsn);
  await connResult.fold((connection) async {
    // Basic query
    await service.executeQuery(connection.id, 'SELECT 1');

    // Parameterized query (positional parameters)
    await service.executeQueryParams(
      connection.id,
      'SELECT ? AS a, ? AS b',
      [1, 'hello'],
    );

    // Prepared statement + execute
    final stmtIdResult = await service.prepare(
      connection.id,
      'SELECT ? AS id, ? AS msg',
      timeoutMs: 0,
    );
    await stmtIdResult.fold((stmtId) async {
      await service.executePrepared(connection.id, stmtId, [123, 'ok']);
      await service.closeStatement(connection.id, stmtId);
    }, (_) async {});

    // Transaction helpers
    final txnIdResult = await service.beginTransaction(
      connection.id,
      IsolationLevel.readCommitted,
    );
    await txnIdResult.fold((txnId) async {
      await service.commitTransaction(connection.id, txnId);
    }, (_) async {});

    // Catalog (metadata)
    await service.catalogTables(connection.id);
    await service.catalogTypeInfo(connection.id);

    // Pooling
    final poolIdResult = await service.poolCreate(dsn, 4);
    await poolIdResult.fold((poolId) async {
      await service.poolHealthCheck(poolId);
      await service.poolGetState(poolId);
      await service.poolClose(poolId);
    }, (_) async {});

    // Bulk insert payload builder (binary protocol)
    final builder = BulkInsertBuilder()
        .table('my_table')
        .addColumn('id', BulkColumnType.i32)
        .addColumn('name', BulkColumnType.text, maxLen: 64)
        .addRow([1, 'alice'])
        .addRow([2, 'bob']);

    await service.bulkInsert(
      connection.id,
      builder.tableName,
      builder.columnNames,
      builder.build(),
      builder.rowCount,
    );

    // Metrics
    await service.getMetrics();

    await service.disconnect(connection.id);
  }, (_) async {});
}
```

### Low-level API (native + streaming)

If you want direct access to native wrappers (including streaming), use
`NativeOdbcConnection`:

```dart
import 'package:odbc_fast/odbc_fast.dart';

Future<void> streamingDemo(String dsn) async {
  final native = NativeOdbcConnection();
  if (!native.initialize()) {
    throw StateError('ODBC init failed: ${native.getError()}');
  }

  final connId = native.connect(dsn);
  if (connId == 0) {
    final se = native.getStructuredError();
    throw StateError(se?.message ?? native.getError());
  }

  await for (final chunk in native.streamQuery(connId, 'SELECT 1', chunkSize: 1000)) {
    // chunk.columns / chunk.rows / chunk.rowCount
  }

  native.disconnect(connId);
}
```

## CI/CD

Multi-platform validation runs on:
- Ubuntu (x86_64)
- Windows (x86_64)

See `.github/workflows/m1_validation.yml` for details.

## License

MIT (see [LICENSE](LICENSE)).
