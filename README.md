# ODBC Fast - Rust-native ODBC for Dart

[![CI](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/ci.yml/badge.svg)](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/ci.yml)
[![E2E Multi-DB](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/e2e_multidb.yml/badge.svg)](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/e2e_multidb.yml)
[![codecov](https://codecov.io/gh/cesar-carlos/dart_odbc_fast/branch/main/graph/badge.svg)](https://codecov.io/gh/cesar-carlos/dart_odbc_fast)

`odbc_fast` is an ODBC data access package for Dart backed by an in-repo Rust engine over `dart:ffi`.

## What's New in 4.3.x

Current package version: **4.3.4**. The 4.3 line keeps the public Dart
surface additive while the Rust FFI layer continues to harden concurrency
and encoding hot paths. Full history: [CHANGELOG.md](CHANGELOG.md).
Open work: [`doc/Features/PENDING_IMPLEMENTATIONS.md`](doc/Features/PENDING_IMPLEMENTATIONS.md).

### Highlights

- **Dual public barrels** — `package:odbc_fast/odbc_fast.dart` for apps
  (`ServiceLocator`, `IOdbcService` / sub-interfaces, domain types);
  `package:odbc_fast/odbc_fast_native.dart` for FFI demos and
  `OdbcRepositoryImpl` / pool factory wiring. See
  [Package entrypoints](#package-entrypoints) and
  [`doc/ARCHITECTURE.md`](doc/ARCHITECTURE.md).
- **Segregated repositories + telemetry ISP** —
  `ServiceLocator.queryRepository` / `poolRepository` / … and
  `TelemetryOdbcDecorators.query|pool|transaction|admin` for narrow seams.
- **Transaction helpers** — `runInTransaction<T>` and
  `runInXaTransaction<T>` on `IOdbcService` (throw-safe commit/rollback or
  XA 2PC / one-phase). Prefer these over manual `txnId` / XA chaining.
  Demos: [`run_in_transaction_demo.dart`](example/run_in_transaction_demo.dart),
  [`xa_2pc_demo.dart`](example/xa_2pc_demo.dart).
- **Sub-interfaces & event bus** — `IQueryService` / `ITransactionService` /
  `IPoolService` / `IAdminService` with `…For(Connection)` overloads;
  `IAdminService.events` (`OdbcEvent`, including live `SlowQueryDetected`
  when `ConnectionOptions.slowQueryThreshold` is set).
- **Columnar & multi-result** — `executeQueryColumnarParamValues` /
  `streamQueryColumnar`, `ResultEncoding.columnar` /
  `columnarCompressed`, `executeQueryMultiFull` /
  `executeQueryMultiParamValues`, `streamQueryMulti`. Row-major remains
  the default encoding.
- **Directed params & Oracle REF CURSOR** — DRT1 /
  `executeQueryDirectedParams`, `QueryResult.outputParamValues` /
  `additionalResults` / `refCursorResults`. Contracts in
  [`doc/notes/TYPE_MAPPING.md`](doc/notes/TYPE_MAPPING.md).
- **Usage profiles** — `OdbcUsageProfile.balanced` /
  `balancedServer` / `highThroughput` via `ServiceLocator` with
  `recommendedConnectionOptions` / `recommendedResultEncoding`.
  Demo: [`quick_start_balanced_demo.dart`](example/quick_start_balanced_demo.dart).
- **FFI performance (native)** — default `block-cursor-fetch` and
  `statement-handle-reuse`; sharded `ffi::state::*` maps; residual
  `GlobalState` is `env` (+ optional BCP strings). Details:
  [`doc/PERFORMANCE.md`](doc/PERFORMANCE.md).

### XA / 2PC engines

| Engine | Status |
| ------ | ------ |
| PostgreSQL | ✅ `PREPARE TRANSACTION` + `pg_prepared_xacts` |
| MySQL / MariaDB | ✅ `XA START / END / PREPARE / COMMIT / RECOVER` |
| DB2 | ✅ same SQL grammar as MySQL |
| Oracle | ✅ `SYS.DBMS_XA` + `DBA_PENDING_TRANSACTIONS` |
| SQL Server (MSDTC) | ✅ Windows + `--features xa-dtc` (advanced Reenlist still open — PENDING §2.1) |
| SQLite / Snowflake | ❌ `UnsupportedFeature` |

XA lifecycle helpers are on the sync/native service path today
(`ServiceLocator.syncService` / `runInXaTransaction`). See
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
  `executeQueryMultiParamValues`, streaming `streamQueryMulti`)
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
  `Int32List` / `Int64List` / `Float64List` per numeric column (zero boxing)
- **`QueryResultAccess`**: typed row/column navigation on
  `QueryResult` without changing row storage (`cell`, `scalar`, `rowsAsMaps`, …)
- **Repository extensions**: columnar execute/stream,
  `…For(Connection)` overloads, `…FromObjects` typed-parameter bridges, and
  `runInTransaction` — same ergonomics as the service sub-interfaces
- **Transaction helpers**: `runInTransaction<T>` and
  `runInXaTransaction<T>` orchestrate begin → action → commit/rollback
  (or end → prepare → commit_prepared for XA) with throw-safe cleanup
- Connection pooling with **configurable eviction/timeouts**
  (`PoolOptions`: `idleTimeout`, `maxLifetime`, `connectionTimeout`)
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
| 12           | `smallInt`         | `String` (textual)           |
| 13           | `boolean`          | `String` (`0`/`1`)           |
| 14           | `float`            | `String` (textual)           |
| 15           | `doublePrecision`  | `String`                     |
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
  `streamQueryColumnar`, `streamQueryMulti` (per-item multi-result stream)
- Multi-result: `executeQueryMulti`, `executeQueryMultiFull`,
  `executeQueryMultiParamValues` / `executeQueryMultiParamValuesFromObjects`
- Metadata/catalog: `catalogTables`, `catalogColumns`, `catalogTypeInfo`,
  `catalogPrimaryKeys`, `catalogForeignKeys`, `catalogIndexes`
- Transactions: `beginTransaction`, `commitTransaction`,
  `rollbackTransaction`, `runInTransaction<T>` (begin → action →
  commit/rollback helper with throw-safe cleanup)
- Savepoints: `createSavepoint`, `rollbackToSavepoint`, `releaseSavepoint`
- X/Open XA / 2PC: `runInXaTransaction<T>` on the aggregate service
  (orchestrates start → action → end/prepare/commit or 1RM `onePhase`).
  Low-level `xaStart` / `xaRecover` / `xaResumePrepared` live on the
  repository / native `XaTransactionHandle` path — see
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
- Prefer query timeout (`ConnectionOptions.queryTimeout`, prepare/statement
  timeout options) for reliable interruption.

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
  ),
);
```

Falls back to the legacy `poolCreate` (no options) when either:
- `options` is `null` or has no field set, OR
- the loaded native library does not expose the v3.0 entry point
  (use `factory.supportsApi` to check beforehand).

`poolSetSize(...)` preserves the resolved pool configuration when it
recreates the pool: `idleTimeout`, `maxLifetime`,
`connectionTimeout`, checkout validation, and any configured
health-check query stay intact after resize.

## Requirements

- Dart SDK `>=3.6.0 <4.0.0`
- ODBC Driver Manager
  - Windows: already available with ODBC stack
  - Linux: `unixodbc` / `unixodbc-dev`

## Installation

```yaml
dependencies:
  odbc_fast: ^4.3.4
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
| `package:odbc_fast/odbc_fast_native.dart` | **Opt-in** — direct FFI surfaces: `NativeOdbcConnection`, `AsyncNativeOdbcConnection`, `OdbcRepositoryImpl`, `OdbcPoolFactory`, `AsyncError` types, and OpenTelemetry FFI. Use when you bypass `ServiceLocator`, construct the repository yourself, or need low-level native types documented in examples such as [`simple_demo.dart`](example/simple_demo.dart) and [`async_demo.dart`](example/async_demo.dart). |
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
import 'package:odbc_fast/odbc_fast.dart';

