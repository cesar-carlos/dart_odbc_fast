# ODBC Fast examples

Execute any example from the project root:

```bash
dart run example/<file>.dart
```

All DB examples require `ODBC_TEST_DSN` (or `ODBC_DSN`) configured via environment
variable or `.env` in project root. Set `ODBC_EXAMPLE_DISABLE_DSN=1` for
DSN-free smoke runs that should skip DB-dependent work even when a local `.env`
exists.

## Cancellation note

- Statement cancellation is currently exposed but not implemented end-to-end in
  runtime execution.
- Prefer timeout-based control in examples and applications.

## Examples

### Core walkthrough

- [main.dart](main.dart): high-level `OdbcService` walkthrough including options, driver detection, named params, multi-result full, catalog calls, cache maintenance, and metrics.
- [service_api_coverage_demo.dart](service_api_coverage_demo.dart): service-level coverage for query params, prepare/execute/cancel/close, transactions/savepoint release, pooling (including detailed state), bulk insert, version/validation/capabilities, metadata cache, audit API, and async request/stream lifecycle.
- [advanced_entities_demo.dart](advanced_entities_demo.dart): `RetryHelper`, `RetryOptions`, `PreparedStatementConfig`, `StatementOptions`, and schema metadata entities.
- [simple_demo.dart](simple_demo.dart): low-level API with `connectWithTimeout`, structured errors, `TransactionHandle`, `CatalogQuery`, prepared statements, and result parsing.
- [quick_start_balanced_demo.dart](quick_start_balanced_demo.dart): minimal `ServiceLocator` + `OdbcUsageProfile.balanced`, `recommendedConnectionOptions`, optional pool hints, and `resolvedUsageProfile` inspection.

### Async

- [async_demo.dart](async_demo.dart): async API with `AsyncNativeOdbcConnection` (`requestTimeout` + `autoRecoverOnWorkerCrash`).
- [execute_async_demo.dart](execute_async_demo.dart): raw `executeAsync` and `streamAsync` for non-blocking single-query and streaming.
- [async_service_locator_demo.dart](async_service_locator_demo.dart): async mode using `ServiceLocator` with `OdbcUsageProfile.balanced` and `OdbcService`.
- [high_concurrency_worker_pool_demo.dart](high_concurrency_worker_pool_demo.dart): `AsyncNativeOdbcConnection(workerCount: 4)` with multiple connections and concurrent queries.
- [high_concurrency_pool_demo.dart](high_concurrency_pool_demo.dart): `ServiceLocator.initialize(profile: OdbcUsageProfile.highThroughput)` with native pool checkout/query/release and an explicit in-flight task limit from the resolved profile.
- [async_concurrency_benchmark.dart](async_concurrency_benchmark.dart): Stopwatch benchmark comparing `workerCount: 1`, `workerCount: 4`, native pool with an in-flight limit, streaming, row-major vs columnar result encodings, and prepared reuse.
- **[backpressure_modes_demo.dart](backpressure_modes_demo.dart)**: contrasts `AsyncBackpressureMode.failFast` (extra requests rejected with `resourceExhausted`) and `AsyncBackpressureMode.waitForSlot` (FIFO queueing until `backpressureTimeout`), and wires the `setOnWorkerRecovered` callback that fires after auto-recovery so higher layers can wipe stale ids.
- [columnar_result_encoding_demo.dart](columnar_result_encoding_demo.dart): opt-in `ResultEncoding.rowMajor`, `columnar`, and `columnarCompressed` comparison for a live DSN.
- [typed_columnar_demo.dart](typed_columnar_demo.dart): `executeQueryColumnarParamValues` and typed `TypedColumnarResult` column access (`Int32List`, `Float64List`, string columns).
- [streaming_performance_benchmark.dart](streaming_performance_benchmark.dart): focused streaming benchmark comparing `streamQuery` and `streamQueryBatched` with text/json/csv output.

Run the high-concurrency demos from the project root:

```bash
dart run example/high_concurrency_worker_pool_demo.dart
dart run example/high_concurrency_pool_demo.dart
dart run example/async_concurrency_benchmark.dart
dart run example/streaming_performance_benchmark.dart
```

`workerCount` / `asyncWorkerCount` is the supported way to open background
Dart workers for high concurrency. Use multiple connections or native-pool
checkouts; the same ODBC connection remains serialized by the native mutex.
Both high-concurrency demos accept `ODBC_CONCURRENCY_QUERY` for a slower or
larger workload:

