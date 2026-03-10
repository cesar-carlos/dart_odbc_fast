# ODBC Fast - Rust-native ODBC for Dart

[![CI](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/ci.yml/badge.svg)](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/ci.yml)
[![E2E Multi-DB](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/e2e_multidb.yml/badge.svg)](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/e2e_multidb.yml)
[![codecov](https://codecov.io/gh/cesar-carlos/dart_odbc_fast/branch/main/graph/badge.svg)](https://codecov.io/gh/cesar-carlos/dart_odbc_fast)

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
- Connection string validation, driver capabilities, and runtime version APIs
- Audit API and metadata cache controls
- Async query/stream lifecycle controls (`executeAsyncStart/asyncPoll/...`)
- Structured errors (SQLSTATE/native code)
- Runtime metrics and telemetry hooks

## Type Mapping

**Implemented input parameter types** (Dart → Database):
- `null`, `int` (32/64-bit auto), `String`, `List<int>` (binary)
- Canonical mappings:
  - `bool` → `Int(1|0)`
  - `double` → Decimal string with fixed scale (6)
    - `NaN` and `Infinity`/`-Infinity` throw `ArgumentError`
  - `DateTime` → UTC ISO8601 string
    - year must be in `[1, 9999]` (otherwise `ArgumentError`)

**Implemented result types** (Database → Dart):
- String (UTF-8), Int32, Int64
- Nullability preserved

**Planned (not yet implemented)**:
- Explicit SQL typing API (`SqlDataType`)
- Output parameters (SQL Server, Oracle)

See [`doc/notes/TYPE_MAPPING.md`](doc/notes/TYPE_MAPPING.md) for detailed reference and roadmap.

### Bulk insert validation behavior

`BulkInsertBuilder.addRow()` performs fail-fast validation:
- non-nullable columns reject `null` immediately (`StateError`)
- per-column type checks (`i32`, `i64`, `text`, `decimal`, `binary`, `timestamp`)
- text columns validate both character length and UTF-8 byte length against
  `maxLen` (`ArgumentError`)

Error messages include column name and row number to simplify debugging.

## API coverage (implemented)

### High-level service (`OdbcService`)

- Query execution: `executeQuery`, `executeQueryParams`, `executeQueryNamed`
- Prepared lifecycle: `prepare`, `prepareNamed`, `executePrepared`, `executePreparedNamed`, `cancelStatement`, `closeStatement`
- Incremental streaming: `streamQuery` (chunked `QueryResult` stream)
- Named parameters: `prepareNamed`, `executePreparedNamed`, `executeQueryNamed`
- Multi-result: `executeQueryMulti`, `executeQueryMultiFull`
- Metadata/catalog: `catalogTables`, `catalogColumns`, `catalogTypeInfo`, `catalogPrimaryKeys`, `catalogForeignKeys`, `catalogIndexes`
- Transactions: `beginTransaction`, `commitTransaction`, `rollbackTransaction`
- Savepoints: `createSavepoint`, `rollbackToSavepoint`, `releaseSavepoint`
- Pooling: `poolCreate`, `poolGetConnection`, `poolReleaseConnection`, `poolHealthCheck`, `poolGetState`, `poolGetStateDetailed`, `poolClose`
- Bulk insert: `bulkInsert`, `bulkInsertParallel` (pool-based, with fallback when `parallelism <= 1`)
- Operations/maintenance: `detectDriver`, `clearStatementCache`, `getMetrics`, `getPreparedStatementsMetrics`, `getVersion`, `validateConnectionString`, `getDriverCapabilities`
- Metadata cache: `metadataCacheEnable`, `metadataCacheStats`, `clearMetadataCache`
- Stream cancellation: `cancelStream`
- Audit: `setAuditEnabled`, `getAuditStatus`, `getAuditEvents`, `clearAuditEvents`
- Async lifecycle: `executeAsyncStart`, `asyncPoll`, `asyncGetResult`, `asyncCancel`, `asyncFree`, `streamStartAsync`, `streamPollAsync`

### Statement cancellation status

- `cancelStatement` is exposed in low-level and high-level APIs.
- Current runtime contract returns unsupported feature for statement cancellation
  (SQLSTATE `0A000`) because active background cancellation is not yet wired
  end-to-end.
- Use query timeout as workaround (`ConnectionOptions.queryTimeout`,
  prepare/statement timeout options).

### Parameter count limit (current runtime)

- Current native execution path supports up to **5 parameters** per execution
  for `executeQueryParams`, `executeQueryNamed`, `executePrepared`, and
  `executePreparedNamed`.
- This is a current implementation limit, not a long-term API goal.
- For larger payloads, prefer `bulkInsert`/`bulkInsertParallel` where applicable.

### Low-level wrappers (`NativeOdbcConnection`)

- Connection extras: `connectWithTimeout`, `getStructuredError`
- Wrapper helpers: `PreparedStatement`, `PreparedStatement.executeNamed`, `TransactionHandle`, `ConnectionPool`, `CatalogQuery`
- Streaming: `streamQueryBatched` (preferred), `streamQuery`
- Bulk insert: `bulkInsertArray`, `bulkInsertParallel`

### Advanced exported APIs

- Retry utilities: `RetryHelper`, `RetryOptions` (see `example/advanced_entities_demo.dart`)
- Statement/cache config: `StatementOptions`, `PreparedStatementConfig`
- Schema metadata entities: `PrimaryKeyInfo`, `ForeignKeyInfo`, `IndexInfo`
- Telemetry services/entities: `ITelemetryService`, `SimpleTelemetryService`, `ITelemetryRepository`, `Trace`, `Span`, `Metric`, `TelemetryEvent`
- Telemetry infrastructure: `OpenTelemetryFFI`, `TelemetryRepositoryImpl`, `TelemetryBuffer`

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

Direct async example (worker isolate, non-blocking):

```dart
final async = AsyncNativeOdbcConnection();
await async.initialize();

final connId = await async.connect('DSN=MyDsn');
final future = async.executeQueryParams(
  connId,
  'SELECT * FROM huge_table',
  const [],
);

// UI/event loop stays responsive while the worker executes the query.
final data = await future;
await async.disconnect(connId);
async.dispose();
```

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

## Connection String Builder

Fluent API for building ODBC connection strings:

```dart
final connStr = SqlServerBuilder()
  .server('localhost')
  .port(1433)
  .database('MyDB')
  .credentials('user', 'pass')
  .build();
```

Runnable demo: `dart run example/connection_string_builder_demo.dart`

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

All examples require `ODBC_TEST_DSN` (or `ODBC_DSN`) configured via environment variable or `.env` in project root.

```bash
dart run example/main.dart
dart run example/service_api_coverage_demo.dart
dart run example/advanced_entities_demo.dart
dart run example/connection_string_builder_demo.dart
dart run example/simple_demo.dart
dart run example/async_demo.dart
dart run example/async_service_locator_demo.dart
dart run example/named_parameters_demo.dart
dart run example/multi_result_demo.dart
dart run example/streaming_demo.dart
dart run example/pool_demo.dart
dart run example/savepoint_demo.dart
dart run example/catalog_reflection_demo.dart
dart run example/audit_example.dart
dart run example/execute_async_demo.dart
dart run example/telemetry_demo.dart
dart run example/otel_repository_demo.dart
```

Coverage-oriented examples:

- `example/service_api_coverage_demo.dart`: exercises service methods that are
  less visible in quick-start docs (`executeQueryParams`, `prepare`,
  `executePrepared`, `cancelStatement`, `closeStatement`, pool APIs,
  `bulkInsert`, `getVersion`, `validateConnectionString`,
  `getDriverCapabilities`, metadata cache controls, audit API, async
  request/stream lifecycle).
- `example/advanced_entities_demo.dart`: demonstrates exported advanced types
  and helpers (`RetryHelper`, `RetryOptions`, `PreparedStatementConfig`,
  `StatementOptions`, `PrimaryKeyInfo`, `ForeignKeyInfo`, `IndexInfo`).
- `example/audit_example.dart`: dedicated audit wrapper demo with
  enable/status/events/clear flow.
- `example/catalog_reflection_demo.dart`: focused schema reflection demo for
  `catalogPrimaryKeys`, `catalogForeignKeys`, and `catalogIndexes`.
- `example/execute_async_demo.dart`: low-level async execution and streaming
  via worker isolate using raw payload parsing.
- `example/telemetry_demo.dart` and `example/otel_repository_demo.dart`:
  telemetry service/buffer usage plus OTLP repository initialization.

More details: [example/README.md](example/README.md)

### Example Overview

#### High-Level API (`OdbcService`)

**[main.dart](example/main.dart)** - Complete API walkthrough

- ✅ Sync and async service modes
- ✅ Connection options with timeouts
- ✅ Driver detection
- ✅ Named parameters (@name, :name)
- ✅ Multi-result queries (executeQueryMultiFull)
- ✅ Catalog queries (tables, columns, types)
- ✅ Prepared statement reuse
- ✅ Statement cache management
- ✅ Runtime metrics and observability

**Advantages**:

- 🎯 High-level abstraction for common use cases
- 📊 Built-in metrics and telemetry hooks
- 🔄 Automatic connection lifecycle management
- ⚡ Optimized with prepared statement cache

#### Catalog Reflection

**[catalog_reflection_demo.dart](example/catalog_reflection_demo.dart)** -
Primary keys, foreign keys, and indexes

- ✅ `catalogPrimaryKeys`
- ✅ `catalogForeignKeys`
- ✅ `catalogIndexes`
- ✅ Simple output for migration/introspection workflows

#### Low-Level API (`NativeOdbcConnection`)

**[simple_demo.dart](example/simple_demo.dart)** - Native connection demo

- ✅ Connection with timeout (`connectWithTimeout`)
- ✅ Structured error handling (SQLSTATE + native codes)
- ✅ Transaction handles for safe operations
- ✅ Catalog queries for metadata introspection
- ✅ Prepared statements with result parsing
- ✅ Binary protocol parser for raw result handling

**Advantages**:

- 🔧 Direct control over ODBC driver manager
- ⚡ Zero-allocation result parsing
- 🛡️ Fine-grained error diagnostics
- 📦 Type-safe parameter handling

#### Async API

**[async_demo.dart](example/async_demo.dart)** - Async worker isolate demo

- ✅ Non-blocking operations (perfect for Flutter/UI)
- ✅ Configurable request timeout
- ✅ Automatic worker recovery on crash
- ✅ Worker isolate lifecycle management

**Advantages**:

- 🚀 Non-blocking UI thread
- 🔒 Configurable timeouts per request
- 🔄 Automatic recovery from failures
- 💪 Isolated worker for CPU-intensive tasks

#### Named Parameters

**[named_parameters_demo.dart](example/named_parameters_demo.dart)** - @name and :name syntax

- ✅ Standard SQL named parameter syntax
- ✅ Prepared statement reuse for performance
- ✅ Mixed @name and :name in same example
- ✅ Type-safe parameter binding

**Advantages**:

- 🛡 SQL injection protection (type-safe binding)
- ⚡ Reuse prepared statements for multiple executions
- 📝 Clean code with named parameters
- 🔌 Database-agnostic syntax (@name works on most DBs)

#### Multi-Result Queries

**[multi_result_demo.dart](example/multi_result_demo.dart)** - Multiple result sets

- ✅ Single query with multiple SELECT statements
- ✅ `executeQueryMulti` + `MultiResultParser`
- ✅ Parse multiple result sets from single payload
- ✅ Access to each result set independently

**Advantages**:

- 📦 Fewer round trips to database
- ⚡ Batch multiple operations in single request
- 🎯 Perfect for stored procedures with multiple results
- 📊 Automatic result set parsing

#### Connection Pooling

**[pool_demo.dart](example/pool_demo.dart)** - Connection pool management

- ✅ Pool creation with configurable size
- ✅ Connection reuse (get/release pattern)
- ✅ Parallel bulk insert via pool
- ✅ Health checks and pool state monitoring
- ✅ Concurrent connection testing

**Advantages**:

- 🚀 Reduced connection overhead (reuse established connections)
- 🔄 Automatic connection recovery and validation
- ⚡ Parallel bulk insert for high-throughput scenarios
- 📊 Pool state monitoring and metrics
- 🎯 Built-in health check on checkout

#### Streaming Queries

**[streaming_demo.dart](example/streaming_demo.dart)** - Incremental data streaming

- ✅ Batched streaming (`streamQueryBatched`) with configurable fetch size
- ✅ Custom chunk streaming (`streamQuery`) with flexible chunk sizes
- ✅ Process large datasets without loading all into memory
- ✅ Low-memory footprint for big tables

**Advantages**:

- 💾 Process millions of rows without OOM errors
- ⚡ Incremental processing reduces first-byte latency
- 🎯 Perfect for UI lists and infinite scrolling
- 🔒 Configurable chunk sizes for optimal performance
- 📊 Memory-efficient for large datasets

#### Transactions & Savepoints

**[savepoint_demo.dart](example/savepoint_demo.dart)** - Advanced transaction control

- ✅ Transaction begin/commit/rollback
- ✅ Savepoint creation (`createSavepoint`)
- ✅ Rollback to savepoint (`rollbackToSavepoint`)
- ✅ Nested savepoints for complex operations
- ✅ Release savepoint (`releaseSavepoint`)

**Advantages**:

- 🔒 Partial rollback support (undo specific changes)
- 🎯 Complex operation support with nested savepoints
- 🛡 Safe error recovery points
- 📝 Clean transaction management patterns
- 🔄 Granular control over transaction boundaries

## Build from source

```bash
cd native
cargo build --release
cd ..
dart test
```

Cross-platform Python helper script:

```bash
python scripts/build.py
```

For more script options, see [scripts/README.md](scripts/README.md)

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

- [doc/BUILD.md](doc/BUILD.md)
- [doc/version/RELEASE_AUTOMATION.md](doc/version/RELEASE_AUTOMATION.md)
- [doc/version/VERSIONING_STRATEGY.md](doc/version/VERSIONING_STRATEGY.md)
- [doc/version/VERSIONING_QUICK_REFERENCE.md](doc/version/VERSIONING_QUICK_REFERENCE.md)
- [doc/version/CHANGELOG_TEMPLATE.md](doc/version/CHANGELOG_TEMPLATE.md)
- [doc/notes/TYPE_MAPPING.md](doc/notes/TYPE_MAPPING.md)
- [doc/notes/FUTURE_IMPLEMENTATIONS.md](doc/notes/FUTURE_IMPLEMENTATIONS.md)
- [doc/notes/RELIABILITY_PERFORMANCE_IMPROVEMENTS_PLAN.md](doc/notes/RELIABILITY_PERFORMANCE_IMPROVEMENTS_PLAN.md)

Files under `doc/notes/` are working plans/backlog and may include features
that are not implemented yet.

## CI/CD

- CI workflow: `.github/workflows/ci.yml`
  - runs `cargo fmt`, `cargo clippy`, Rust build, `dart analyze`, and unit-only Dart tests (excluding `test/integration`, `test/e2e`, `test/stress`, `test/my_test`)
  - forces `ENABLE_E2E_TESTS=0` and `RUN_SKIPPED_TESTS=0`
- Release workflow: `.github/workflows/release.yml`
  - Validates release metadata (tag/pubspec/changelog)
  - Builds native binaries for Linux/Windows
  - Creates GitHub Release with assets
- **Publish workflow: `.github/workflows/publish.yml`**
  - Uses official Dart team reusable workflow with **OIDC authentication** (no secrets required)
  - Automatically publishes to pub.dev when tags matching `v{{version}}` are pushed
  - Requires automated publishing to be enabled on pub.dev admin panel

### Automated Release Flow

To publish a new version, follow these steps:

1. \*\*Update `pubspec.yaml`: Set the new version (e.g., `version: 1.1.0`)
2. \*\*Update `CHANGELOG.md`: Add a new section `## [1.1.0] - YYYY-MM-DD` with changes
3. **Commit and push main branch**:
   ```bash
   git add .
   git commit -m "Release v1.1.0"
   git push origin main
   ```
4. **Create and push tag** (triggers automated release):
   ```bash
   git tag -a v1.1.0 -m "Release v1.1.0"
   git push origin v1.1.0
   ```

The GitHub Actions will automatically:

- Verify tag format and consistency with pubspec/changelog
- Build native binaries for Linux and Windows
- Create GitHub Release with binaries
- **Publish to pub.dev** via OIDC (no manual intervention needed)

### Security

This project uses **OIDC (OpenID Connect)** for pub.dev authentication:

- No long-lived secrets required
- Temporary tokens are automatically managed by GitHub Actions
- See [Automated publishing documentation](https://dart.dev/tools/pub/automated-publishing) for details

## Support

If this project helps you, consider supporting the maintainer via Pix:

- `cesar_carlos@msn.com`

## License

MIT (see [LICENSE](LICENSE)).
