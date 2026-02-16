
# TROUBLESHOOTING.md - Common Issues

## 1. Native library not found

Symptoms:
- `StateError: ODBC engine library not found`

Resolution:
- Build and test native library
- Ensure native binary is deployed correctly

Check:
- Windows: `native/target/release/odbc_engine.dll`
- Linux: `native/target/release/libodbc_engine.so`

If build output is in `native/odbc_engine/target/release`, copy it to
`native/target/release`.

## 2. `Failed to lookup symbol 'odbc_init'`

Symptoms:
- Native FFI symbol not found

Resolution:
- Run `dart run ffigen -v info` and verify bindings are generated correctly
- Verify `cbindgen` is installed
- Ensure `Cargo.toml` has correct configuration

Checklist:
1. Header exists: `native/odbc_engine/include/odbc_engine.h`
2. `cbindgen` installed: `cargo install cbindgen`
3. Correct command: `dart run ffigen -v info`

## 3. Async API hangs or times out

Symptoms:
- Query execution seems to hang indefinitely

Resolution:
- Use explicit timeout and always dispose async connection correctly

Example:
```dart
final conn = AsyncNativeOdbcConnection(
  requestTimeout: Duration(seconds: 30),
);
// ...
await conn.dispose();
```

Expected async error codes: `requestTimeout` and `workerTerminated`.

## 4. Unsupported parameter type

Symptoms:
- Error: "Unsupported parameter type: X"

Cause:
- Passing an unsupported type to `executeQueryParams` or bulk insert

Resolution:
- Convert to supported type before passing:
- `bool` -> `ParamValueInt32(1|0)`
- `double` -> `ParamValueDecimal(value.toString())`
- `DateTime` -> `ParamValueString(value.toUtc().toIso8601String())`
- Or use explicit `ParamValue` wrapper

Migration Guide:
1. Identify where unsupported types are used
2. Convert to canonical type or use explicit `ParamValue` wrapper
3. Run `dart analyze` to verify changes

## 5. Bulk insert nullability error

Symptoms:
- Error: 'Column "name" is non-nullable but contains null at row X. 
  Use nullable: true for columns that should accept null.'

Cause:
- Trying to insert `null` into a column defined as non-nullable

Resolution:
- Set `nullable: true` for columns that should accept null values
- Or provide actual values for non-nullable columns

Example:
```dart
// Don't do this:
builder.addColumn('id', BulkColumnType.i32)
  .addRow([null]);

// Do this instead:
builder.addColumn('id', BulkColumnType.i32, nullable: true)
  .addRow([null]);
```

## 6. ODBC IM002 (driver/DSN) error

Symptoms:
- Error message contains SQLSTATE code starting with "IM002"

Typical message:
- "Data source name not found"

Resolution:
- Verify data source configuration
- Check system DSN settings
- Ensure ODBC driver is installed

Check:
1. Driver name in connection string
2. System DSN configuration
3. ODBC driver installation (Windows: `Get-OdbcDriver`, Linux: `odbcinst -q -d`)

## 7. Buffer too small on large result sets

Symptoms:
- Truncated query results on large datasets

Resolution:
- Increase per-connection buffer size

Example:
```dart
ConnectionOptions(
  maxResultBufferBytes: 32 * 1024 * 1024,
);
```

Or use page SQL query (TOP/OFFSET-FETCH).

## 8. Release workflow fails

Common errors:
- `cp: cannot stat ...`
- Pattern 'uploads/*' does not match any files
- `403` while creating release
- `failed to find tool "x86_64-linux-gnu-gcc"` on Windows host (Linux cross-build)

For Linux cross-build error on Windows:
1. Run Linux build in official workflow (`ubuntu-latest`) in `.github/workflows/release.yml`
2. Or install local cross toolchain for `x86_64-unknown-linux-gnu`

## 9. Quick diagnostics

```bash
dart --version
rustc --version
cargo --version
```

Linux:
```bash
odbcinst -q -d
odbcinst --version
```

Windows:
```powershell
Get-OdbcDriver
```

## 10. When to open an issue

Open an issue at https://github.com/cesar-carlos/dart_odbc_fast/issues with:

1. Full error output
2. OS and versions (Dart/Rust/ODBC driver)
3. Reproduction steps
4. Minimal code snippet

## 11. Rust benchmark (bulk array vs parallel) was skipped

If `cargo test --test e2e_bulk_compare_benchmark_test -- --ignored --nocapture` does not execute:

1. Set `ENABLE_E2E_TESTS=true`
2. Configure valid `ODBC_TEST_DSN`
3. Confirm local ODBC connectivity (driver + DSN)

Optional:
- Tune volume with `BULK_BENCH_SMALL_ROWS` and `BULK_BENCH_MEDIUM_ROWS`

## 12. High pool checkout latency

By default, pool validates connection on checkout (`SELECT 1`).

This reduces broken-connection risk but adds acquisition cost.

For controlled workloads (low invalid-connection probability), disable validation:

```bash
ODBC_POOL_TEST_ON_CHECKOUT=false
```

Or per pool in connection string:
```text
DSN=MyDsn;PoolTestOnCheckout=false;
```

Accepted values: `true/false`, `1/0`, `yes/no`, `on/off`.

When both are defined, connection string takes precedence.

## 13. Linux link error: `undefined symbol: SQLCompleteAsync`

Symptoms:
- Linking with 'cc' failed
- `rust-lld: error: undefined symbol: SQLCompleteAsync`

Root cause:
- `odbc-api` default feature set may require ODBC 3.80 async symbols not exported by all installed `libodbc` variants.

Resolution:

Use `odbc-api` with explicit ODBC 3.5 feature in `native/odbc_engine/Cargo.toml`:

```toml
odbc-api = { version = "3.51", default-features = false, features = ["odbc_version_3_5"] }
```

Then rebuild:

```bash
cargo test --manifest-path native/Cargo.toml --workspace --all-targets
```

## 14. Bulk insert nullability validation

Symptoms:
- Error: 'Column "name" is non-nullable but contains null at row X. 
  Use nullable: true for columns that should accept null.'

Cause:
- Trying to insert `null` into a column defined as non-nullable

Resolution:
- Set `nullable: true` for columns that should accept null values
- Or provide actual values for non-nullable columns

Example:
```dart
// Don't do this:
builder.addColumn('id', BulkColumnType.i32)
  .addRow([null]);

// Do this instead:
builder.addColumn('id', BulkColumnType.i32, nullable: true)
  .addRow([null]);
```

This is a new validation added in Phase 1-2 of the 
NULL_HANDLING_RELIABILITY_PERFORMANCE_PLAN.

