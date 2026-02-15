# ODBC Fast - Rust-native ODBC for Dart

[![CI](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/ci.yml/badge.svg)](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/ci.yml)

`odbc_fast` is an ODBC data access package for Dart backed by an in-repo Rust engine over `dart:ffi`.

## Why Rust + FFI

- Low overhead (no platform channels)
- Strong memory/thread safety guarantees in the native layer
- Portable native binaries for Windows/Linux x64
- Direct control over ODBC driver manager interaction

## Features

- Sync and async database access (async via worker isolate)
- Prepared statements and named parameters (`@name`, `:name`)
- Multi-result queries (`executeQueryMulti`, `executeQueryMultiFull`)
- Streaming queries (`streamQueryBatched`, `streamQuery`)
- Connection pooling
- Transactions and savepoints
- Bulk insert payload builder and parallel bulk insert via pool
- Structured errors (SQLSTATE/native code)
- Runtime metrics and telemetry hooks

## API coverage (implemented)

### High-level service (`OdbcService`)

- Query execution: `executeQuery`, `executeQueryParams`
- Incremental streaming: `streamQuery` (chunked `QueryResult` stream)
- Named parameters: `prepareNamed`, `executePreparedNamed`, `executeQueryNamed`
- Multi-result: `executeQueryMulti`, `executeQueryMultiFull`
- Metadata/catalog: `catalogTables`, `catalogColumns`, `catalogTypeInfo`
- Transactions: `beginTransaction`, `commitTransaction`, `rollbackTransaction`
- Savepoints: `createSavepoint`, `rollbackToSavepoint`, `releaseSavepoint`
- Pooling: `poolCreate`, `poolGetConnection`, `poolReleaseConnection`, `poolHealthCheck`, `poolGetState`, `poolClose`
- Bulk insert: `bulkInsert`, `bulkInsertParallel` (pool-based, with fallback when `parallelism <= 1`)
- Operations/maintenance: `detectDriver`, `clearStatementCache`, `getMetrics`, `getPreparedStatementsMetrics`

### Low-level wrappers (`NativeOdbcConnection`)

- Connection extras: `connectWithTimeout`, `getStructuredError`
- Wrapper helpers: `PreparedStatement`, `PreparedStatement.executeNamed`, `TransactionHandle`, `ConnectionPool`, `CatalogQuery`
- Streaming: `streamQueryBatched` (preferred), `streamQuery`
- Bulk insert: `bulkInsertArray`, `bulkInsertParallel`

## Requirements

- Dart SDK `>=3.6.0 <4.0.0`
- ODBC Driver Manager
  - Windows: already available with ODBC stack
  - Linux: `unixodbc` / `unixodbc-dev`

## Installation

```yaml
dependencies:
  odbc_fast: ^1.0.0
```

Then:

```bash
dart pub get
```

Native binary resolution order is documented in [doc/BUILD.md](doc/BUILD.md).

## Quick Start (High-level service)

`ServiceLocator` is exported by `package:odbc_fast/odbc_fast.dart`.

```dart
import 'package:odbc_fast/odbc_fast.dart';

Future<void> main() async {
  final locator = ServiceLocator()..initialize();
  final service = locator.syncService;

  final init = await service.initialize();
  if (init.isError()) return;

  final connResult = await service.connect('DSN=MyDsn');
  final conn = connResult.getOrNull();
  if (conn == null) return;

  try {
    final query = await service.executeQuery(
      "SELECT 1 AS id, 'ok' AS msg",
      connectionId: conn.id,
    );

    query.fold(
      (r) => print('rows=${r.rowCount} columns=${r.columns}'),
      (e) => print('query error: $e'),
    );
  } finally {
    await service.disconnect(conn.id);
  }
}
```

## Async API (non-blocking)

Use async mode in UI apps (especially Flutter):

```dart
final locator = ServiceLocator()..initialize(useAsync: true);
final service = locator.asyncService;

await service.initialize();
final connResult = await service.connect('DSN=MyDsn');
final conn = connResult.getOrNull();
if (conn != null) {
  await service.executeQuery('SELECT * FROM users', connectionId: conn.id);
  await service.disconnect(conn.id);
}

locator.shutdown();
```

If you use `AsyncNativeOdbcConnection` directly, you can also configure:

- `requestTimeout` for worker response timeout
- `autoRecoverOnWorkerCrash` for automatic worker re-initialization

Async streaming (`streamQuery` / `streamQueryBatched`) uses the native
stream protocol through the worker isolate (`stream_start/fetch/close`),
instead of fetching full result sets in a single call.

For high-level incremental consumption without materializing all rows:

