# ODBC Fast Examples

Run any example with:

```bash
dart run example/<example_name>.dart
```

Configure `ODBC_TEST_DSN` in `.env` or as environment variable.

Bulk insert in `main.dart` is gated by:

- `ODBC_EXAMPLE_ENABLE_BULK=1` (or `ODBC_FAST_ENABLE_BULK=1`)

## Basic Examples

- [main.dart](main.dart) — Comprehensive demo (connections, queries, transactions, streaming, catalog, pooling, bulk insert, multi-result).

## Feature-Specific Examples

### v0.2.0 — Async API

- [async_demo.dart](async_demo.dart) — Non-blocking operations with worker isolates

### v0.2.0 — New Features

- [savepoint_demo.dart](savepoint_demo.dart) — Nested transaction markers
- [retry_demo.dart](retry_demo.dart) — Automatic retry with exponential backoff
- [connection_builder_demo.dart](connection_builder_demo.dart) — Fluent connection string builder

## Advanced Examples

- [multi_result_demo.dart](multi_result_demo.dart) — `executeQueryMulti` (multiple result sets)
- [timeouts_demo.dart](timeouts_demo.dart) — `ConnectionOptions` (timeouts, `maxResultBufferBytes`), statement timeout
- [typed_params_demo.dart](typed_params_demo.dart) — `ParamValue*` typed parameters (native API)
- [low_level_wrappers_demo.dart](low_level_wrappers_demo.dart) — `PreparedStatement`, `TransactionHandle`, `ConnectionPool`, `CatalogQuery`