Future<void> main() async {
  final locator = ServiceLocator()
    ..initialize(profile: OdbcUsageProfile.balanced);
  final service = locator.service;
  final tuning = locator.resolvedUsageProfile;

  final init = await service.initialize();
  if (init.isError()) return;

  final connResult = await service.connect(
    'DSN=MyDsn',
    options: locator.recommendedConnectionOptions,
  );
  final conn = connResult.getOrNull();
  if (conn == null) return;

  try {
    final query = await service.executeQuery(
      "SELECT 1 AS id, 'ok' AS msg",
      connectionId: conn.id,
    );

    query.fold(
      (r) => print(
        'profile=${tuning.profile.name} workers=${tuning.workerCount} '
        'rows=${r.rowCount} columns=${r.columns}',
      ),
      (e) => print('query error: $e'),
    );
  } finally {
    await service.disconnect(conn.id);
  }

  locator.shutdown();
}
```

## Performance quick reference

| Scenario | Prefer |
| -------- | ------ |
| Large SELECT (many rows, stable types) | `ResultEncoding.columnar` or `streamQueryBatched` / streaming APIs |
| INSERT &lt; ~100 rows | Prepared `INSERT` in a loop |
| INSERT 100–1k rows | `bulkInsert` / `bulkInsertArray` on one connection |
| INSERT &gt; ~1k rows | `bulkInsertParallel` + native [`ConnectionPool`](lib/infrastructure/native/native_pool.dart) |
| Concurrency / worker tuning | [`OdbcUsageProfile`](lib/domain/entities/odbc_usage_profile.dart) via `ServiceLocator.initialize(profile: ...)` |

Rationale, benchmarks, and opt-in perf test flags:
[doc/PERFORMANCE.md](doc/PERFORMANCE.md).

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

await service.initialize();
final connResult = await service.connect('DSN=MyDsn');
final conn = connResult.getOrNull();
if (conn != null) {
  await service.executeQuery('SELECT * FROM users', connectionId: conn.id);
  await service.disconnect(conn.id);
}

locator.shutdown();
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

`asyncWorkerCount` defaults from the active **[`OdbcUsageProfile`](lib/domain/entities/odbc_usage_profile.dart)**
(`2` for balanced, `1` for balancedFlutter, `4` for balancedServer, `6` for highThroughput, `1` for legacy).
Values greater than
`1` let independent connections or pool checkouts run on multiple Dart worker
isolates. Operations on the same connection, statement, transaction, stream, or
async request keep worker affinity so handle usage stays serialized.
`asyncMaxPendingRequests` is optional and opt-in; use it as backpressure for
high-concurrency services, typically a small multiple of native pool size.
This is the supported "thread opening" pattern for Dart consumers: configure
workers with `workerCount` / `asyncWorkerCount` and open multiple real
connections or pool checkouts. Do not spawn raw isolates around the same
connection expecting parallel SQL execution; the native connection mutex still
serializes one connection for ODBC safety.

If you use `AsyncNativeOdbcConnection` directly, you can also configure:

- `requestTimeout` for worker response timeout
- `autoRecoverOnWorkerCrash` for automatic worker re-initialization
- `workerCount` for an optional worker isolate pool (`1` if you construct
  `AsyncNativeOdbcConnection` with defaults; use `ServiceLocator.initialize` with
  an `OdbcUsageProfile` for preset worker counts)
- `maxPendingRequests` for a global pending-request cap (`null` with legacy
  profile; bounded with balanced and `highThroughput` presets)
- `backpressureMode` as `failFast` (legacy profile) or `waitForSlot` (balanced
  and `highThroughput` presets)
- `backpressureTimeout` when `waitForSlot` is active
- `getWorkerPoolStats()` for a Dart-side snapshot of routed, active, pending,
  timeout, cancel, latency, per-worker, and blocking-fallback counters

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

High-concurrency examples:

- [`example/high_concurrency_worker_pool_demo.dart`](example/high_concurrency_worker_pool_demo.dart)
  uses `AsyncNativeOdbcConnection(workerCount: 4)` with multiple connections,
  prints per-worker routing, and accepts `ODBC_CONCURRENCY_QUERY`.
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

Tuning defaults:

- API/web with native pool: set `workerCount` near `min(poolSize, cores)` and
  `maxPendingRequests` near `poolSize * 2` to `poolSize * 4`.
- Batch jobs: set `workerCount = poolSize`; prefer streaming for large result
  sets.
- Flutter/UI: keep `workerCount = 1` unless the app opens multiple real
  connections concurrently.
- Same connection: keep calls logically serial. More workers reduce contention
  only when there are multiple connections, native pool checkouts, or
  independent non-handle operations to route.

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

Fluent API for building ODBC connection strings. Seven builders ship by
default — three from v1, four added in v3.0:

```dart
// v1
SqlServerBuilder()...build();
PostgreSqlBuilder()...build();
MySqlBuilder()...build();