```dart
await for (final chunkResult in service.streamQuery(conn.id, 'SELECT * FROM big_table')) {
  chunkResult.fold(
    (chunk) => print('chunk rows=${chunk.rowCount}'),
    (err) => print('stream error: $err'),
  );
}
```

Streaming errors are now classified with clearer messages:

- protocol/frame errors: `Streaming protocol error: ...`
- timeout: `Query timed out`
- worker interruption/dispose: `Streaming interrupted: ...`
- SQL/driver errors (when structured error is available):
  `Streaming SQL error: ...` (+ SQLSTATE/native code)

## Connection options example

```dart
final result = await service.connect(
  'DSN=MyDsn',
  options: ConnectionOptions(
    loginTimeout: Duration(seconds: 30),
    initialResultBufferBytes: 256 * 1024,
    maxResultBufferBytes: 32 * 1024 * 1024,
    queryTimeout: Duration(seconds: 10),
    autoReconnectOnConnectionLost: true,
    maxReconnectAttempts: 3,
    reconnectBackoff: Duration(seconds: 1),
  ),
);
```

Validation rules:

- timeouts/backoff must be non-negative
- `maxResultBufferBytes` and `initialResultBufferBytes` must be `> 0`
- `initialResultBufferBytes` cannot be greater than `maxResultBufferBytes`

## Pool checkout validation tuning

By default, the Rust pool validates a connection on checkout (`SELECT 1`),
which is safer but adds latency under high contention.

For controlled high-throughput workloads, disable checkout validation:

- connection string override (per pool):
  `DSN=MyDsn;PoolTestOnCheckout=false;`
- environment override (global fallback):
  `ODBC_POOL_TEST_ON_CHECKOUT=false`

Accepted boolean values: `true/false`, `1/0`, `yes/no`, `on/off`.
Connection-string override takes precedence over environment value.

## Examples

Run examples from project root:

```bash
dart run example/main.dart
dart run example/simple_demo.dart
dart run example/async_demo.dart
dart run example/named_parameters_demo.dart
dart run example/multi_result_demo.dart
dart run example/streaming_demo.dart
dart run example/pool_demo.dart
dart run example/savepoint_demo.dart
```

More details: [example/README.md](example/README.md)

## Build from source

```bash
cd native
cargo build --release
cd ..
dart test
```

Windows helper script:

```powershell
.\scripts\build.ps1
```

Linux helper script:

```bash
./scripts/build.sh
```

## Testing

```bash
# all tests
dart test

# integration
dart test test/integration/

# stress
dart test test/stress/

# validation
dart test test/validation/

# benchmarks
dart run benchmarks/m1_baseline.dart
dart run benchmarks/m2_performance.dart

# rust bulk insert benchmark (array vs parallel)
cargo test --test e2e_bulk_compare_benchmark_test -- --ignored --nocapture
```

Integration/stress tests require `ODBC_TEST_DSN` in `.env` or environment.
For the Rust bulk benchmark, also set `ENABLE_E2E_TESTS=true`.
Optional tuning: `BULK_BENCH_SMALL_ROWS` and `BULK_BENCH_MEDIUM_ROWS`.

## Project structure

```text
dart_odbc_fast/
|- native/        # Rust workspace (odbc_engine)
|- lib/           # Dart package sources
|- hook/          # Native assets hooks
|- test/          # Test suites
`- doc/           # Documentation
```

## Documentation

- [doc/README.md](doc/README.md)
- [doc/BUILD.md](doc/BUILD.md)
- [doc/TROUBLESHOOTING.md](doc/TROUBLESHOOTING.md)
- [doc/RELEASE_AUTOMATION.md](doc/RELEASE_AUTOMATION.md)
- [doc/VERSIONING_STRATEGY.md](doc/VERSIONING_STRATEGY.md)
- [doc/VERSIONING_QUICK_REFERENCE.md](doc/VERSIONING_QUICK_REFERENCE.md)
- [doc/OBSERVABILITY.md](doc/OBSERVABILITY.md)
- [doc/FUTURE_IMPLEMENTATIONS.md](doc/FUTURE_IMPLEMENTATIONS.md)

## CI/CD

- CI workflow: `.github/workflows/ci.yml`
  - runs `cargo fmt`, `cargo clippy`, Rust build, `dart analyze`, and unit-only Dart tests (excluding `test/integration`, `test/e2e`, `test/stress`, `test/my_test`)
  - forces `ENABLE_E2E_TESTS=0` and `RUN_SKIPPED_TESTS=0`
- Release workflow: `.github/workflows/release.yml`

## Support

If this project helps you, consider supporting the maintainer via Pix:

- `cesar_carlos@msn.com`

## License

MIT (see [LICENSE](LICENSE)).
