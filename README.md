# ODBC Fast - Rust-native ODBC for Dart

[![CI](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/ci.yml/badge.svg)](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/ci.yml)
[![E2E Multi-DB](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/e2e_multidb.yml/badge.svg)](https://github.com/cesar-carlos/dart_odbc_fast/actions/workflows/e2e_multidb.yml)
[![codecov](https://codecov.io/gh/cesar-carlos/dart_odbc_fast/branch/main/graph/badge.svg)](https://codecov.io/gh/cesar-carlos/dart_odbc_fast)

`odbc_fast` is an ODBC data access package for Dart backed by an in-repo Rust engine over `dart:ffi`.

## What's New (Unreleased)

- **Usage profiles (`OdbcUsageProfile`)** — `ServiceLocator.initialize()` now
  defaults to async with a **balanced** preset and also exposes
  **`ResolvedOdbcUsageProfile`** for the effective config after overrides. The
  preset family now includes **`highThroughput`** for heavier server workloads.
  Use `profile: OdbcUsageProfile.legacy` for the previous sync-only defaults.
  See [Quick Start](#quick-start-high-level-service) and
  [`example/quick_start_balanced_demo.dart`](example/quick_start_balanced_demo.dart).

Highlights of the work currently on `main` ahead of the next tagged
release. See the [CHANGELOG](CHANGELOG.md) for the complete list and
[`doc/Features/PENDING_IMPLEMENTATIONS.md`](doc/Features/PENDING_IMPLEMENTATIONS.md)
for the remaining backlog.

### Sprint 4 — transaction control

- **`TransactionAccessMode.readOnly`** (Sprint 4.1) — emits
  `SET TRANSACTION READ ONLY` on PostgreSQL / MySQL / MariaDB / DB2 /
  Oracle; silent no-op on engines without a native hint (SQL Server,
  SQLite, Snowflake). Lets the engine skip locking and pick a
  snapshot read path where applicable.

- **Per-transaction `LockTimeout`** (Sprint 4.2) — `Duration` cap on
  how long any statement inside the transaction waits for a lock.
  Engine-aware emission: SQL Server `SET LOCK_TIMEOUT <ms>`,
  PostgreSQL `SET LOCAL lock_timeout`, MySQL/MariaDB
  `SET SESSION innodb_lock_wait_timeout` (sub-second values round
  UP to 1s so the bound is never silently relaxed).

- **`IOdbcService.runInTransaction<T>`** (Sprint 4.4) — captures the
  full begin → action → commit/rollback dance behind one call:

  ```dart
  final result = await service.runInTransaction<int>(
    connId,
    (txnId) async {
      // Any work here participates in the transaction.
      return const Success(42);
    },
    isolationLevel: IsolationLevel.repeatableRead,
    accessMode: TransactionAccessMode.readOnly,
    lockTimeout: const Duration(seconds: 2),
  );
  ```

  Action `Failure` rolls back, action throws are caught + converted
  to `QueryError` (the throw never escapes), commit failure surfaces
  as the unit-of-work failure, rollback failures during cleanup are
  swallowed so they never overwrite the original cause. See
  [`example/run_in_transaction_demo.dart`](example/run_in_transaction_demo.dart).

- **`TransactionHandle.runWithBegin<T>`** (low-level wrapper) - the
  helper now returns only after commit succeeds. If commit fails it
  throws `StateError`, so the success path can no longer mask a
  failed unit of work.

- **X/Open XA / 2PC** (Sprint 4.3 / 4.3c) — strongly-typed `Xid`
  value class + `XaTransactionHandle` state machine
  (Active → Idle → Prepared → Committed/RolledBack). Engine matrix:

  | Engine                | Status                                      |
  | --------------------- | ------------------------------------------- |
  | PostgreSQL            | ✅ `BEGIN` + `PREPARE TRANSACTION` + `pg_prepared_xacts` |
  | MySQL / MariaDB       | ✅ `XA START / END / PREPARE / COMMIT / RECOVER` |
  | DB2                   | ✅ same SQL grammar as MySQL                 |
  | **Oracle**            | ✅ **`SYS.DBMS_XA` PL/SQL** + `DBA_PENDING_TRANSACTIONS` (v3.4.1); needs `EXECUTE` on `DBMS_XA` + `FORCE [ANY] TRANSACTION` |
  | SQL Server (MSDTC)    | ✅ Windows + `--features xa-dtc` (DTC enlist + XA branch); Linux/CI still unsupported — see `doc/Features/PENDING_IMPLEMENTATIONS.md` §1.1 |
  | SQLite / Snowflake    | ❌ no 2PC support — `UnsupportedFeature`     |

1RM optimisation (`commit_one_phase`) skips the prepare-log write
when this RM is the sole participant. Crash-recovery via
`xaRecover` + `xaResumePrepared` (works across reconnects on every
✅ engine, including Oracle). See
[`example/xa_2pc_demo.dart`](example/xa_2pc_demo.dart) for the
full lifecycle (full 2PC, 1RM, crash-recovery, plus an
Oracle-specific section that runs DML inside the branch so the
prepare actually writes a log entry — without DML Oracle returns
`XA_RDONLY` and silently auto-completes the branch).

Current Dart limitation: XA/2PC is available through the sync/native backend
(`NativeOdbcConnection`, `OdbcService(useAsync: false)`). The async worker
backend does not expose `XaTransactionHandle` lifecycle methods yet.

### `SqlDataType` extras (17 new kinds, 27 total)

Cross-engine: `smallInt`, `bigInt`, `tinyInt`, `bit`, `text`, `xml`,
`json` (with optional `validate:true` round-trip), `uuid` (canonical
folding + bare-hex/`{...}` wrapping), `money` (4-fractional-digit
SQL Server convention), `interval` (`Duration` → portable
`'<n> seconds'` form).

Engine-specific: PostgreSQL `range` / `cidr` / `tsvector`, SQL Server
`hierarchyId` / `geography`, Oracle `raw` / `bfile`. See
  [`doc/notes/TYPE_MAPPING.md`](doc/notes/TYPE_MAPPING.md) for the full
  27-kind matrix with validation and wire-encoding details.

### Directed parameters, `OUT1`, `MULT`, and columnar v2

- **DRT1** request buffer + **`IOdbcService.executeQueryDirectedParams`**
  for mixed `IN` / `OUT` / `INOUT` (see
  [TYPE_MAPPING.md](doc/notes/TYPE_MAPPING.md) §3.1). Results can carry
  **`QueryResult.outputParamValues`** when the engine appends an `OUT1`
  footer. When `SQLMoreResults` yields additional items, the engine emits a
  **`MULT`** envelope followed by `OUT1`; the first result set still maps to
  `QueryResult.columns` / `rows` / `rowCount`, and the tail items surface in
  **`QueryResult.additionalResults`** (`DirectedResultItem` /
  `DirectedRowCountItem`). Legacy `executeQueryParams` / v0 param wire is
  unchanged.
- **Oracle `REF CURSOR` path:** `ParamValueRefCursorOut` uses the Oracle
  plugin path (`strip ?` + `SQLMoreResults`) and materializes cursor result
  sets into **`QueryResult.refCursorResults`** via the `RC1\0` trailer.
- **Columnar v2 results:** the engine can emit a v2 columnar payload; the
  Dart `BinaryProtocolParser` decodes both **uncompressed** and
  **compressed** column blocks (zstd / LZ4) through the native
  `odbc_columnar_decompress` FFI path. [columnar sketch](doc/notes/columnar_protocol_sketch.md)
  remains the long-form spec. Public query APIs keep row-major v1 as the
  default; use `ResultEncoding.columnar` or `ResultEncoding.columnarCompressed`
  on parameterized query paths only after validating the workload.

  Example: [`example/output_param_directions_demo.dart`](example/output_param_directions_demo.dart).

- **Performance guardrails:** live table-scan tests under `test/my_test` are
  skipped unless `RUN_LIVE_TESTS=1`, bounded by default (`MY_TEST_ROW_LIMIT`,
  default `5000`), and require `MY_TEST_FULL_TABLE_SCAN=1` for full scans. Use
  `dart run tool/test_slow_report.dart --top 20 --threshold-ms 500` to list the
  slowest Dart tests, and
  [`example/streaming_performance_benchmark.dart`](example/streaming_performance_benchmark.dart)
  to compare `streamQuery` vs `streamQueryBatched` on the same workload.

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
- Connection pooling with **configurable eviction/timeouts** (v3.0
  `PoolOptions`: `idleTimeout`, `maxLifetime`, `connectionTimeout`)
- Transactions and savepoints (Sql-92 / SQL Server dialects)
- Bulk insert payload builder and parallel bulk insert via pool
- Connection string validation, driver capabilities, and runtime version APIs
- **Live DBMS introspection** via `SQLGetInfo` (v2.1+): typed `DbmsInfo` with
  canonical engine id, identifier limits, current catalog
- **Driver-specific SQL builders** (v3.0): UPSERT, RETURNING/OUTPUT, and
  per-engine session initialization through `OdbcDriverFeatures`
- **9 supported engines** with dedicated plugins: SQL Server, PostgreSQL,
  MySQL, **MariaDB** (v3.0), Oracle, Sybase, **SQLite** (v3.0),
  **IBM Db2** (v3.0), **Snowflake** (v3.0)
- **Per-driver catalog dispatch** (v3.0): `catalogTables`/`catalogColumns`
  etc. now use `ALL_TABLES`/`sysobjects`/`sqlite_master`/`SYSCAT.*`
  automatically when targeting Oracle/Sybase/SQLite/Db2 (no more
  `INFORMATION_SCHEMA` failures on those engines)
- Audit API and metadata cache controls
- Async query/stream lifecycle controls (`executeAsyncStart/asyncPoll/...`)
- **Structured errors** with 12+ typed Dart classes: `ConnectionError`,
  `QueryError`, `ValidationError`, `UnsupportedFeatureError`,
  `EnvironmentNotInitializedError`, plus v3.0: `NoMoreResultsError`,
  `MalformedPayloadError`, `RollbackFailedError`,
  `ResourceLimitReachedError`, `CancelledError`, `WorkerCrashedError`,
  `BulkPartialFailureError` (with structured fields)
- Runtime metrics and telemetry hooks (in-memory + OpenTelemetry OTLP)

## Type Mapping

**Implemented input parameter types** (Dart → Database):
- `null`, `int` (32/64-bit auto), `String`, `List<int>` (binary)
- Canonical mappings:
  - `bool` → `Int(1|0)`
  - `double` → Decimal string with fixed scale (6)
    - `NaN` and `Infinity`/`-Infinity` throw `ArgumentError`
  - `DateTime` → UTC ISO8601 string
    - year must be in `[1, 9999]` (otherwise `ArgumentError`)

**Implemented result types** (Database → Dart) — **v3.0** typed enum
[`OdbcType`](lib/infrastructure/native/protocol/odbc_type.dart) with
**19 variants** matching the Rust wire protocol 1:1:

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

Use `OdbcType.fromDiscriminant(int)` or `ColumnMetadata.type` to access
the typed variant. Unknown discriminants degrade to `OdbcType.varchar`
for forward compatibility.

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
// Canonical double mapping rejects NaN/Infinity.
paramValuesFromObjects([double.nan]); // throws ArgumentError
paramValuesFromObjects([double.infinity]); // throws ArgumentError
```

```dart
// DateTime year must be in [1, 9999].
final outOfRangeDate = DateTime.utc(9999, 12, 31).add(const Duration(days: 2));
paramValuesFromObjects([outOfRangeDate]); // throws ArgumentError
```

## API coverage (implemented)

### High-level service (`OdbcService`)

- Query execution: `executeQuery`, `executeQueryParams`, `executeQueryNamed`
- Prepared lifecycle: `prepare`, `prepareNamed`, `executePrepared`, `executePreparedNamed`, `cancelStatement`, `closeStatement`
- Incremental streaming: `streamQuery` (chunked `QueryResult` stream)
- Named parameters: `prepareNamed`, `executePreparedNamed`, `executeQueryNamed`
- Multi-result: `executeQueryMulti`, `executeQueryMultiParams`, `executeQueryMultiFull`
- Metadata/catalog: `catalogTables`, `catalogColumns`, `catalogTypeInfo`, `catalogPrimaryKeys`, `catalogForeignKeys`, `catalogIndexes`
- Transactions: `beginTransaction`, `commitTransaction`, `rollbackTransaction`
- Savepoints: `createSavepoint`, `rollbackToSavepoint`, `releaseSavepoint`
- Pooling: `poolCreate`, `poolGetConnection`, `poolReleaseConnection`, `poolHealthCheck`, `poolGetState`, `poolGetStateDetailed`, `poolSetSize`, `poolClose`
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
- `asyncCancel` is best-effort for Rust async requests; it cannot guarantee an
  immediate interrupt when an ODBC driver is already blocked in a native call.
- `streamCancel` is effective between stream batches/iterations and is followed
  by stream close during async cleanup.
- Use query timeout as workaround (`ConnectionOptions.queryTimeout`,
  prepare/statement timeout options).

### Parameterized execution

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

### v2.1 — Live DBMS introspection

- `OdbcDriverCapabilities.getDbmsInfoForConnection(connId)` returns a typed
  [`DbmsInfo`](lib/infrastructure/native/driver_capabilities.dart) with
  the server-reported product name, canonical engine id, identifier
  length limits, and current catalog. More accurate than parsing the
  connection string (works for DSN-only, distinguishes MariaDB/MySQL,
  ASE/ASA, etc).
- `DatabaseEngineIds` and `DatabaseType.fromEngineId(id)` for stable
  switch/case across releases.

### v3.0 — Driver-specific capability builders

[`OdbcDriverFeatures`](lib/infrastructure/native/driver_capabilities_v3.dart)
exposes three pure SQL builders that resolve the dialect from the
connection string:

- `buildUpsertSql(...)` — generates dialect UPSERT (`ON CONFLICT`,
  `ON DUPLICATE KEY UPDATE`, `MERGE`, depending on engine).
- `appendReturningClause(sql, verb, columns)` — appends `RETURNING` /
  `OUTPUT INSERTED.*` / `RETURNING ... INTO` / `FROM FINAL TABLE`.
- `getSessionInitSql(connStr, options)` — returns the post-connect setup
  statements per engine (`SET application_name`, `ALTER SESSION SET
  NLS_*`, `PRAGMA foreign_keys=ON`, ...).

### v3.0 — Pool eviction/timeout options

[`PoolOptions`](lib/infrastructure/native/pool_options.dart) +
[`OdbcPoolFactory`](lib/infrastructure/native/pool_options.dart)
expose the new FFI `odbc_pool_create_with_options`:

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
  odbc_fast: ^3.0.0
```

Then:

```bash
dart pub get
```

Native binary resolution order is documented in [doc/BUILD.md](doc/BUILD.md).

## Quick Start (High-level service)

`ServiceLocator` is exported by `package:odbc_fast/odbc_fast.dart`.

By default, `initialize()` uses **[`OdbcUsageProfile.balanced`](lib/domain/entities/odbc_usage_profile.dart)**:
async API, two worker isolates, bounded backpressure, and helpers
`recommendedConnectionOptions`, `recommendedPoolOptions`, and
`recommendedPoolMaxSize` for copy-paste-friendly timeouts and pool tuning.
Use `locator.resolvedUsageProfile` when you want the effective config after
explicit async overrides.
Use **`initialize(profile: OdbcUsageProfile.legacy)`** for the historical
sync-only behavior, or pass explicit `useAsync` / worker parameters to
override individual knobs.

```dart
import 'package:odbc_fast/odbc_fast.dart';

Future<void> main() async {
  final locator = ServiceLocator()..initialize();
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

## Async API (non-blocking)

Async mode is **on by default** (balanced profile). `locator.service` and
`locator.asyncService` both refer to the high-level async service when async
is enabled.

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
  uses `ServiceLocator.initialize(useAsync: true, asyncWorkerCount: 4)` with a
  native pool, separate checkouts, an explicit in-flight task limit, and
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

```bash
# Core API
dart run example/main.dart
dart run example/service_api_coverage_demo.dart
dart run example/advanced_entities_demo.dart
dart run example/simple_demo.dart

# Connection / pool
dart run example/connection_string_builder_demo.dart   # 7 builders incl. MariaDB/SQLite/Db2/Snowflake
dart run example/pool_demo.dart
dart run example/pool_with_options_demo.dart           # NEW v3.0 (PoolOptions)

# Async
dart run example/async_demo.dart
dart run example/async_service_locator_demo.dart
dart run example/execute_async_demo.dart
dart run example/high_concurrency_worker_pool_demo.dart
dart run example/high_concurrency_pool_demo.dart
dart run example/async_concurrency_benchmark.dart

# Optional: override the demo query with a slower/larger workload
ODBC_CONCURRENCY_QUERY="SELECT 1 AS value" dart run example/high_concurrency_worker_pool_demo.dart

# Queries / parameters
dart run example/named_parameters_demo.dart
dart run example/multi_result_demo.dart
dart run example/streaming_demo.dart

# Transactions / savepoints
dart run example/savepoint_demo.dart
dart run example/transaction_helpers_demo.dart

# Schema introspection
dart run example/catalog_reflection_demo.dart
dart run example/dbms_info_demo.dart                   # NEW v2.1 (live SQLGetInfo)

# Driver-specific SQL builders (v3.0)
dart run example/driver_features_demo.dart             # NEW v3.0 (UPSERT/RETURNING/SessionInit)

# Errors / observability
dart run example/structured_errors_demo.dart           # NEW v3.0 (12+ typed error classes)
dart run example/audit_example.dart
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
- `example/high_concurrency_worker_pool_demo.dart` and
  `example/high_concurrency_pool_demo.dart`: documented worker-pool and
  native-pool patterns for high-concurrency scenarios.
- `example/async_concurrency_benchmark.dart`: local Stopwatch-based benchmark
  for worker pool, native pool and streaming choices.
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
- ✅ Repeated placeholders reuse the same supplied value
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

### Reference (current)

- [doc/API_SURFACE.md](doc/API_SURFACE.md) — complete FFI surface (92 functions), public Rust API, Dart bindings
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
- [doc/notes/ROADMAP_PENDENTES.md](doc/notes/ROADMAP_PENDENTES.md) — ordered epic backlog (PT)

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