// v3.0 (NEW)
MariaDbBuilder()...build();   // {MariaDB ODBC 3.1 Driver}, port 3306
SqliteBuilder()...build();    // {SQLite3 ODBC Driver}, no Server/Port
Db2Builder()...build();       // {IBM DB2 ODBC DRIVER}, port 50000
SnowflakeBuilder()...build(); // {SnowflakeDSIIDriver}
```

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

Start with the performance checklist when choosing APIs:

```bash
dart run example/recommended_performance_patterns_demo.dart
```

| Workload | Prefer | Example |
| --- | --- | --- |
| Small query | `executeQuery` / `executeQueryParamValues` | `recommended_performance_patterns_demo.dart` |
| Large read | `streamQuery` (batched) / `streamQueryNamed` / `streamQueryColumnar` | `streaming_demo.dart`, `stream_query_named_demo.dart` |
| Medium insert (~hundreds) | `bulkInsert` | `bulk_insert_demo.dart` |
| Large insert (>1k) | `bulkInsertParallel` | `bulk_insert_parallel_demo.dart` |
| App default / async | `OdbcUsageProfile.balanced` | `quick_start_balanced_demo.dart` |
| Server / columnar | `balancedServer` / `highThroughput` | `stream_query_columnar_demo.dart`, `high_concurrency_pool_demo.dart` |
| Prepared reuse | prepare once, execute many | `named_parameters_demo.dart` |

```bash
# Core API
dart run example/main.dart
dart run example/recommended_performance_patterns_demo.dart  # workload → API checklist
dart run example/service_api_coverage_demo.dart
dart run example/advanced_entities_demo.dart
dart run example/simple_demo.dart
dart run example/quick_start_balanced_demo.dart        # OdbcUsageProfile.balanced
dart run example/sub_interfaces_migration_demo.dart    # IQueryService et al
dart run example/param_value_migration_demo.dart       # DSN-free ParamValue migration

