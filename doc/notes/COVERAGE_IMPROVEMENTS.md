# Coverage improvements (native odbc_engine)

Notes on modules whose remaining uncovered lines depend on integration or E2E tests with a real DSN.

## query.rs

The functions `execute_query_with_connection`, `execute_query_with_params`, `execute_query_with_params_and_timeout`, and `execute_multi_result` delegate to `QueryPipeline` with a `&Connection<'static>`. The only code testable without a live connection is `get_global_metrics()`. **The remaining ~8 lines (execute_* paths) are covered by integration or E2E tests** that use a real ODBC connection.

## execution_engine.rs

Constructors, config, and cache logic are covered by unit tests. **Paths that use `Connection` (e.g. execution and fetch) depend on integration or E2E tests** with a DSN.

## streaming.rs

`StreamingState` and batched state logic are covered by unit tests. **`execute_streaming` and `execute_streaming_batched` depend on integration or E2E tests** that use a real connection.

## catalog.rs

`validate_and_parse_table` is covered by unit tests. **`list_tables`, `list_columns`, and `get_type_info`** depend on a real `Connection` (integration or E2E).

## transaction.rs

`IsolationLevel`, `TransactionState`, and validation paths (e.g. commit/rollback when already committed/rolled back) are covered by unit tests. **`Transaction::begin`, `execute`, `execute_sql`, `Savepoint` create/rollback/release, and the `Drop` impl that performs auto-rollback** depend on a live connection (integration or E2E).

## pool/mod.rs

`extract_pool_components` and `PoolState` are covered by unit tests. **`ConnectionPool::new`, `get`, `health_check`, and `OdbcConnectionManager::connect`, `is_valid`, `has_broken`** depend on a valid DSN (integration or E2E).

## ffi/mod.rs

The FFI layer (C API) is not exercised by lib unit tests. **Coverage of the FFI entrypoints is provided by E2E or FFI tests** when the `ffi-tests` feature and an ODBC driver are available.
