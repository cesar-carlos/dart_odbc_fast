# ODBC Fast - Rust-native ODBC for Dart

[![CI](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/ci.yml/badge.svg)](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/ci.yml)
[![E2E Multi-DB](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/e2e_multidb.yml/badge.svg)](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/e2e_multidb.yml)
[![codecov](https://codecov.io/gh/cesar-carlos/dart_odbc_fast/branch/main/graph/badge.svg)](https://codecov.io/gh/cesar-carlos/dart_odbc_fast)

`odbc_fast` is an ODBC data access package for Dart backed by an in-repo Rust engine over `dart:ffi`.

## Support

If this project helps you, consider supporting the maintainer via Pix:

- `cesar_carlos@msn.com`

## What's New in 5.0

Current package version: **5.0.0**. This major release hardens error handling,
transaction completion, worker lifecycle and protocol buffer ownership.
Public Dart signatures and the native ABI remain supported, but recovery
behavior and non-ASCII XID encoding require migration from 4.x.
Full history: [CHANGELOG.md](CHANGELOG.md).
Open work: [`doc/Features/PENDING_IMPLEMENTATIONS.md`](doc/Features/PENDING_IMPLEMENTATIONS.md).

### Highlights

- Request-scoped `OdbcErrorCode` / `OdbcErrorDetails`, clear `userMessage`,
  and consistent service/repository `Result` failures.
- Reconnection without query replay by default, and guarded local/XA
  transaction completion when the outcome is uncertain.
- Shared initialization, generation-safe disposal and late-reply cleanup
  without completing the caller a second time.
- Stable exposed buffer views, cursor-based frame assembly and indexed
  `QueryResultReader` access.
- UTF-8 XIDs with explicit original-byte recovery for older non-ASCII branches.
- Consolidated performance examples using batches, typed arrays, prepared
  reuse, bounded bulk payloads and bounded pool concurrency.

### Migrating from 4.x

- `autoReconnectOnConnectionLost` restores connections for future operations.
  Set `replayQueriesAfterReconnect: true` only when repeating the failed query
  is safe. Reconnection and replay are blocked inside local/XA transactions.
- Recover older non-ASCII XA branches using `Xid` with their original bytes.
  `Xid.fromStrings` now uses UTF-8, enforces limits after encoding and rejects
  unpaired UTF-16 surrogates. ASCII and explicit binary identifiers are unchanged.
- An uncertain transaction completion blocks queries, savepoints, further
  completion and pool return. Inspect `OdbcError.details.outcomeUnknown` and XA
  handle state; recover explicitly. A timeout does not confirm driver
  cancellation, and a failed commit is not automatically rolled back or retried.

Details: [5.0.0 migration notes](CHANGELOG.md#500---2026-10-03) and
[doc/PERFORMANCE.md](doc/PERFORMANCE.md).

### XA / 2PC engines

| Engine | Status |
| ------ | ------ |
| PostgreSQL | ✅ `PREPARE TRANSACTION` + `pg_prepared_xacts` |
| MySQL / MariaDB | ✅ `XA START / END / PREPARE / COMMIT / RECOVER` |
| DB2 | ✅ same SQL grammar as MySQL |
| Oracle | ✅ `SYS.DBMS_XA` + `DBA_PENDING_TRANSACTIONS` |
| SQL Server (MSDTC) | ✅ Windows + `--features xa-dtc` (advanced Reenlist still open — PENDING §2.1) |
| SQLite / Snowflake | ❌ `UnsupportedFeature` |

XA works on sync and async service paths (`ServiceLocator.syncService` /
isolate backend / `runInXaTransaction`). See
[`example/xa_2pc_demo.dart`](example/xa_2pc_demo.dart).

### Docs index

Start at [`doc/README.md`](doc/README.md) for architecture, API surface,
capabilities, testing, and performance. Examples:
[`example/README.md`](example/README.md).

## Why Rust + FFI

- Low overhead (no platform channels)
- Strong memory/thread safety guarantees in the native layer
- Portable native binaries for Windows/Linux x64
- Direct control over ODBC driver manager interaction

## Features

- Sync and async database access (async via worker isolate)
- Prepared statements and named parameters (`@name`, `:name`)
- Multi-result queries (`executeQueryMulti`, `executeQueryMultiFull`,
  `executeQueryMultiParamValues`, streaming `streamQueryMulti` and
  `streamQueryMultiBatches`)
- Streaming queries (`streamQueryBatched`, `streamQuery`, `streamQueryNamed`)
- **Sub-interfaces of `IOdbcService`**: `IQueryService`,
  `ITransactionService`, `IPoolService`, `IAdminService` — depend on the
  narrow seam your code actually uses (Interface Segregation). Each ships
  `...For(Connection conn, ...)` overloads so call sites no longer thread
  `connection.id` around
- **Event bus**: `IAdminService.events` returns a broadcast
  `Stream<OdbcEvent>` with sealed variants (`ConnectionLost`,
  `WorkerRecovered`, `AutoReconnectAttempted`, `PoolResize`,
  `SlowQueryDetected`) for log/metric/observability pipelines
- **Typed columnar results**: `executeQueryColumnarParamValues` /
  `streamQueryColumnar` return `TypedColumnarResult` with
  `Int32List` / `Int64List` / `Float64List` per numeric column, avoiding
  a boxed row representation for numeric processing
- **`QueryResultAccess`**: typed row/column navigation on
  `QueryResult` without changing row storage. Use `result.reader()` for repeated
  column-name lookups; `rowsAsMaps` allocates a map for each row.
- **Repository extensions**: columnar execute/stream,
  `…For(Connection)` overloads, `…FromObjects` typed-parameter bridges, and
  `runInTransaction` — same ergonomics as the service sub-interfaces
- **Transaction helpers**: `runInTransaction<T>` and
  `runInXaTransaction<T>` orchestrate begin → action → commit/rollback
  (or end → prepare → commit_prepared for XA) with throw-safe cleanup
- Connection pooling with **configurable eviction/timeouts**
  (`PoolOptions`: `idleTimeout`, `maxLifetime`, `connectionTimeout`,
  optional `sessionResetOnCheckout` to skip per-checkout session reset
  on trusted pools)
- Streaming chunk / block-fetch knobs on `ConnectionOptions`
  (`streamChunkSizeBytes`, `blockFetchBatchSize`) and optional
  `StatementOptions.initialBufferSize` for prepared seeds
- Transactions and savepoints (SQL-92 / SQL Server dialects); per-transaction
  `IsolationLevel`, `TransactionAccessMode.readOnly`, `LockTimeout`
- **X/Open XA / 2PC**: typed `Xid` + `XaTransactionHandle`
  state machine across PostgreSQL, MySQL/MariaDB, DB2, Oracle
  (`SYS.DBMS_XA`), and SQL Server (`--features xa-dtc` on Windows)
- Bulk insert payload builder and parallel bulk insert via pool
- Connection string validation, driver capabilities, and runtime version APIs
- **Live DBMS introspection** via `SQLGetInfo`: typed `DbmsInfo` with
  canonical engine id, identifier limits, current catalog
- **Driver-specific SQL builders**: UPSERT, RETURNING/OUTPUT, and
  per-engine session initialization through `OdbcDriverFeatures`
- **9 supported engines** with dedicated plugins: SQL Server, PostgreSQL,
  MySQL, MariaDB, Oracle, Sybase, SQLite, IBM Db2, Snowflake
- **Per-driver catalog dispatch**: `catalogTables`/`catalogColumns`
  etc. use dialect-specific catalogs for Oracle/Sybase/SQLite/Db2
- Audit API and metadata cache controls
- Async query/stream lifecycle controls (`executeAsyncStart/asyncPoll/...`)
- **Structured errors** with 12+ typed Dart classes: `ConnectionError`,
  `QueryError`, `ValidationError`, `UnsupportedFeatureError`,
  `EnvironmentNotInitializedError`, `NoMoreResultsError`,
  `MalformedPayloadError`, `RollbackFailedError`,
  `ResourceLimitReachedError`, `CancelledError`, `WorkerCrashedError`,
  `BulkPartialFailureError` (with structured fields)
- Runtime metrics and telemetry hooks (in-memory + OpenTelemetry OTLP)
- **Opt-in performance helpers**: `LazyString` (defer text decode
  until `.value` is read); native SQL pointer LRU for hot prepare paths

## Type Mapping

**Implemented input parameter types** (Dart → Database):
- `null`, `int` (32/64-bit auto), `String`, `List<int>` (binary)
- Canonical mappings:
  - `bool` → `Int(1|0)`
  - `double` → Decimal string with fixed scale (6)
    - `NaN` and `Infinity`/`-Infinity` throw `ArgumentError`
  - `DateTime` → UTC ISO8601 string
    - year must be in `[1, 9999]` (otherwise `ArgumentError`)

**Implemented result types** (Database → Dart) — wire `OdbcType` enum
(protocol discriminants) with **19 variants** matching the Rust wire
protocol 1:1. Access via `ColumnMetadata` / typed views on parsed results
(see [`doc/notes/TYPE_MAPPING.md`](doc/notes/TYPE_MAPPING.md)):

| Discriminant | Variant            | Dart return type             |
|--------------|--------------------|------------------------------|
| 1            | `varchar`          | `String` (UTF-8)             |
| 2            | `integer`          | `int` (4-byte LE i32)        |
| 3            | `bigInt`           | `int` (8-byte LE i64)        |
| 4            | `decimal`          | `String` (textual)           |
| 5            | `date`             | `String` (`YYYY-MM-DD`)      |
| 6            | `timestamp`        | `String`                     |
| 7            | `binary`           | `Uint8List` (raw bytes)      |
| 8            | `nVarchar`         | `String`                     |
| 9            | `timestampWithTz`  | `String` (ISO 8601 + offset) |
| 10           | `datetimeOffset`   | `String`                     |
| 11           | `time`             | `String`                     |
| 12           | `smallInt`         | `int` / `String` (ASCII preferred) |
| 13           | `boolean`          | `bool` (1-byte `0\|1` or ASCII)    |
| 14           | `float`            | `double` (8-byte LE or ASCII)      |
| 15           | `doublePrecision`  | `double` (8-byte LE or ASCII)      |
| 16           | `json`             | `String` (raw JSON text)     |
| 17           | `uuid`             | `String`                     |
| 18           | `money`            | `String`                     |
| 19           | `interval`         | `String`                     |

Use `ColumnMetadata` / the typed column view on parsed results to access
the discriminant. Unknown discriminants degrade to varchar for forward
compatibility.

**Planned (not yet implemented)**:
- Full `SqlDataType` × direction certification matrix beyond the current
  `ParamValue` / DRT1 surface (see
  [`doc/Features/PENDING_IMPLEMENTATIONS.md`](doc/Features/PENDING_IMPLEMENTATIONS.md))
- TVP / broadening of driver-specific output capability coverage, if product
  priorities change

See [`doc/notes/TYPE_MAPPING.md`](doc/notes/TYPE_MAPPING.md) for detailed
reference and [`doc/CAPABILITIES_v3.md`](doc/CAPABILITIES_v3.md) for the
full driver-capability matrix.

### Bulk insert validation behavior

For medium/large batches, prefer columnar
[`addColumnInt32`](lib/infrastructure/native/protocol/bulk_insert_builder.dart) /
[`addColumnText`](lib/infrastructure/native/protocol/bulk_insert_builder.dart)
(and related `addColumn*` helpers) when source data is already column-shaped —
they avoid per-row `List<dynamic>` allocation and bulk-copy typed lists into the
wire buffer. Use [`addRow`](lib/infrastructure/native/protocol/bulk_insert_builder.dart)
for small batches or incremental row construction. See
[doc/PERFORMANCE.md](doc/PERFORMANCE.md#bulk-insert-performance-dart).

`BulkInsertBuilder.addRow()` performs fail-fast validation:
- non-nullable columns reject `null` immediately (`StateError`)
- per-column type checks (`i32`, `i64`, `text`, `decimal`, `binary`, `timestamp`)
- text columns validate both character length and UTF-8 byte length against
  `maxLen` (`ArgumentError`)

Error messages include column name and row number to simplify debugging.

### Validation examples

```dart
// BulkInsertBuilder fail-fast: null in non-nullable column.
final builder = BulkInsertBuilder()
  ..table('users')
  ..addColumn('id', BulkColumnType.i32) // nullable: false by default
  ..addRow([null]); // throws StateError
```

```dart
// Text maxLen also validates UTF-8 byte length (emoji uses multiple bytes).
final builder = BulkInsertBuilder()
  ..table('users')
  ..addColumn('name', BulkColumnType.text, maxLen: 2)
  ..addRow(['😀']); // throws ArgumentError (UTF-8 bytes > maxLen)
```

```dart
// Canonical double mapping rejects NaN/Infinity (via FromObjects bridge).
await service.executeQueryParamValuesFromObjects(
  connId,
  'SELECT ? AS x',
  [double.nan], // throws ArgumentError before FFI
);
```

```dart
// DateTime year must be in [1, 9999].
final outOfRangeDate = DateTime.utc(9999, 12, 31).add(const Duration(days: 2));
await service.executeQueryParamValuesFromObjects(
  connId,
  'SELECT ? AS d',
  [outOfRangeDate], // throws ArgumentError
);
```

## API coverage (implemented)

### High-level service (`OdbcService` + sub-interfaces)

`IOdbcService` (aggregate) implements four narrower contracts:
[`IQueryService`](lib/application/services/i_query_service.dart),
[`ITransactionService`](lib/application/services/i_transaction_service.dart),
[`IPoolService`](lib/application/services/i_pool_service.dart),
[`IAdminService`](lib/application/services/i_admin_service.dart). New
consumers should depend on the narrowest sub-interface they need (ISP);
existing code typed against `IOdbcService` keeps working.

Each sub-interface also ships `...For(Connection conn, ...)` extension
overloads (`executeQueryFor`, `streamQueryFor`, `beginTransactionFor`,
`runInTransactionFor`, ...) so call sites no longer thread
`connection.id` around.

- Query execution: `executeQueryParamValues` (`List<ParamValue>` — preferred),
  `executeQueryParamValuesFromObjects` (bridge), `executeQuery`,
  `executeQueryNamed`, `executeQueryDirectedParams` (DRT1 `IN`/`OUT`/`INOUT`),
  `executeQueryColumnarParamValues` / `executeQueryColumnarFromObjects`
  (returns `TypedColumnarResult`)
- Prepared lifecycle: `prepare`, `prepareNamed`,
  `executePreparedParamValues` / `executePreparedParamValuesFromObjects`,
  `executePreparedNamed`, `cancelStatement` (experimental), `closeStatement`,
  `clearAllStatements`
- Incremental streaming: `streamQuery`, `streamQueryNamed`,
  `streamQueryColumnar`, `streamQueryMulti` (coalesced per-item multi-result
  stream), `streamQueryMultiBatches` (one item per fetch batch)
- Multi-result: `executeQueryMulti`, `executeQueryMultiFull`,
  `executeQueryMultiParamValues` / `executeQueryMultiParamValuesFromObjects`
- Metadata/catalog: `catalogTables`, `catalogColumns`, `catalogTypeInfo`,
  `catalogPrimaryKeys`, `catalogForeignKeys`, `catalogIndexes`
- Transactions: `beginTransaction`, `commitTransaction`,
  `rollbackTransaction`, `runInTransaction<T>` (begin → action →
  commit/rollback helper with throw-safe cleanup)
- Savepoints: `createSavepoint`, `rollbackToSavepoint`, `releaseSavepoint`
- X/Open XA / 2PC: `runInXaTransaction<T>`, `xaRecover` and
  `xaResumePrepared` are available on `IOdbcService`. The helper orchestrates
  start → action → end/prepare/commit or explicit single-RM `onePhase`.
  Direct `xaStart` is a repository/native capability; prepared recovery requires
  the transaction manager's durable XID and decision. See
  [`example/xa_2pc_demo.dart`](example/xa_2pc_demo.dart).
- Pooling: `poolCreate` (with `PoolOptions`), `poolGetConnection`,
  `poolReleaseConnection`, `poolHealthCheck`, `poolGetState`,
  `poolGetStateDetailed`, `poolSetSize`, `poolClose`
- Bulk insert: `bulkInsert`, `bulkInsertParallel` (pool-based, with
  fallback when `parallelism <= 1`)
- Lifecycle/admin: `initialize`, `connect`, `disconnect`,
  `validateConnectionString`, `getDriverCapabilities`,
  `getConnectionDbmsInfo` (live `SQLGetInfo`), `getMetrics`,
  `getVersion`, `setLogLevel`, `getWorkerPoolStats()` (infallible,
  returns `null` in sync mode)
- Event bus: `events` — broadcast `Stream<OdbcEvent>` with sealed
  variants (`ConnectionLost`, `WorkerRecovered`, `AutoReconnectAttempted`,
  `PoolResize`, `SlowQueryDetected`)
- Operations/maintenance: `detectDriver`, `clearStatementCache`,
  `getPreparedStatementsMetrics`
- Metadata cache: `metadataCacheEnable`, `metadataCacheStats`,
  `clearMetadataCache`
- Stream cancellation: `cancelStream`
- Audit: `setAuditEnabled`, `getAuditStatus`, `getAuditEvents`,
  `clearAuditEvents`
- Async request/stream lifecycle: `executeAsyncStart`, `asyncPoll`,
  `asyncGetResult`, `asyncCancel`, `asyncFree`, `streamStartAsync`,
  `streamPollAsync`

### Statement cancellation status

- `cancelStatement` is **experimental** (`@experimental` on `IOdbcService`).
- Current runtime contract often returns `UnsupportedFeatureError` /
  SQLSTATE `0A000` because native cancellation is not fully wired end-to-end.
- `asyncCancel` is best-effort for Rust async requests; it cannot guarantee an
  immediate interrupt when an ODBC driver is already blocked in a native call.
- `cancelStream` is effective between stream batches/iterations and is followed
  by stream close during async cleanup.
- Use driver-supported query timeouts (`ConnectionOptions.queryTimeout`,
  prepare/statement timeout options) to bound execution where supported.
  A worker/API timeout alone does not confirm driver cancellation or rollback.

### Parameterized execution

- **Typed parameters (preferred):** `executeQueryParamValues` /
  `executePreparedParamValues` with `List<ParamValue>` (sealed hierarchy in
  `lib/domain/entities/param_value.dart`). Use
  `executeQueryParamValuesFromObjects` / `…FromObjects` bridges on
  `IQueryService` / `IOdbcRepository` when you still have plain Dart values.
  Directed `OUT` / `INOUT` bindings use `executeQueryDirectedParams` with
  `List<DirectedParam>`.
- Legacy untyped `List<dynamic>` service/repository overloads were removed in
  **4.0.0** — see [CHANGELOG](CHANGELOG.md) migration table.
- Positional and prepared execution support a dynamic number of parameters,
  subject to the package protocol safety cap and the underlying driver/database.
- Named placeholders preserve occurrence order. Repeating `@id` or `:id` in the
  same SQL reuses the same map value for every matching position.

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

### Live DBMS introspection

- Preferred: `IOdbcService.getConnectionDbmsInfo(connectionId)` returns typed
  `DbmsInfo` (product name, canonical engine id, identifier limits, catalog).
  Demo: [`example/dbms_info_demo.dart`](example/dbms_info_demo.dart).
- Low-level: `OdbcDriverCapabilities.getDbmsInfoForConnection(connId)` via
  `odbc_fast_native.dart` when you already hold a native connection id.
- `DatabaseEngineIds` and `DatabaseType.fromEngineId(id)` for stable
  switch/case across releases.

### Driver-specific capability builders

[`OdbcDriverFeatures`](lib/infrastructure/native/driver_capabilities_v3.dart)
(native barrel) exposes three pure SQL builders that resolve the dialect from
the connection string:

- `buildUpsertSql(...)` — generates dialect UPSERT (`ON CONFLICT`,
  `ON DUPLICATE KEY UPDATE`, `MERGE`, depending on engine).
- `appendReturningClause(sql, verb, columns)` — appends `RETURNING` /
  `OUTPUT INSERTED.*` / `RETURNING ... INTO` / `FROM FINAL TABLE`.
- `getSessionInitSql(connStr, options)` — returns the post-connect setup
  statements per engine (`SET application_name`, `ALTER SESSION SET
  NLS_*`, `PRAGMA foreign_keys=ON`, ...).

### Pool eviction/timeout options

[`PoolOptions`](lib/domain/entities/pool_options.dart) +
[`OdbcPoolFactory`](lib/infrastructure/native/pool_options.dart)
(native barrel) expose `odbc_pool_create_with_options`:

```dart
final factory = OdbcPoolFactory(native);
final poolId = factory.createPool(
  'DSN=MyDsn',
  10,
  options: const PoolOptions(
    idleTimeout: Duration(minutes: 5),
    maxLifetime: Duration(hours: 1),
    connectionTimeout: Duration(seconds: 10),
    // Trusted pools only — skips checkout session reset (checkin still resets):
    // sessionResetOnCheckout: false,
  ),
);
```

Falls back to the legacy `poolCreate` (no options) when either:
- `options` is `null` or has no field set, OR
- the loaded native library does not expose the v3.0 entry point
  (use `factory.supportsApi` to check beforehand).

`poolSetSize(...)` preserves the resolved pool configuration when it
recreates the pool: `idleTimeout`, `maxLifetime`,
`connectionTimeout`, `sessionResetOnCheckout`, checkout validation, and any
configured health-check query stay intact after resize.

## Requirements

- Dart SDK `>=3.6.0 <4.0.0`
- ODBC Driver Manager
  - Windows: already available with ODBC stack
  - Linux: `unixodbc` / `unixodbc-dev`

## Installation

```yaml
dependencies:
  odbc_fast: ^5.0.0
```

Then:

```bash
dart pub get
```

Native binary resolution order is documented in [doc/BUILD.md](doc/BUILD.md).

### Package entrypoints

| Import | When to use |
| ------ | ----------- |
| `package:odbc_fast/odbc_fast.dart` | **Default** — domain types, `ServiceLocator`, `IOdbcService` / sub-interfaces, segregated `IQueryRepository` / `IPoolRepository` / etc., protocol helpers (`ParamValue`, `BulkInsertBuilder`, `ParsedRowBuffer`), and telemetry. Enough for most apps and examples. |
| `package:odbc_fast/odbc_fast_native.dart` | **Opt-in** — direct FFI surfaces: `NativeOdbcConnection`, `AsyncNativeOdbcConnection`, `OdbcRepositoryImpl`, `OdbcPoolFactory`, `AsyncError` types, and OpenTelemetry FFI. Use when you bypass `ServiceLocator`, construct the repository yourself, or need low-level native types documented in examples such as [`execute_async_demo.dart`](example/execute_async_demo.dart) and [`backpressure_modes_demo.dart`](example/backpressure_modes_demo.dart). |
| `package:odbc_fast/infrastructure/...` | **Internal / advanced** — only when a symbol is not re-exported by the barrels above (e.g. `BinaryProtocolParser` internals, `multi_result_parser.dart`). Prefer extending the public barrels over deep infrastructure imports in application code. |

`odbc_fast.dart` deliberately does **not** export `OdbcRepositoryImpl` or
`NativeOdbcConnection`; add `import 'package:odbc_fast/odbc_fast_native.dart';`
when your code needs those types.

## Quick Start (High-level service)

`ServiceLocator` is exported by `package:odbc_fast/odbc_fast.dart`.

By default, `initialize()` uses
**[`OdbcUsageProfile.legacy`](lib/domain/entities/odbc_usage_profile.dart)** to
preserve the historical sync-only behavior. Use
**`initialize(profile: OdbcUsageProfile.balanced)`** for the recommended async
preset: two worker isolates, bounded backpressure, and helpers
`recommendedConnectionOptions`, `recommendedPoolOptions`, and
`recommendedPoolMaxSize` for copy-paste-friendly timeouts and pool tuning.
Use `locator.resolvedUsageProfile` when you want the effective config after
explicit async overrides.

```dart
import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

void reportFailure(Object error) {
  exitCode = 1;
  if (error is OdbcError) {
    stderr.writeln('${error.code.name}: ${error.userMessage}');
  } else {
    stderr.writeln('The database operation could not be completed.');
  }
}

Future<void> main() async {
  AppLogger.initialize();
  final locator = ServiceLocator();
  try {
    locator.initialize(profile: OdbcUsageProfile.balanced);
    final service = locator.service;
    (await service.initialize()).getOrThrow();
    final connection = (await service.connect(
      'DSN=MyDsn',
      options: locator.recommendedConnectionOptions,
    )).getOrThrow();
    try {
      final result = (await locator.queryService.executeQueryParamValues(
        connection.id,
        'SELECT CAST(? AS INTEGER) AS id',
        const [ParamValueInt32(1)],
      )).getOrThrow();
      final id = result.reader().scalar<int>('id', ignoreCase: true);
      stdout.writeln('rows=${result.rowCount} id=$id');
    } finally {
      final disconnected = await service.disconnect(connection.id);
      disconnected.fold((_) {}, reportFailure);
    }
  } on Object catch (error, stackTrace) {
    reportFailure(error);
    AppLogger.severe('Database operation failed', error, stackTrace);
  } finally {
    locator.shutdown();
  }
}
```

The CLI boundary catches `getOrThrow()` failures, prints the presentation
message and keeps technical diagnostics in the logger. Disconnect is checked
separately, and shutdown runs after initialization or query failures.
Adapt the sample SELECT for your driver's dialect; connection settings stay
outside SQL parameter values. Runnable version:
[quick_start_balanced_demo.dart](example/quick_start_balanced_demo.dart).

## Performance quick reference

| Scenario | Prefer |
| -------- | ------ |
| Large row/text scan | Service `streamQuery`, one batch at a time; start with `fetchSize: 1000` and the profile chunk recommendation |
| Numeric analytics | Explicit `streamQueryColumnar` / `executeQueryColumnarParamValues`; resolve typed columns once per batch |
| Repeated same SQL | Prepare once, execute many |
| Large multi-result cursor | `streamQueryMultiBatches`; handle each fetch batch and use `isContinuationBatch` to group it when needed |
| Repeated individual writes | Prepare once and bind new values |
| Batch writes | `bulkInsert` / `bulkInsertArray`, generate bounded payloads |
| Independent parallel batches | `bulkInsertParallel` with a native pool; measure against single-connection bulk on the same driver and workload |
| Repeated named-column reads | One `result.reader()` per result or batch |
| Concurrency / worker tuning | [`OdbcUsageProfile`](lib/domain/entities/odbc_usage_profile.dart) via `ServiceLocator.initialize(profile: ...)` |

Rationale, how to reproduce, and opt-in perf flags:
[doc/PERFORMANCE.md](doc/PERFORMANCE.md). Native snapshots:
[native/doc/performance_comparison.md](native/doc/performance_comparison.md).

### Historical benchmark snapshots

These recorded measurements are not a fresh run of this checkout.
Order-of-magnitude snapshots on a local SQL Server DSN (driver, schema, and
hardware dominate). **Not** a portable contract or CI gate. Reproduce with
`python scripts/run_dart_benchmarks.py --crud --heavy` and
`cargo bench --features test-helpers --bench comparative_bench`.

Native engine (`comparative_bench`):

| Workload | Typical |
| -------- | ------- |
| Single-row `INSERT` (INT) | ~260–300 µs (~3.4–3.7k rows/s) |
| Bulk array 1k / 5k / 10k | ~75–100 / ~370–430 / ~730–830 ms |
| Bulk parallel ×4 (same sizes) | ~25–30 / ~120–140 / ~230–280 ms (~3× vs array) |
| `SELECT` 5k INT, streaming | ~1.1–1.4 ms |

Dart (same DSN):

| Workload | Typical |
| -------- | ------- |
| `INSERT` 5k columnar + pool ×4 | ~20–45k ops/s |
| `SELECT` 5k narrow table, `streamQueryBatched` | ~300–650k rows/s |
| `SELECT TOP 5000 * FROM Produto`, `streamQueryBatched` | ~19–20k rows/s |
| `SELECT 1` prepared reuse (smoke) | ~3.5–3.9k q/s |

Wide text scans and narrow numeric scans have different costs; the
300–650k rows/s sample uses a two-column bench table. Optional native BCP
(`sqlserver-bcp` + `sqlncli11.dll`) is a separate path measured in the
native comparison document. Async p95 on the
heavy `Produto` lane is noisy across runs; prefer throughput and
`fallbacksToBlocking` over a single p95 sample.

For a large multi-result cursor, use `streamQueryMultiBatches` when rows can
be processed per fetch. It keeps decoded memory bounded by `fetchSize` and
marks follow-up batches for the same result set with `isContinuationBatch`.
Use `streamQueryMulti` when its convenient coalesced result-set semantics are
more valuable than retaining prior continuation rows. Let the usage profile
choose `chunkSize` unless measurement shows a need to override it; server
profiles start at 1 MiB while the base default remains 64 KiB.

For a database-free comparison of buffer/framing/reader processing, run:

```bash
dart run benchmarks/dart_hot_paths.dart
```

Use warmup and repeated samples on the same SDK, without concurrent suites.
The [measured comparison in doc/TESTING.md](doc/TESTING.md) covers Dart frame
assembly against `522dc45`; it does not establish end-to-end SQL throughput.
Batch memory depends on row width, fetch size and retained views.

## Async API (non-blocking)

Async mode is opt-in through an async profile or `useAsync: true`. When async is
enabled, `locator.service` and `locator.asyncService` both refer to the
high-level async service.

For **Flutter**-heavy apps that mostly hold a single connection, you can start
with a lighter worker footprint:

```dart
final locator = ServiceLocator()
  ..initialize(profile: OdbcUsageProfile.balancedFlutter);
final service = locator.service;
```

For **HTTP services** with a native pool and concurrent checkouts:

```dart
final locator = ServiceLocator()
  ..initialize(profile: OdbcUsageProfile.balancedServer);
```

For **heavier server workloads** that want a larger worker pool and a higher
recommended native pool size:

```dart
final locator = ServiceLocator()
  ..initialize(profile: OdbcUsageProfile.highThroughput);
```

To opt out of async entirely (CLI scripts, tests, or minimal overhead):

```dart
final locator = ServiceLocator()
  ..initialize(profile: OdbcUsageProfile.legacy);
final service = locator.syncService;
```

Explicit overrides still work:

```dart
final locator = ServiceLocator()
  ..initialize(
    profile: OdbcUsageProfile.balancedFlutter,
    asyncWorkerCount: 4,
    asyncMaxPendingRequests: 16,
  );
final service = locator.service;
// Use the initialization, Result handling and finally cleanup from Quick Start.
```

For high-concurrency workloads, async mode accepts an optional worker pool:

```dart
final locator = ServiceLocator()
  ..initialize(
    useAsync: true,
    asyncWorkerCount: 4,
    asyncMaxPendingRequests: 16,
  );
```

Profile recommendations (native pools must be created explicitly):

| Profile | Async | Workers | Request cap | Pool size hint | Stream chunk |
| --- | --- | --- | --- | --- | --- |
| `legacy` | No | 1 if async enabled | Unlimited | 4 | 64 KiB |
| `balanced` | Yes | 2 | 24 | 4 | 64 KiB |
| `balancedFlutter` | Yes | 1 | 16 | 4 | 64 KiB |
| `balancedServer` | Yes | 4 | 32 | 8 | 1 MiB |
| `highThroughput` | Yes | 6 | 48 | 12 | 1 MiB |

`asyncWorkerCount` defaults from the active **[`OdbcUsageProfile`](lib/domain/entities/odbc_usage_profile.dart)**
(`2` for balanced, `1` for balancedFlutter, `4` for balancedServer, `6` for highThroughput, `1` for legacy).
Values greater than
`1` let independent connections or pool checkouts run on multiple Dart worker
isolates. Operations on the same connection, statement, transaction, stream, or
async request keep worker affinity so handle usage stays serialized.
`asyncMaxPendingRequests` defaults to the selected profile's cap; legacy has no
cap. A positive override changes that cap. Direct
`AsyncNativeOdbcConnection(maxPendingRequests: null)` has no limit.
Use a small multiple of pool size as a starting point, and bound application
in-flight tasks separately so waiting Futures do not grow with the workload.
This is the supported "thread opening" pattern for Dart consumers: configure
workers with `workerCount` / `asyncWorkerCount` and open multiple real
connections or pool checkouts. Do not spawn raw isolates around the same
connection expecting parallel SQL execution; the native connection mutex still
serializes one connection for ODBC safety.

If you use `AsyncNativeOdbcConnection` directly, you can also configure:

- `requestTimeout` for worker response and handshake deadlines: `null` keeps
  the 30-second default; only `Duration.zero` disables the deadline
- `autoRecoverOnWorkerCrash` for automatic worker re-initialization
- `workerCount` for an optional worker isolate pool (`1` if you construct
  `AsyncNativeOdbcConnection` with defaults; use `ServiceLocator.initialize` with
  an `OdbcUsageProfile` for preset worker counts)
- `maxPendingRequests` for a global outstanding-request cap (`null` means no
  limit, as with the legacy
  profile; bounded with balanced and `highThroughput` presets)
- `backpressureMode` as `failFast` (legacy profile) or `waitForSlot` (balanced
  and `highThroughput` presets)
- `backpressureTimeout` when `waitForSlot` is active
- `getWorkerPoolStats()` for a Dart-side snapshot of routed, active, pending,
  timeout, cancel, latency, per-worker, and blocking-fallback counters
- `onDiagnostic(OdbcError)` for late completion and cleanup diagnostics;
  absent or failing callbacks fall back to `AppLogger`

Concurrent `initialize()` calls share one attempt. Workers become available
only after the whole attempt succeeds. `dispose()` immediately invalidates that
generation, including workers still starting; a later explicit `initialize()`
starts a new generation. Responses from older generations cannot restore handles.

A request timeout ends the caller's wait once. Work may continue in the driver,
so an outstanding request still counts toward `maxPendingRequests` until its
late response and cleanup are reconciled. Maintenance runs on the original
worker, independently of ordinary capacity. Late connection, pool, checkout,
statement, stream, async execution and transaction allocations are released
when their native results permit it. Failed cleanup leaves the identified
resource quarantined and emits a diagnostic; the earlier failure remains unchanged.
Prepared XA branches resumed after timeout are retained for explicit adoption
by another `xaResumePrepared` with the same connection and XID. Pending adoption
does not create a second handle or roll back a prepared branch. A blocked FFI
call or dead worker prevents Dart from guaranteeing cancellation or native cleanup.

For the low-level native polling API, import `odbc_fast_native.dart` and use
the checked initialization/disconnect/dispose lifecycle in
[execute_async_demo.dart](example/execute_async_demo.dart). Native APIs retain
sentinel/exception contracts; application services provide `Result` values.

High-concurrency examples:

- [`example/high_concurrency_pool_demo.dart`](example/high_concurrency_pool_demo.dart)
  uses `ServiceLocator.initialize(profile: OdbcUsageProfile.highThroughput)`
  with a native pool, separate checkouts, an explicit in-flight task limit, and
  accepts `ODBC_CONCURRENCY_QUERY`.
- [`example/async_concurrency_benchmark.dart`](example/async_concurrency_benchmark.dart)
  compares `workerCount: 1`, `workerCount: 4`, native pool with an in-flight
  limit, streaming, row-major vs columnar encodings, and prepared reuse.

Async streaming (`streamQuery` / `streamQueryBatched`) uses the native
stream protocol through the worker isolate (`stream_start/fetch/close`),
instead of fetching full result sets in a single call.

Tuning starting points (measure on your driver/workload):

- API/web with native pool: set `workerCount` near `min(poolSize, cores)` and
  `maxPendingRequests` near `poolSize * 2` to `poolSize * 4`.
- Batch jobs: set `workerCount = poolSize`; prefer streaming for large result
  sets.
- Flutter/UI: keep `workerCount = 1` unless the app opens multiple real
  connections concurrently.
- Same connection: keep calls logically serial. More workers reduce contention
  only when there are multiple connections, native pool checkouts, or
  independent non-handle operations to route.

For large scans, start with `fetchSize: 1000` and
`chunkSize: locator.recommendedStreamChunkSizeBytes`. An omitted chunk size
resolves from connection options, then falls back to 64 KiB; server profile
connection options recommend 1 MiB. Pass recommended options on connect or pool
creation/acquisition, or pass chunk size explicitly. Use columnar APIs for
numeric column processing and project only the columns needed.

```dart
var totalRows = 0;
await for (final result in service.streamQuery(
  connection.id,
  'SELECT id, name FROM big_table',
  chunkSize: locator.recommendedStreamChunkSizeBytes,
)) {
  final batch = result.getOrThrow(); // Inside the Quick Start error boundary.
  // Process and await the consumer here; do not retain previous batches.
  totalRows += batch.rowCount;
}
stdout.writeln('rows=$totalRows');
```

## Errors, transactions and recovery

Service and repository `Result` APIs return typed `OdbcError` failures, including
unexpected exceptions from injected implementations. Streams emit one terminal
`Failure` and then close. Use `error.code` for localization and `error.userMessage`
for presentation; retain `message`, SQLSTATE and native code for diagnostics.
`error.details` preserves the operation, cause, stack trace, worker/request IDs,
uncertain execution (`outcomeUnknown`) and secondary cleanup failures. Presentation
messages do not contain driver text, SQL, parameters or connection strings.

Instrumentation failures do not change database results. Configure
`SimpleTelemetryService(onDiagnostic: ...)` to receive these diagnostics;
without a callback they go to `AppLogger`. A failing diagnostic callback also
falls back to logging.

Local commit/rollback marks the transaction as completing before awaiting the
worker. Status `0` confirms success; `1` consumes the handle but does not confirm
the database outcome; `2` keeps the transaction active. Missing or invalid status
keeps ownership and marks the outcome unknown, unless the adapter proves that
the native call never started. While completion is in progress or uncertain,
queries, savepoints, another completion, reconnection, replay and pool return
are blocked. Diagnostics and explicit connection shutdown remain available.
Late completion can reconcile this state; it does not repeat commit or rollback.

`XaTransactionHandle.outcomeUnknown` exposes uncertain XA phases, and `lastError`
retains phase, XID, cause and stack trace. Helpers respect phases completed inside
the application callback and never automatically undo an uncertain confirmation.
The read-only `commitAttempted` flag also prevents orchestration from repeating
a commit decision rejected before the native call; explicit rollback remains
possible when non-execution is proven.
Prepared branch recovery requires an explicit application decision.

`Xid.fromStrings` encodes `gtrid` and `bqual` as UTF-8, enforcing the existing
64-byte limits after encoding. Invalid UTF-16 surrogates throw `ArgumentError`;
no Unicode normalization is performed. ASCII identifiers are unchanged. To recover
a non-ASCII XID created by an older version, use `Xid` with the original bytes;
recreating it with `fromStrings` may identify a different branch.

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

Automatic reconnection restores the connection for future operations. It does
**not** replay the failed query by default. Set
`replayQueriesAfterReconnect: true` together with `autoReconnectOnConnectionLost`
only when the application explicitly authorizes another execution. The package
does not infer replay safety from SQL text. Reconnection and replay are blocked
inside local and XA transactions. A timeout of buffered work may leave execution
running in the driver; check `error.details.outcomeUnknown` before deciding what
to do next.

Validation rules:

- timeouts/backoff must be non-negative
- `maxResultBufferBytes`, `initialResultBufferBytes`, `streamChunkSizeBytes`
  and `sqlPointerCacheMaxSize` must be `> 0` when supplied
- `initialResultBufferBytes` cannot be greater than `maxResultBufferBytes`

## Result access and buffer ownership

For repeated named-column reads, create
`final reader = queryResult.reader()` once on a successful `QueryResult`.
Its column names are a snapshot; rows remain live, as in the existing helpers.
Duplicate names resolve to the first occurrence for cell lookup. Readers preserve
nulls and runtime types; they do not coerce numeric or lazy string values.
Avoid `rowsAsMaps` or copying `columnValues` when an aggregate is enough. Use
`streamQueryMultiBatches` or `streamQueryColumnar` for large results;
`streamQueryMulti` deliberately coalesces each complete result set.

Protocol frames and lazy string slices remain zero-copy views with stable backing
memory, including derived `Uint8List` and `ByteData` views. Exposed backing is
never automatically returned to a pool. Internal, unexposed abandoned buffers
can still be reused. Explicit `offerPooledBacking`/`offerDefaultBacking` calls
transfer exclusive ownership: neither the buffer nor any live view may remain
in use afterward. Fragmented frame headers use bounded copies and cached lengths;
adding data copies only pending bytes when detachment or growth is necessary.

## Connection String Builder

Seven fluent builders are available:

| Database | Builder |
| --- | --- |
| SQL Server | `SqlServerBuilder` |
| PostgreSQL | `PostgreSqlBuilder` |
| MySQL | `MySqlBuilder` |
| MariaDB | `MariaDbBuilder` |
| SQLite | `SqliteBuilder` |
| IBM Db2 | `Db2Builder` |
| Snowflake | `SnowflakeBuilder` |

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

See [example/README.md](example/README.md) for the current catalogue, environment
settings and supported dialects.

| Workload | Example |
| --- | --- |
| Small query with typed parameters | [quick start](example/quick_start_balanced_demo.dart) |
| API selection for throughput | [performance patterns](example/recommended_performance_patterns_demo.dart) |
| Repeated SQL, prepare once | [prepared reuse](example/named_parameters_demo.dart) |
| Large row scans, one batch at a time | [batched streaming](example/streaming_demo.dart) |
| Large numeric scans, typed arrays | [columnar streaming](example/stream_query_columnar_demo.dart) |
| Large multi-result cursors | [uncoalesced batches](example/multi_result_batches_demo.dart) |
| Repeated column-name access | [indexed reader](example/query_result_access_demo.dart) |
| Bounded bulk payloads | [bulk insert](example/bulk_insert_demo.dart) |
| Independent parallel bulk | [parallel bulk](example/bulk_insert_parallel_demo.dart) |
| Bounded pooled requests | [pool concurrency](example/high_concurrency_pool_demo.dart) |
| Local transactions / savepoints | [transaction scope](example/run_in_transaction_demo.dart), [savepoints](example/savepoint_demo.dart) |
| XA and recovery listing | [XA](example/xa_2pc_demo.dart) |

```bash
dart run example/recommended_performance_patterns_demo.dart
dart run example/streaming_demo.dart
dart run example/stream_query_columnar_demo.dart
dart run example/high_concurrency_pool_demo.dart
```

Large-read examples process batches without collecting all rows or logging each
row. Server profiles supply the recommended chunk size; columnar results require
the explicit columnar APIs. Parallel bulk has no universal row threshold and is
not one atomic transaction. Benchmark your driver/schema before selecting
batch size or concurrency.

The examples also cover named/directional parameters, Oracle REF CURSOR,
catalogs, typed errors, telemetry, events and native asset resolution.
[common.dart](example/common.dart) centralizes the main examples' lifecycle and
clear errors. A timeout does not confirm cancellation; no example should
automatically replay SQL or reverse an uncertain transactional decision.

For measured comparisons, use [the concurrency benchmark](example/async_concurrency_benchmark.dart),
[streaming benchmark](example/streaming_performance_benchmark.dart) and
[multi-result benchmark](example/multi_result_performance_benchmark.dart).
The tiny demo queries and single stopwatch readings illustrate usage; they do
not establish performance gains. See [doc/PERFORMANCE.md](doc/PERFORMANCE.md).

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

For more script options, see [scripts/README.md](scripts/README.md).

The experimental Cargo feature `columnar-v2` gates sketch constants and the
`columnar_v2_placeholder` bench only; production columnar encoding and
`odbc_columnar_decompress` stay on the default build. See
[`doc/notes/columnar_protocol_sketch.md`](doc/notes/columnar_protocol_sketch.md).

## Testing

Copy [`.env.example`](.env.example) to `.env` and set `ODBC_TEST_DSN` before
any live-driver scope. Canonical opt-in flags are listed in
[doc/TESTING.md](doc/TESTING.md).

**Coverage note:** Codecov gates (`.codecov.yml`) measure Dart coverage under
`lib/` only — `native/**` is intentionally ignored because Rust coverage is
tracked separately via `cargo tarpaulin` (see [doc/TESTING.md](doc/TESTING.md)).
The combined badge therefore understates native engine coverage; treat it as a
Dart-layer gate, not whole-repo coverage.

```bash
# Dart — CI unit scope (disable live flags and DSNs as in doc/TESTING.md)
dart test test/application test/domain test/infrastructure test/helpers/database_detection_test.dart

# Dart — core / public barrel contracts
dart test test/core test/public_api_exports_test.dart

# Dart — DSN-free documentation and example scope
dart test test/documentation test/example

# Dart — performance guard; forced GC runs separately from unit budget
dart test test/performance/protocol_performance_test.dart
dart test test/integration/protocol_frame_ownership_gc_test.dart

# Dart — FFI export synchronization
dart tool/check_ffi_exports.dart

# Dart — full suite (integration/e2e/stress self-skip without env)
dart test

# Dart — integration (live cases require ODBC_TEST_DSN; includes DSN-free cases)
dart test test/integration/

# Dart — live DB tests gated by RUN_LIVE_TESTS=1 (see .env.example)
# Dart — slow/stress: RUN_SKIPPED_TESTS=1

# Dart — validation / stress / benchmarks
dart test test/validation/
dart test test/stress/
dart run benchmarks/m1_baseline.dart
dart run benchmarks/m2_performance.dart
# or: python scripts/run_dart_benchmarks.py --smoke --harness

# Rust — from native/ (lib unit tests; integration #[ignore] without env)
cd native
cargo test --workspace -- --test-threads=1
cd ..

# Rust E2E — ENABLE_E2E_TESTS=1 + ODBC_TEST_DSN in .env (25 e2e_* suites)
powershell scripts/run_e2e_tests.ps1           # full incl. slow stress
powershell scripts/run_e2e_tests.ps1 -Quick    # live E2E only
./scripts/run_e2e_tests.sh                     # Linux/macOS equivalent

# Rust bulk insert benchmark (array vs parallel)
cd native/odbc_engine
cargo test --test e2e_bulk_compare_benchmark_test -- --ignored --nocapture
```

| Variable | Scope | Purpose |
| -------- | ----- | ------- |
| `ENABLE_E2E_TESTS` | Rust | `1` — run live `e2e_*` integration tests |
| `RUN_LIVE_TESTS` | Dart | `1` — run DSN-dependent live tests outside integration |
| `RUN_SKIPPED_TESTS` | Dart | `1` — include slow/stress Dart tests |
| `ENABLE_SLOW_E2E_TESTS` | Rust | `1` — long-running `#[ignore]` E2E stress paths (`run_e2e_tests` maps `RUN_SKIPPED_TESTS` when unset) |

Optional Rust bulk benchmark tuning: `BULK_BENCH_SMALL_ROWS` and
`BULK_BENCH_MEDIUM_ROWS`.

## Project structure

```text
dart_odbc_fast/
├── lib/
│   ├── application/         # IOdbcService, capability delegates, telemetry decorators
│   ├── domain/              # entities (ParamValue, PoolOptions), repositories, OdbcError
│   ├── infrastructure/      # FFI, protocol, repository runners, NativeOdbcConnection
│   ├── core/                # ServiceLocator, logging
│   ├── odbc_fast.dart      # primary public barrel
│   └── odbc_fast_native.dart  # opt-in FFI / repository barrel
├── native/
│   └── odbc_engine/         # Rust FFI engine (plugins, protocol, streaming, transaction)
├── hook/                    # Native assets hooks
├── scripts/                 # build, E2E runners, validation
├── example/                 # runnable demos (see example/README.md)
├── test/                    # Dart suites (unit, integration, e2e, stress)
└── doc/                     # Index: doc/README.md
```

Layering and service wiring: [doc/ARCHITECTURE.md](doc/ARCHITECTURE.md).
Native engine layout: [native/odbc_engine/ARCHITECTURE.md](native/odbc_engine/ARCHITECTURE.md).

## Documentation

### Reference (current)

- [doc/README.md](doc/README.md) — documentation index (start here)
- [doc/ARCHITECTURE.md](doc/ARCHITECTURE.md) — Dart layers, dual barrels, ServiceLocator, sealed `OdbcBackend`, sub-interfaces, runners, event bus
- [doc/API_SURFACE.md](doc/API_SURFACE.md) — FFI surface, public Rust API and Dart bindings; validate current exports with `dart tool/check_ffi_exports.dart`
- [doc/CAPABILITIES_v3.md](doc/CAPABILITIES_v3.md) — driver capability traits × engine matrix
- [doc/BUILD.md](doc/BUILD.md) — build, library resolution, scripts
- [doc/TESTING.md](doc/TESTING.md) — test policy, CI scope, environment variables
- [doc/PERFORMANCE.md](doc/PERFORMANCE.md) — architectural performance notes and bench guide
- [native/doc/performance_comparison.md](native/doc/performance_comparison.md) — native benchmark snapshots vs SQL Server
- [doc/notes/TYPE_MAPPING.md](doc/notes/TYPE_MAPPING.md) — canonical Dart/native type mapping contract
- [doc/Features/PENDING_IMPLEMENTATIONS.md](doc/Features/PENDING_IMPLEMENTATIONS.md) — open work and non-goals

### Development

- [doc/development/docker-test-stack.md](doc/development/docker-test-stack.md) — Docker E2E test stack
- [doc/development/msdtc-recovery.md](doc/development/msdtc-recovery.md) — MSDTC / XA recovery scope

### Release and versioning

- [doc/version/RELEASE_AUTOMATION.md](doc/version/RELEASE_AUTOMATION.md)
- [doc/version/VERSIONING_STRATEGY.md](doc/version/VERSIONING_STRATEGY.md)
- [doc/version/VERSIONING_QUICK_REFERENCE.md](doc/version/VERSIONING_QUICK_REFERENCE.md)
- [doc/version/CHANGELOG_TEMPLATE.md](doc/version/CHANGELOG_TEMPLATE.md)

### Notes and implementation detail

- [doc/notes/columnar_protocol_sketch.md](doc/notes/columnar_protocol_sketch.md) — columnar v2 wire layout
- [doc/notes/REF_CURSOR_ORACLE_ROADMAP.md](doc/notes/REF_CURSOR_ORACLE_ROADMAP.md) — Oracle ref cursor contract
- [doc/notes/TVP_DESIGN_GATE.md](doc/notes/TVP_DESIGN_GATE.md) - decisions required before TVP work starts
- [doc/notes/ROADMAP_PENDENTES.md](doc/notes/ROADMAP_PENDENTES.md) — short open-item index → PENDING

## CI/CD

- CI workflow: `.github/workflows/ci.yml`
  - runs `cargo fmt`, `cargo clippy`, Rust build, `dart analyze`, FFI export checks and the canonical Dart unit scope
  - also runs documentation/example contracts, the protocol performance guard,
    a separate DSN-free forced-GC regression and the slow-test budget
  - live integration/E2E/stress scopes are opt-in; the separate GC regression
    is the explicit DSN-free integration case in default CI
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

Release preparation and publication commands are maintained in
[RELEASE_AUTOMATION.md](doc/version/RELEASE_AUTOMATION.md).
Update release metadata and the changelog before creating a matching version tag.

The release workflow validates metadata, builds Windows/Linux assets and
creates a GitHub Release. The publish workflow validates stable `vX.Y.Z`
tags, waits for release binaries and SHA-256 sidecars, then publishes through
OIDC. Prerelease tags are excluded from that automatic pub.dev path.

### Security

This project uses **OIDC (OpenID Connect)** for pub.dev authentication:

- No long-lived secrets required
- Temporary tokens are automatically managed by GitHub Actions
- See [Automated publishing documentation](https://dart.dev/tools/pub/automated-publishing) for details

## License

MIT (see [LICENSE](LICENSE)).