```bash
ODBC_CONCURRENCY_QUERY="SELECT 1 AS value" dart run example/high_concurrency_worker_pool_demo.dart
```

The benchmark supports structured output:

```bash
ODBC_BENCH_OUTPUT=json ODBC_BENCH_OUT_FILE=bench_baselines/async.json dart run example/async_concurrency_benchmark.dart
ODBC_BENCH_OUTPUT=csv ODBC_BENCH_OUT_FILE=bench_baselines/async.csv dart run example/async_concurrency_benchmark.dart
ODBC_STREAM_BENCH_OUTPUT=json ODBC_STREAM_BENCH_OUT_FILE=bench_baselines/streaming.json dart run example/streaming_performance_benchmark.dart
```

Compare a saved streaming baseline with a new run:

```bash
dart run tool/compare_benchmark_baseline.dart --baseline bench_baselines/streaming.json --current bench_baselines/streaming-current.json --max-regression-percent 30
```

For DSN-free protocol/parser performance smoke checks, run from the project
root:

```bash
dart test test/performance/protocol_performance_test.dart
```

`benchmark_harness` init/connect micro-benches (shared
`benchmarks/odbc_async_benchmarks.dart`):

```bash
python scripts/run_dart_benchmarks.py --protocol --smoke --harness
dart run benchmarks/m1_baseline.dart
dart run benchmarks/m2_performance.dart
```

See [doc/PERFORMANCE.md](../doc/PERFORMANCE.md) for the full benchmark matrix.

The `P4.1` benchmark covers row-major parsing, columnar parsing, frame
accumulation with small chunks, and streaming multi-result decoding.

### Queries / parameters

- [named_parameters_demo.dart](named_parameters_demo.dart): named params with `@name` and `:name`, including repeated placeholders, `>5` named params, and prepared statement reuse.
- **[stream_query_named_demo.dart](stream_query_named_demo.dart)**: `IOdbcService.streamQueryNamed` — same single-chunk delivery as `executeQueryNamed`, but exposed as `Stream<Result<QueryResult>>` for uniform call sites and a typed failure stream item for missing named params.
- **[sub_interfaces_migration_demo.dart](sub_interfaces_migration_demo.dart)**: side-by-side `IOdbcService` (full aggregate) vs `IQueryService` (narrow sub-interface) consumer, exercising the new `executeQueryFor(Connection conn, ...)` overload that drops the manual `conn.id` plumbing.
- **[param_value_migration_demo.dart](param_value_migration_demo.dart)**: DSN-free side-by-side deprecated `executeQueryParams` (`List<dynamic>`) vs preferred `executeQueryParamValues` (`List<ParamValue>`).
- [multi_result_demo.dart](multi_result_demo.dart): multi-result payload parsing with `executeQueryMulti` and parameterized `executeQueryMultiParams`.
- [multi_result_stream_demo.dart](multi_result_stream_demo.dart): streaming multi-result consumption item-by-item with `streamQueryMulti`.
- [output_param_directions_demo.dart](output_param_directions_demo.dart): directed params (`IN`, `OUT`, `INOUT`) wire format and `executeQueryDirectedParams`.
- [oracle_ref_cursor_demo.dart](oracle_ref_cursor_demo.dart): opt-in Oracle `ParamValueRefCursorOut` call that surfaces cursor row sets through `QueryResult.refCursorResults`.
- [streaming_demo.dart](streaming_demo.dart): batched streaming and custom chunk streaming.

### Connection / pool

- [connection_string_builder_demo.dart](connection_string_builder_demo.dart): fluent connection string creation for **all 7 builders** (SQL Server, PostgreSQL, MySQL, plus v3.0 MariaDB / SQLite / Db2 / Snowflake).
- [pool_demo.dart](pool_demo.dart): connection pool lifecycle, reuse, pooled checkout -> local transaction -> release flow, state/health checks, and parallel bulk insert (column-oriented `addColumnText`).
- [bulk_insert_demo.dart](bulk_insert_demo.dart): single-connection `bulkInsert` with ~500 rows via `addColumnInt32` + `addColumnText`.
- **[pool_with_options_demo.dart](pool_with_options_demo.dart)** *(NEW v3.0)*: typed `PoolOptions` (`idleTimeout`, `maxLifetime`, `connectionTimeout`) with `OdbcPoolFactory`, automatic legacy fallback, and resize-safe config preservation.