# Connection / pool
dart run example/connection_string_builder_demo.dart   # 7 builders incl. MariaDB/SQLite/Db2/Snowflake
dart run example/pool_demo.dart
dart run example/pool_with_options_demo.dart           # PoolOptions

# Async
dart run example/async_demo.dart
dart run example/quick_start_balanced_demo.dart
dart run example/execute_async_demo.dart
dart run example/high_concurrency_worker_pool_demo.dart
dart run example/high_concurrency_pool_demo.dart
dart run example/async_concurrency_benchmark.dart
dart run example/backpressure_modes_demo.dart          # failFast / waitForSlot + recovery callback

# Optional: override the demo query with a slower/larger workload
ODBC_CONCURRENCY_QUERY="SELECT 1 AS value" dart run example/high_concurrency_worker_pool_demo.dart

# Queries / parameters
dart run example/named_parameters_demo.dart
dart run example/stream_query_named_demo.dart          # streamQueryNamed
dart run example/multi_result_demo.dart
dart run example/multi_result_stream_demo.dart         # streamQueryMulti per-item
dart run example/output_param_directions_demo.dart     # DRT1 IN/OUT/INOUT
dart run example/oracle_ref_cursor_demo.dart           # ParamValueRefCursorOut (opt-in)
dart run example/columnar_result_encoding_demo.dart    # ResultEncoding.columnar / .columnarCompressed
dart run example/typed_columnar_demo.dart              # TypedColumnarResult consumption
dart run example/streaming_demo.dart
dart run example/streaming_performance_benchmark.dart  # streamQuery vs streamQueryBatched

# Bulk insert
dart run example/bulk_insert_demo.dart                 # single-connection bulk insert (~500 rows)
dart run example/bulk_insert_parallel_demo.dart        # parallel bulk insert (>1k rows)

