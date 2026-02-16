# ODBC Fast examples

Execute any example from the project root:

```bash
dart run example/<file>.dart
```

All DB examples require `ODBC_TEST_DSN` (or `ODBC_DSN`) configured via environment variable or `.env` in project root.

## Examples

- [main.dart](main.dart): high-level `OdbcService` walkthrough including options, driver detection, named params, multi-result full, catalog calls, cache maintenance, and metrics.
- [service_api_coverage_demo.dart](service_api_coverage_demo.dart): service-level coverage for query params, prepare/execute/close, transactions/savepoint release, pooling, and bulk insert.
- [advanced_entities_demo.dart](advanced_entities_demo.dart): `RetryHelper`, `RetryOptions`, `PreparedStatementConfig`, `StatementOptions`, and schema metadata entities.
- [simple_demo.dart](simple_demo.dart): low-level API with `connectWithTimeout`, structured errors, `TransactionHandle`, `CatalogQuery`, prepared statements, and result parsing.
- [async_demo.dart](async_demo.dart): async API with `AsyncNativeOdbcConnection` (`requestTimeout` + `autoRecoverOnWorkerCrash`).
- [async_service_locator_demo.dart](async_service_locator_demo.dart): async mode using `ServiceLocator` (`useAsync: true`) and `OdbcService`.
- [named_parameters_demo.dart](named_parameters_demo.dart): named params with `@name` and `:name`, including prepared statement reuse.
- [multi_result_demo.dart](multi_result_demo.dart): multi-result payload parsing with `executeQueryMulti`.
- [streaming_demo.dart](streaming_demo.dart): batched streaming and custom chunk streaming.
- [pool_demo.dart](pool_demo.dart): connection pool lifecycle, reuse, state/health checks, and parallel bulk insert.
- [savepoint_demo.dart](savepoint_demo.dart): transactions with savepoint, rollback to savepoint, and commit.
- [connection_string_builder_demo.dart](connection_string_builder_demo.dart): fluent connection string creation for SQL Server/PostgreSQL/MySQL.
- [telemetry_demo.dart](telemetry_demo.dart): `SimpleTelemetryService`, `ITelemetryRepository`, and `TelemetryBuffer` with in-memory repository.
- [otel_repository_demo.dart](otel_repository_demo.dart): `OpenTelemetryFFI` + `TelemetryRepositoryImpl` with optional OTLP endpoint.

## Shared helper

- [common.dart](common.dart): helper for DSN loading from `.env` and environment variables.
