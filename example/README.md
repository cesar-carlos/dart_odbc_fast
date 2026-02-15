# ODBC Fast Examples

Run any example with:

```bash
dart run example/<example_name>.dart
```

Configure `ODBC_TEST_DSN` in `.env` or as environment variable.

All examples use `ServiceLocator` to obtain `OdbcService` (sync or async).

## Examples

- [main.dart](main.dart) — Metrics (no DB) and basic connect / query / disconnect using `ServiceLocator` and `syncService`.
- [async_demo.dart](async_demo.dart) — Simple connect, execute query, disconnect; same API, can be switched to `locator.initialize(useAsync: true)` and `locator.asyncService` for non-blocking operations.
- [savepoint_demo.dart](savepoint_demo.dart) — Transactions with savepoints: begin, create savepoint, rollback to savepoint, commit.


