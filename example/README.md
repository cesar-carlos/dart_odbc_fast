# ODBC Fast Examples

Run any example with:

```bash
dart run example/<example_name>.dart
```

Configure `ODBC_TEST_DSN` in `.env` or as environment variable.

## Basic Examples

- [main.dart](main.dart) — Comprehensive demo (connections, queries, transactions, streaming, catalog, pooling, bulk insert). Does not demonstrate v0.3.0 features; see feature-specific examples below.

## Feature-Specific Examples

### v0.2.0 — Async API
- [async_demo.dart](async_demo.dart) — Non-blocking operations with worker isolates

### v0.3.0 — New Features
- [savepoint_demo.dart](savepoint_demo.dart) — Nested transaction markers
- [retry_demo.dart](retry_demo.dart) — Automatic retry with exponential backoff
- [connection_builder_demo.dart](connection_builder_demo.dart) — Fluent connection string builder