# Transactions / savepoints / XA
dart run example/run_in_transaction_demo.dart          # runInTransaction<T>
dart run example/savepoint_demo.dart
dart run example/transaction_helpers_demo.dart
dart run example/xa_2pc_demo.dart                      # Sprint 4.3 (XA / 2PC across 5 engines)

# Schema introspection
dart run example/catalog_reflection_demo.dart
dart run example/dbms_info_demo.dart                   # getConnectionDbmsInfo
dart run example/driver_features_demo.dart             # UPSERT/RETURNING/SessionInit

# Errors / observability
dart run example/structured_errors_demo.dart           # typed OdbcError classes
dart run example/event_bus_demo.dart                   # IAdminService.events
dart run example/audit_example.dart
dart run example/telemetry_demo.dart
dart run example/otel_repository_demo.dart
```

Coverage-oriented examples:

- `example/service_api_coverage_demo.dart`: exercises service methods that are
  less visible in quick-start docs (`executeQueryParamValuesFromObjects`,
  `prepare`, `executePreparedParamValuesFromObjects`, `cancelStatement`,
  `closeStatement`, pool APIs, `bulkInsert`, `getVersion`,
  `validateConnectionString`, `getDriverCapabilities`, metadata cache,
  audit API, async request/stream lifecycle).
- `example/advanced_entities_demo.dart`: demonstrates exported advanced types
  and helpers (`RetryHelper`, `RetryOptions`, `PreparedStatementConfig`,
  `StatementOptions`, `PrimaryKeyInfo`, `ForeignKeyInfo`, `IndexInfo`).
- `example/audit_example.dart`: dedicated audit wrapper demo with
  enable/status/events/clear flow.
- `example/catalog_reflection_demo.dart`: focused schema reflection demo for
  `catalogPrimaryKeys`, `catalogForeignKeys`, and `catalogIndexes`.
- `example/execute_async_demo.dart`: low-level async execution and streaming
  via worker isolate using raw payload parsing.
- `example/high_concurrency_worker_pool_demo.dart` and
  `example/high_concurrency_pool_demo.dart`: documented worker-pool and
  native-pool patterns for high-concurrency scenarios.
- `example/async_concurrency_benchmark.dart`: local Stopwatch-based benchmark
  for worker pool, native pool and streaming choices.
- `example/backpressure_modes_demo.dart`: contrasts `failFast` vs
  `waitForSlot` and wires the `onWorkerRecovered` callback that fires
  after auto-recovery.
- `example/sub_interfaces_migration_demo.dart`: side-by-side `IOdbcService`
  (aggregate) vs `IQueryService` (narrow sub-interface) plus the
  `executeQueryFor(Connection, ...)` overload.
- `example/event_bus_demo.dart`: subscribes to `IAdminService.events`
  and pattern-matches the sealed `OdbcEvent` variants (`PoolResize`,
  `SlowQueryDetected`, etc.).
- `example/columnar_result_encoding_demo.dart` and
  `example/streaming_performance_benchmark.dart`: opt-in result-encoding
  comparison and streaming throughput benchmark.
- `example/multi_result_stream_demo.dart`: per-item multi-result streaming
  via `streamQueryMulti`.
- `example/output_param_directions_demo.dart` and
  `example/oracle_ref_cursor_demo.dart`: DRT1 directed parameters and
  Oracle `REF CURSOR` materialization.
- `example/run_in_transaction_demo.dart` and `example/xa_2pc_demo.dart`:
  `runInTransaction<T>` and `runInXaTransaction` / native XA lifecycle
  (supported engines).
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
Primary keys, foreign keys, and indexes via `ServiceLocator`

- ✅ `catalogTables` (pick a sample table) / optional `ODBC_EXAMPLE_TABLE`
- ✅ `catalogPrimaryKeys`
- ✅ `catalogForeignKeys`
- ✅ `catalogIndexes`

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

**[named_parameters_demo.dart](example/named_parameters_demo.dart)** - `@name` / `:name` via service API

- ✅ `executeQueryNamed` and `prepareNamed` / `executePreparedNamed`
- ✅ Mixed `@name` and `:name` syntax
- ✅ Repeated placeholders reuse the same supplied value
- ✅ Prepared named statement reuse

**Advantages**:

- 🛡 SQL injection protection (bound parameters)
- ⚡ Reuse prepared statements for multiple executions
- 📝 Clean call sites with named maps
- 🔌 Database-agnostic placeholder syntax

#### Multi-Result Queries

**[multi_result_demo.dart](example/multi_result_demo.dart)** - Multiple result sets

- ✅ Portable multi-`SELECT` batches
- ✅ `executeQueryMultiFull` + `executeQueryMultiParamValues`
- ✅ Ordered result sets and row-counts via `QueryResultMulti`
- ✅ Streaming alternative: `streamQueryMulti` /
  [`multi_result_stream_demo.dart`](example/multi_result_stream_demo.dart)

**Advantages**:

- 📦 Fewer round trips to database
- ⚡ Batch multiple operations in a single request
- 🎯 Fits stored procedures with multiple results
- 📊 Stable multi-item parsing on the service layer

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

Checked-out pooled connections can start local transactions directly,
and `poolReleaseConnection(...)` rolls back leftover local work before
the connection is reused.

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

**[transaction_helpers_demo.dart](example/transaction_helpers_demo.dart)** -
Fluent transaction helpers on top of `TransactionHandle`

- `TransactionHandle.runWithBegin(...)`
- `TransactionHandle.withSavepoint(...)`
- Success only returns after commit succeeds
- Commit failure throws instead of returning a false success path

#### Pool with options (v3.0)

**[pool_with_options_demo.dart](example/pool_with_options_demo.dart)** -
Configurable pool eviction/timeouts

- ✅ `PoolOptions(idleTimeout, maxLifetime, connectionTimeout)`
- ✅ `OdbcPoolFactory.createPool(...)` with automatic legacy fallback
- ✅ Supports detection of `supportsApi` for old native libraries
- ✅ JSON-encoded options sent through `odbc_pool_create_with_options`
- `poolSetSize(...)` preserves resolved pool options after resize.

#### Live DBMS introspection (v2.1)

**[dbms_info_demo.dart](example/dbms_info_demo.dart)** - Real
`SQLGetInfo` discovery

- ✅ `OdbcDriverCapabilities.getDbmsInfoForConnection`
- ✅ Distinguishes MariaDB vs MySQL, ASE vs ASA via the live driver
- ✅ Reports `dbms_name`, `engine` id, identifier limits, current catalog
- ✅ Works for DSN-only connection strings

#### Driver-specific SQL builders (v3.0)

**[driver_features_demo.dart](example/driver_features_demo.dart)** -
UPSERT, RETURNING, and SessionInit

- ✅ `buildUpsertSql` for any of the 9 supported engines
- ✅ `appendReturningClause` with INSERT/UPDATE/DELETE positioning
- ✅ `getSessionInitSql` per dialect
- ✅ No DB connection needed — pure SQL generation

#### Structured error handling (v3.0)

**[structured_errors_demo.dart](example/structured_errors_demo.dart)** -
12+ typed error classes

- ✅ `ConnectionError`, `QueryError`, `ValidationError`, ... (v1)
- ✅ `NoMoreResultsError`, `MalformedPayloadError`, `RollbackFailedError`,
  `ResourceLimitReachedError`, `CancelledError`, `WorkerCrashedError`,
  `BulkPartialFailureError` (v3.0)
- ✅ `ErrorCategory` enum (transient/fatal/validation/connectionLost)
  for retry/abort/reconnect decision making

#### Transaction orchestration

**[run_in_transaction_demo.dart](example/run_in_transaction_demo.dart)** -
High-level `runInTransaction<T>` helper

- ✅ Begin → action → commit/rollback in a single call
- ✅ Action `Failure` rolls back; throws are caught and converted to
  `QueryError` (throw never escapes)
- ✅ Forwards `IsolationLevel`, `TransactionAccessMode.readOnly`, and
  `LockTimeout` to the underlying engine
- ✅ Rollback failures during cleanup are swallowed so they never
  overwrite the original cause

#### XA / 2PC distributed transactions (Sprint 4.3 / v3.4.x)

**[xa_2pc_demo.dart](example/xa_2pc_demo.dart)** - Full X/Open XA lifecycle

- ✅ Phase 1 + Phase 2 commit (`xa_start` / `xa_end` / `xa_prepare` /
  `xa_commit_prepared`)
- ✅ 1RM optimization (`commit_one_phase`) when this RM is the sole
  participant
- ✅ Crash recovery via `xaRecover` + `xaResumePrepared`
- ✅ Dedicated Oracle section (DML inside the branch so `xa_prepare`
  doesn't return `XA_RDONLY`)
- ✅ `XaTransactionHandle.runWithStart<T>` exception-safe helper

#### Sub-interfaces + Connection-typed overloads

**[sub_interfaces_migration_demo.dart](example/sub_interfaces_migration_demo.dart)** -
ISP-friendly seams

- ✅ Side-by-side `IOdbcService` (aggregate) vs `IQueryService` consumer
- ✅ `executeQueryFor(Connection conn, ...)` overload that drops the
  manual `conn.id` plumbing
- ✅ DSN-free smoke run: works as a describe-only example

#### Event bus

**[event_bus_demo.dart](example/event_bus_demo.dart)** -
`IAdminService.events` broadcast stream

- ✅ Pattern-matches sealed `OdbcEvent` variants (`ConnectionLost`,
  `WorkerRecovered`, `AutoReconnectAttempted`, `PoolResize`,
  `SlowQueryDetected`)
- ✅ Triggers real `PoolResize` via `poolSetSize` and real
  `SlowQueryDetected` with `slowQueryThreshold: Duration.zero`
- ✅ Best-effort observability — no back-pressure on the runtime
  emission path

#### Backpressure modes

**[backpressure_modes_demo.dart](example/backpressure_modes_demo.dart)** -
Async-pool flow control

- ✅ `AsyncBackpressureMode.failFast` — extras rejected with
  `AsyncErrorCode.resourceExhausted`
- ✅ `AsyncBackpressureMode.waitForSlot` — FIFO queueing up to
  `backpressureTimeout`
- ✅ `onWorkerRecovered` callback wiring after auto-recovery

#### Columnar result encoding

**[columnar_result_encoding_demo.dart](example/columnar_result_encoding_demo.dart)** -
Opt-in `ResultEncoding` comparison

- ✅ Runs the same SQL through `rowMajor`, `columnar`, and
  `columnarCompressed` encodings
- ✅ Surfaces decompression errors when the loaded native library
  lacks `odbc_columnar_decompress`
- ✅ Row-major remains the default; columnar is opt-in per call

#### Multi-result streaming

**[multi_result_stream_demo.dart](example/multi_result_stream_demo.dart)** -
`streamQueryMulti` per-item delivery

- ✅ Streams `QueryResultMultiItem` (result set OR row count) one item
  at a time
- ✅ Lower peak memory than `executeQueryMultiFull` for big batches

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
# Dart — CI-equivalent unit + docs (no live DSN)
dart test test/application test/domain test/infrastructure test/helpers/database_detection_test.dart test/documentation test/example

# Dart — full suite (integration/e2e/stress self-skip without env)
dart test

# Dart — integration (requires ODBC_TEST_DSN)
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

# Rust E2E — ENABLE_E2E_TESTS=1 + ODBC_TEST_DSN in .env (25 e2e_* suites)
powershell scripts/run_e2e_tests.ps1           # full incl. slow stress
powershell scripts/run_e2e_tests.ps1 -Quick    # live E2E only
./scripts/run_e2e_tests.sh                     # Linux/macOS equivalent

# Rust bulk insert benchmark (array vs parallel; from native/odbc_engine)
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
- [doc/API_SURFACE.md](doc/API_SURFACE.md) — FFI surface (**100** exports), public Rust API, Dart bindings
- [doc/CAPABILITIES_v3.md](doc/CAPABILITIES_v3.md) — driver capability traits × engine matrix
- [doc/BUILD.md](doc/BUILD.md) — build, library resolution, scripts
- [doc/TESTING.md](doc/TESTING.md) — test policy, CI scope, environment variables
- [doc/PERFORMANCE.md](doc/PERFORMANCE.md) — architectural performance notes and bench guide
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
