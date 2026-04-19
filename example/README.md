# ODBC Fast examples

Execute any example from the project root:

```bash
dart run example/<file>.dart
```

All DB examples require `ODBC_TEST_DSN` (or `ODBC_DSN`) configured via environment variable or `.env` in project root.

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

### Async

- [async_demo.dart](async_demo.dart): async API with `AsyncNativeOdbcConnection` (`requestTimeout` + `autoRecoverOnWorkerCrash`).
- [execute_async_demo.dart](execute_async_demo.dart): raw `executeAsync` and `streamAsync` for non-blocking single-query and streaming.
- [async_service_locator_demo.dart](async_service_locator_demo.dart): async mode using `ServiceLocator` (`useAsync: true`) and `OdbcService`.

### Queries / parameters

- [named_parameters_demo.dart](named_parameters_demo.dart): named params with `@name` and `:name`, including prepared statement reuse.
- [multi_result_demo.dart](multi_result_demo.dart): multi-result payload parsing with `executeQueryMulti`.
- [streaming_demo.dart](streaming_demo.dart): batched streaming and custom chunk streaming.

### Connection / pool

- [connection_string_builder_demo.dart](connection_string_builder_demo.dart): fluent connection string creation for **all 7 builders** (SQL Server, PostgreSQL, MySQL, plus v3.0 MariaDB / SQLite / Db2 / Snowflake).
- [pool_demo.dart](pool_demo.dart): connection pool lifecycle, reuse, state/health checks, and parallel bulk insert.
- **[pool_with_options_demo.dart](pool_with_options_demo.dart)** *(NEW v3.0)*: typed `PoolOptions` (`idleTimeout`, `maxLifetime`, `connectionTimeout`) with `OdbcPoolFactory` and automatic legacy fallback.

### Transactions / savepoints

- [savepoint_demo.dart](savepoint_demo.dart): transactions with savepoint, rollback to savepoint, and commit. Uses the high-level `OdbcService` API.
- **[transaction_helpers_demo.dart](transaction_helpers_demo.dart)** *(NEW v3.1)*: fluent helpers `TransactionHandle.runWithBegin` (commit-on-success / rollback-on-throw) and `TransactionHandle.withSavepoint(name, action)` for partial-rollback inside a longer transaction. Also prints the `SavepointDialect` wire codes and explains the new `auto` default.

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

## Shared helper

- [common.dart](common.dart): helper for DSN loading from `.env` and environment variables.
