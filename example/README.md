# ODBC Fast examples

Execute any example from the project root:

```bash
dart run example/<file>.dart
```

All DB examples require `ODBC_TEST_DSN` (or `ODBC_DSN`) configured via environment variable or `.env` in project root.

## Examples

- [main.dart](main.dart): high-level quickstart with `OdbcService` (initialize, connect, query, metrics, disconnect).
- [simple_demo.dart](simple_demo.dart): low-level API with `NativeOdbcConnection`, prepared statements, and result parsing.
- [async_demo.dart](async_demo.dart): async API with `AsyncNativeOdbcConnection`.
- [named_parameters_demo.dart](named_parameters_demo.dart): named params with `@name` and `:name`, including prepared statement reuse.
- [multi_result_demo.dart](multi_result_demo.dart): multi-result payload parsing with `executeQueryMulti`.
- [streaming_demo.dart](streaming_demo.dart): batched streaming and custom chunk streaming.
- [pool_demo.dart](pool_demo.dart): connection pool lifecycle, reuse, and state/health checks.
- [savepoint_demo.dart](savepoint_demo.dart): transactions with savepoint, rollback to savepoint, and commit.

## Shared helper

- [common.dart](common.dart): helper for DSN loading from `.env` and environment variables.
