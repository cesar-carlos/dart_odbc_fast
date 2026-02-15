# TROUBLESHOOTING.md - Common Issues

## 1. Native library not found

Symptoms:

- `StateError: ODBC engine library not found`
- `Failed to lookup symbol 'odbc_init'`

Resolution:

```bash
cd native
cargo build --release
```

Verify the file exists:

- Windows: `native/target/release/odbc_engine.dll`
- Linux: `native/target/release/libodbc_engine.so`

If the build output is in `native/odbc_engine/target/release`, copy it to `native/target/release`.

## 2. `dart pub get` did not download binary

The hook may skip download in CI/pub.dev environments.

Check:

1. The matching tag/release exists on GitHub (`vX.Y.Z`).
2. Release assets are at release root (`odbc_engine.dll`, `libodbc_engine.so`).
3. `pubspec.yaml` version matches the tag.

## 3. Rust build fails due to missing dependencies

Linux:

```bash
sudo apt-get install -y unixodbc unixodbc-dev libclang-dev llvm
```

Windows:

- Ensure the MSVC toolchain is active (`rustup default stable-msvc`).

## 4. `ffigen` fails to generate bindings

Checklist:

1. Header exists: `native/odbc_engine/include/odbc_engine.h`
2. `cbindgen` installed: `cargo install cbindgen`
3. Correct command: `dart run ffigen -v info`

## 5. Async API hangs or times out

Use explicit timeout and always dispose async connection correctly:

```dart
final conn = AsyncNativeOdbcConnection(
  requestTimeout: Duration(seconds: 30),
);

// ...
await conn.dispose();
```

Expected async error codes: `requestTimeout` and `workerTerminated`.

For async streaming (`streamQuery` / `streamQueryBatched`):

1. `stream_start` and `stream_fetch` failures now return `AsyncErrorCode.queryFailed`
2. Stream no longer closes silently on failure
3. With `autoRecoverOnWorkerCrash=true`, recovery is serialized (avoids `onError`/`onDone` race)
4. Repository/service stream errors are classified as:
   - `Streaming protocol error: ...` (framing/protocol)
   - `Query timed out` (from `ConnectionOptions.queryTimeout`)
   - `Streaming interrupted: ...` (worker/dispose during stream)
   - `Streaming SQL error: ...` (with SQLSTATE/nativeCode when available)

## 6. ODBC IM002 (driver/DSN) error

Typical message:

- `Data source name not found`

Check:

- Driver name in connection string
- System DSN configuration
- Driver installation (Windows: `Get-OdbcDriver`, Linux: `odbcinst -q -d`)

## 7. `Buffer too small` on large result sets

Increase per-connection buffer:

```dart
ConnectionOptions(maxResultBufferBytes: 32 * 1024 * 1024)
```

Or page SQL query (TOP/OFFSET-FETCH).

If `connect` fails with options validation error, verify:

- `queryTimeout`, `loginTimeout`, `connectionTimeout`, `reconnectBackoff` >= 0
- `maxResultBufferBytes` and `initialResultBufferBytes` > 0
- `initialResultBufferBytes` <= `maxResultBufferBytes` (when both set)

## 8. Release workflow fails

Common errors:

- `cp: cannot stat ...`
- `Pattern 'uploads/*' does not match any files`
- `403` while creating release
- `failed to find tool "x86_64-linux-gnu-gcc"` on Windows host (Linux cross-build)

See: [RELEASE_AUTOMATION.md](RELEASE_AUTOMATION.md)

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