### Transactions / savepoints

- [run_in_transaction_demo.dart](run_in_transaction_demo.dart): high-level `runInTransaction<T>` helper covering success, failure, throw-to-rollback, and transaction options.
- [savepoint_demo.dart](savepoint_demo.dart): transactions with savepoint, rollback to savepoint, and commit. Uses the high-level `OdbcService` API.
- **[transaction_helpers_demo.dart](transaction_helpers_demo.dart)** *(NEW v3.1)*: fluent helpers `TransactionHandle.runWithBegin` (commit-on-success / rollback-on-throw) and `TransactionHandle.withSavepoint(name, action)` for partial-rollback inside a longer transaction. `runWithBegin` now throws on commit failure instead of returning a false success path. Also prints the `SavepointDialect` wire codes and explains the new `auto` default.
- **[xa_2pc_demo.dart](xa_2pc_demo.dart)** *(Sprint 4.3 / 4.3c — extended in v3.4.1 with Oracle DBMS_XA, in v3.4.2 with the `runWithStart` helper)*: full X/Open XA / 2PC lifecycle via `XaTransactionHandle` + `Xid`. Covers Phase 1 + Phase 2 commit, the `commit_one_phase` 1RM optimisation, crash-recovery (`xaRecover` + `xaResumePrepared`), a bonus DML-inside-branch section that runs an INSERT inside the XA branch — required on Oracle so `xa_prepare` doesn't return `XA_RDONLY` and silently auto-complete the branch — and a final section showing the exception-safe helper `XaTransactionHandle.runWithStart<T>` (mirror of `TransactionHandle.runWithBegin` for local transactions: drives end → prepare → commit_prepared on success, or the appropriate rollback path on any throw, without manual chaining). Works against PostgreSQL, MySQL/MariaDB, DB2, **Oracle 10g+** (via `SYS.DBMS_XA` PL/SQL), and SQL Server on Windows builds with `--features xa-dtc`; advanced MSDTC `Reenlist` / RM recovery remains operational follow-up work.

### Schema introspection

- [catalog_reflection_demo.dart](catalog_reflection_demo.dart): schema reflection for primary keys, foreign keys, and indexes (now uses dialect-specific SQL via `CatalogProvider` for Oracle/Sybase/SQLite/Db2).
- **[dbms_info_demo.dart](dbms_info_demo.dart)** *(NEW v2.1)*: live DBMS introspection via `SQLGetInfo` — distinguishes MariaDB/MySQL, ASE/ASA, reports identifier limits and current catalog.

### Driver-specific SQL builders (v3.0)

- **[driver_features_demo.dart](driver_features_demo.dart)** *(NEW v3.0)*: pure SQL generation for `OdbcDriverFeatures.buildUpsertSql`, `appendReturningClause`, and `getSessionInitSql`. Cycles through 8 dialects.

### Errors

- **[structured_errors_demo.dart](structured_errors_demo.dart)** *(NEW v3.0)*: every concrete `OdbcError` subclass (5 from v1 + 7 from v3.0) with `ErrorCategory` decision-making.

### Audit / telemetry

- [audit_example.dart](audit_example.dart): audit wrapper demo with enable/status/events/clear flow.
- [telemetry_demo.dart](telemetry_demo.dart): `SimpleTelemetryService`, `ITelemetryRepository`, and `TelemetryBuffer` with in-memory repository.
- [otel_repository_demo.dart](otel_repository_demo.dart): `OpenTelemetryFFI` + `TelemetryRepositoryImpl` with optional OTLP endpoint.

### Event bus

- **[event_bus_demo.dart](event_bus_demo.dart)** *(NEW v3.10.0)*: subscribes to `IAdminService.events` and pattern-matches the sealed `OdbcEvent` hierarchy (`ConnectionLost`, `WorkerRecovered`, `AutoReconnectAttempted`, `PoolResize`, `SlowQueryDetected`). Triggers real `PoolResize` via `poolSetSize` and real `SlowQueryDetected` with `slowQueryThreshold: Duration.zero`. Skips DSN-dependent work when `ODBC_EXAMPLE_DISABLE_DSN=1` and prints the sealed variant catalogue instead.

## Shared helper

- [common.dart](common.dart): helper for DSN loading from `.env` and environment variables.
