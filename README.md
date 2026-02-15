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
- Bulk insert payload builder
- Structured errors (SQLSTATE/native code)
- Runtime metrics and telemetry hooks

## API coverage (implemented)

### High-level service (`OdbcService`)

- Query execution: `executeQuery`, `executeQueryParams`
- Named parameters: `prepareNamed`, `executePreparedNamed`, `executeQueryNamed`
- Multi-result: `executeQueryMulti`, `executeQueryMultiFull`
- Metadata/catalog: `catalogTables`, `catalogColumns`, `catalogTypeInfo`
- Transactions: `beginTransaction`, `commitTransaction`, `rollbackTransaction`
- Savepoints: `createSavepoint`, `rollbackToSavepoint`, `releaseSavepoint`
- Pooling: `poolCreate`, `poolGetConnection`, `poolReleaseConnection`, `poolHealthCheck`, `poolGetState`, `poolClose`
- Operations/maintenance: `detectDriver`, `clearStatementCache`, `getMetrics`, `getPreparedStatementsMetrics`

### Low-level wrappers (`NativeOdbcConnection`)

- Connection extras: `connectWithTimeout`, `getStructuredError`
- Wrapper helpers: `PreparedStatement`, `PreparedStatement.executeNamed`, `TransactionHandle`, `ConnectionPool`, `CatalogQuery`
- Streaming: `streamQueryBatched` (preferred), `streamQuery`

## Requirements

- Dart SDK `>=3.6.0 <4.0.0`
- ODBC Driver Manager
  - Windows: already available with ODBC stack
  - Linux: `unixodbc` / `unixodbc-dev`

## Installation

```yaml
dependencies:
  odbc_fast: ^0.3.1
```

Then:

```bash
dart pub get
```

Native binary resolution order is documented in [doc/BUILD.md](doc/BUILD.md).

## Quick Start (High-level service)

```dart
import 'package:odbc_fast/core/di/service_locator.dart';
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
```

Integration/stress tests require `ODBC_TEST_DSN` in `.env` or environment.

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
- Release workflow: `.github/workflows/release.yml`

## Support

If this project helps you, consider supporting the maintainer via Pix:

- `cesar_carlos@msn.com`

## License

MIT (see [LICENSE](LICENSE)).
