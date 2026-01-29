# ODBC Fast - Enterprise ODBC Data Platform

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
- **Savepoints** (nested transaction markers)
- **Automatic retry** with exponential backoff for transient errors
- **Connection timeouts** (login/connection timeout configuration)
- **Connection String Builder** (fluent API)
- **Backpressure control** in streaming queries

## Highlights

### Savepoints (Nested Transactions)

Create rollback points within transactions:

```dart
final txnId = await service.beginTransaction(connId, IsolationLevel.readCommitted);
await service.createSavepoint(connId, txnId, 'sp1');
// ... operations
await service.rollbackToSavepoint(connId, txnId, 'sp1'); // or releaseSavepoint
```

### Automatic Retry with Exponential Backoff

Automatic retry for transient errors (connection lost, timeouts):

```dart
final result = await service.withRetry(
  () => service.connect(dsn),
  options: RetryOptions(maxAttempts: 3, initialDelay: Duration(milliseconds: 100)),
);
```

### Connection options

Configure login/connection timeouts and result buffer size:

```dart
await service.connect(
  dsn,
  options: ConnectionOptions(
    loginTimeout: Duration(seconds: 30),
    maxResultBufferBytes: 32 * 1024 * 1024, // 32 MB (default: 16 MB)
  ),
);
```

- **loginTimeout** / **connectionTimeout**: ODBC login timeout.
- **maxResultBufferBytes**: maximum size in bytes for query result buffers on this connection. When null, `defaultMaxResultBufferBytes` (16 MB) is used. Increase for very large result sets to avoid "Buffer too small" errors; consider pagination (TOP/OFFSET-FETCH) for huge tables.

### Connection String Builder

Fluent API for building connection strings:

```dart
final connStr = SqlServerBuilder()
  .server('localhost')
  .port(1433)
  .database('MyDB')
  .credentials('user', 'pass')
  .build();
```

### Backpressure Control

For large result sets, prefer `streamQueryBatched` and tune batching:

- `fetchSize`: rows per batch (cursor-based)
- `chunkSize`: buffer size in bytes

**Examples**: see [example/README.md](example/README.md)

## Requirements

- Dart SDK >=3.0.0
- ODBC Driver Manager (unixODBC on Linux)

## Installation

### 1. Add dependency

```yaml
dependencies:
  odbc_fast: ^0.2.9
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
- **Troubleshooting**: [doc/TROUBLESHOOTING.md](doc/TROUBLESHOOTING.md)
- **Release automation**: [doc/RELEASE_AUTOMATION.md](doc/RELEASE_AUTOMATION.md)
- **Future implementations**: [doc/FUTURE_IMPLEMENTATIONS.md](doc/FUTURE_IMPLEMENTATIONS.md)
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

## Async API (Non-Blocking Operations)

ODBC Fast provides **true non-blocking database operations** using Dart isolates. All blocking FFI calls execute in a dedicated worker isolate, ensuring your UI stays responsive.

### Architecture

- **Main Thread**: Your app/UI code runs here
- **Worker Isolate**: Background isolate handles all FFI/ODBC calls
- **Message Protocol**: SendPort/ReceivePort for request/response communication
- **Binary Protocol**: Efficient Uint8List transfer between isolates

### Performance

- **Worker spawn (one-time)**: ~50–100ms
- **Per-operation overhead**: ~1–3ms
- **Parallel queries**: Multiple requests are queued and processed by the worker
- **UI responsiveness**: Event loop never blocks, even during long-running queries

### Example: True Non-Blocking

```dart
import 'package:odbc_fast/odbc_fast.dart';

Future<void> asyncDemo(String dsn) async {
  final async = AsyncNativeOdbcConnection();

  await async.initialize();
  final connId = await async.connect(dsn);

  // Long query - UI stays responsive
  final queryFuture = async.executeQueryParams(
    connId,
    'SELECT * FROM huge_table WHERE processing_takes_5_seconds',
    [],
  );

  // While query runs in worker isolate, UI can render, handle input, etc.
  final result = await queryFuture;

  await async.disconnect(connId);
}
```

Using ServiceLocator (recommended for Flutter):

```dart
final locator = ServiceLocator();
locator.initialize(useAsync: true);

final service = locator.asyncService;
await service.initialize();

final connResult = await service.connect(dsn);
await connResult.fold((connection) async {
  await service.executeQuery(connection.id, 'SELECT * FROM users');
  await service.disconnect(connection.id);
}, (error) async {});

locator.shutdown(); // Call on app exit when using async
```

### When to Use Async

**Use async for:**

- Flutter applications (required for responsive UI)
- Any UI application
- Long-running queries
- Parallel operations

**Use sync for:**

- CLI tools without UI
- Scripts where blocking is acceptable

### See Also

- Run `dart run example/async_demo.dart` for a complete async demonstration
- [Async API Integration Tests](test/integration/async_api_integration_test.dart)
- [Migration guide](doc/MIGRATION_ASYNC.md) for moving from sync to async

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

    // Multiple result sets (returns the first result set)
    await service.executeQueryMulti(connection.id, 'SELECT 1 AS a; SELECT 2 AS b;');

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

- **`streamQueryBatched`**: preferred for large result sets. Cursor-based batching;
  each batch is a complete protocol message. Use `fetchSize` (rows per batch) and
  `chunkSize` (buffer bytes).
- **`streamQuery`**: buffer mode; fetches full result then yields in chunks.
  Fallback when batched is unavailable.

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

  await for (final chunk in native.streamQueryBatched(connId, 'SELECT 1')) {
    // chunk.columns / chunk.rows / chunk.rowCount
  }

  native.disconnect(connId);
}
```

#### Typed parameters (low-level)

For explicit typing on the native API, use `ParamValue*` (and `serializeParams`
when you need raw bytes).

#### Convenience wrappers (low-level)

The low-level API also exposes wrappers to make imperative flows easier:

- `PreparedStatement` (via `NativeOdbcConnection.prepareStatement(...)`)
- `TransactionHandle` (via `NativeOdbcConnection.beginTransactionHandle(...)`)
- `ConnectionPool` (via `NativeOdbcConnection.createConnectionPool(...)`)
- `CatalogQuery` (via `NativeOdbcConnection.catalogQuery(...)`)

## CI/CD

Multi-platform validation runs on:

- Ubuntu (x86_64)
- Windows (x86_64)

See `.github/workflows/ci.yml` and `.github/workflows/release.yml` for details.

## Support the project

If this project helps you, consider buying the developer a coffee via Pix:

- **Pix**: `cesar_carlos@msn.com`

## License

MIT (see [LICENSE](LICENSE)).
