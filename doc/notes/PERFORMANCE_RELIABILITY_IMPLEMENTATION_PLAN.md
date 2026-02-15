# PERFORMANCE_RELIABILITY_IMPLEMENTATION_PLAN.md

Detailed plan for performance and reliability improvements in the Dart + Rust stack (FFI + isolate + pool).

## Objective

Improve latency, throughput, and operational predictability without breaking public compatibility.

## Reference date

- 2026-02-15

## Baseline (current state)

Key observations in code:

1. Async streaming could close silently on failure (`return` without explicit error):
   - `lib/infrastructure/native/async_native_odbc_connection.dart`
2. Worker recovery could race through `onError` and `onDone`:
   - `lib/infrastructure/native/async_native_odbc_connection.dart`
3. Sync `getMetrics()` performed multiple FFI calls for the same snapshot:
   - `lib/infrastructure/native/native_odbc_connection.dart`
4. Repository bulk insert copied buffer (`Uint8List.fromList`) in hot paths:
   - `lib/infrastructure/repositories/odbc_repository_impl.dart`
5. Pool validated on checkout with query (`test_on_check_out(true)` + `SELECT 1`):
   - `native/odbc_engine/src/pool/mod.rs`
6. Some Rust runtime paths still used `unwrap/expect`:
   - `native/odbc_engine/src/async_bridge/mod.rs`
   - `native/odbc_engine/src/pool/mod.rs`
   - `native/odbc_engine/src/observability/telemetry/mod.rs`

## Technical goals (global DoD)

1. No async streaming error may be silently dropped.
2. Worker recovery must be serialized (one recovery at a time).
3. Reduce allocations/copies in bulk insert hot paths.
4. Eliminate avoidable panics in production runtime.
5. Keep `dart analyze`, `dart test`, and `cargo test -p odbc_engine --lib` green.
6. Update operations/troubleshooting docs after each phase.

## Execution status (2026-02-15)

- [x] Phase 1 - Item 1.1 (async streaming now propagates explicit errors)
- [x] Phase 1 - Item 1.2 (serialized worker recovery + dispose guard)
- [x] Phase 1 - Item 1.3 (Rust runtime panic hardening)
- [x] Phase 2 - Item 2.1 (sync `getMetrics` uses single snapshot)
- [x] Phase 2 - Item 2.2 (`Uint8List` reuse in bulk insert)
- [x] Phase 2 - Item 2.3 (pool checkout health-check configurable)
- [x] Phase 3 - Item 3.1 (incremental streaming API in repository/service)
- [x] Phase 3 - Item 3.2 (more robust streaming fallback)
- [x] Phase 4 - Item 4.1 (timeout/retry/pool limit hardening)
- [x] Phase 4 - Item 4.2 (FFI backward-compatibility checklist)
- [x] Phase 4 - Item 4.3 (Windows/Linux release smoke)

## Phase 0 - Measurement and guardrails

### Implementation

1. Define benchmark scenarios:
   - small/medium/large query
   - sync and async streaming
   - bulk insert array vs parallel
2. Standardize benchmark environment variables in a single document.
3. Record baseline throughput, p95 latency, and memory usage.

### Tests

1. `dart test`
2. `cargo test -p odbc_engine --lib`
3. Rust bulk benchmark (`e2e_bulk_compare_benchmark_test`)

### Documentation

1. Update `README.md` (benchmark section/commands)
2. Update `doc/BUILD.md` (benchmark reproducibility)

## Phase 1 - Critical reliability (low risk, high impact)

### Item 1.1 - Async streaming error propagation

Target file:

- `lib/infrastructure/native/async_native_odbc_connection.dart`

Changes:

1. Replace silent `return` with `throw AsyncError` + context
2. Preserve stream close in `finally`
3. Include worker/native error message when available

Tests:

1. `streamStart` failure
2. mid-stream `streamFetch` failure
3. `streamClose` is guaranteed on exception

### Item 1.2 - Race-free worker recovery

Target file:

- `lib/infrastructure/native/async_native_odbc_connection.dart`

Changes:

1. Add logical recovery lock (`_isRecovering` or `Completer<void> _recovering`)
2. `onError` and `onDone` must reuse ongoing recovery
3. Prevent concurrent `dispose/initialize`

Tests:

1. simulate `onError` and `onDone` nearly simultaneously
2. validate only one recovery execution
3. validate predictable failure for in-flight requests

### Item 1.3 - Remove avoidable Rust runtime panics

Initial target files:

- `native/odbc_engine/src/async_bridge/mod.rs`
- `native/odbc_engine/src/pool/mod.rs`
- `native/odbc_engine/src/observability/telemetry/mod.rs`

Changes:

1. Replace runtime-path `unwrap/expect` with explicit error handling
2. Convert poisoned locks to controlled error paths
3. Emit structured errors when applicable

Tests:

1. unit tests for runtime/pool initialization failures
2. FFI tests for error codes without panic

### Phase 1 documentation

1. `doc/TROUBLESHOOTING.md` (new symptoms/messages)
2. `doc/OBSERVABILITY.md` (error/recovery behavior)
3. `CHANGELOG.md`

## Phase 2 - Immediate performance (low risk)

### Item 2.1 - Single snapshot in `getMetrics()`

Target file:

- `lib/infrastructure/native/native_odbc_connection.dart`

Changes:

1. call `_native.getMetrics()` once
2. build `OdbcMetrics` from that single snapshot

Test:

1. unit test validating one fetch (mock/spy)

### Item 2.2 - Avoid unnecessary bulk insert copy

Target file:

- `lib/infrastructure/repositories/odbc_repository_impl.dart`

Changes:

1. skip `Uint8List.fromList` when `dataBuffer` is already `Uint8List`
2. evaluate internal overload for direct `Uint8List`
3. keep public API compatibility

Tests:

1. unit test for no-copy path
2. bulk insert sync/async regression

### Item 2.3 - Configurable pool checkout health-check

Target file:

- `native/odbc_engine/src/pool/mod.rs`

Changes:

1. make `test_on_check_out` configurable
2. keep safe default for compatibility
3. add high-performance mode for controlled workloads

Tests:

1. pool with checkout validation enabled/disabled
2. simple checkout latency comparison

Status (2026-02-15):

1. Implemented connection-string parser (`PoolTestOnCheckout` + aliases)
2. Implemented environment fallback (`ODBC_POOL_TEST_ON_CHECKOUT`)
3. Applied precedence: connection string > env var > safe default (`true`)
4. Sanitized connection string before driver usage (removed internal pool flag)
5. Added parser/precedence/default unit tests

### Phase 2 documentation

1. `README.md` (performance flags/recommendations)
2. `doc/BUILD.md` (execution parameters)
3. `doc/TROUBLESHOOTING.md` (safety vs latency trade-off)
4. `CHANGELOG.md`

## Phase 3 - Scalable streaming at higher layers

### Item 3.1 - Incremental streaming API in repository/service

Candidate files:

- `lib/domain/repositories/odbc_repository.dart`
- `lib/application/services/odbc_service.dart`
- `lib/infrastructure/repositories/odbc_repository_impl.dart`

Changes:

1. add optional streaming path without materializing full result set
2. keep current API for compatibility
3. document when to use stream vs full materialization

Tests:

1. integration with large dataset and controlled memory growth
2. functional equivalence between stream mode and full mode

Status (2026-02-15):

1. Added `streamQuery(connectionId, sql)` to `IOdbcRepository` and `IOdbcService`
2. Implemented incremental `QueryResult` chunk emission in `OdbcRepositoryImpl`
3. Preserved existing API compatibility (`executeQuery` still returns full result)
4. Added validation/delegation unit tests for new API

### Item 3.2 - More robust streaming fallback

Target file:

- `lib/infrastructure/repositories/odbc_repository_impl.dart`

Changes:

1. extend fallback to handle consumption-time failure (not only stream creation)
2. distinguish protocol, SQL, and timeout errors

Tests:

1. iteration-time failure
2. streaming timeout
3. cancel/dispose mid-stream

Status (2026-02-15):

1. Adjusted fallback to cover failure during first batched-stream consumption
2. Classified streaming errors by operational category:
   - protocol (`Streaming protocol error`)
   - timeout (`Query timed out`)
   - worker/dispose interruption (`Streaming interrupted`)
   - structured SQL error (`Streaming SQL error` with SQLSTATE/nativeCode)
3. Added unit coverage for iteration failure, timeout, interruption, and structured SQL errors

### Phase 3 documentation

1. `README.md` (production streaming guide)
2. `doc/TROUBLESHOOTING.md` (stream errors)
3. `CHANGELOG.md`

## Phase 4 - Final hardening and rollout

### Implementation

1. review timeout/retry/pool limits and defaults
2. FFI backward-compatibility checklist
3. Windows/Linux release smoke

Status (2026-02-15):

1. Implemented `ConnectionOptions` validation (timeouts/backoff/buffers/retry)
2. `connect` now rejects invalid options before native call
3. `poolCreate` now validates `connectionString` and `maxSize > 0`
4. Added unit tests for options and pool validation
5. Completed FFI backward-compatibility checklist:
   - `doc/notes/FFI_BACKWARD_COMPATIBILITY_CHECKLIST.md`
6. Aligned `cbindgen.toml` with exported ODBC + OpenTelemetry surface
7. Completed local Windows smoke:
   - `dart analyze`
   - `dart test`
   - `cargo test -p odbc_engine --lib`
   - `cargo build --release --target x86_64-pc-windows-msvc`
   - `dart run example/async_demo.dart`
   - `dart run example/streaming_demo.dart`
   - `dart run example/pool_demo.dart`
8. Formalized Linux build smoke in release workflow:
   - `.github/workflows/release.yml` (`ubuntu-latest`)
9. Consolidated evidence in:
   - `doc/notes/RELEASE_SMOKE_WINDOWS_LINUX_2026-02-15.md`

### Final tests

1. `dart analyze`
2. `dart test`
3. `cargo test -p odbc_engine --lib`
4. manual execution of key examples:
   - `example/async_demo.dart`
   - `example/streaming_demo.dart`
   - `example/pool_demo.dart`

### Final documentation

1. `README.md` (final consolidated state)
2. `doc/OBSERVABILITY.md`
3. `doc/TROUBLESHOOTING.md`
4. `doc/VERSIONING_QUICK_REFERENCE.md` (if surface/ABI changes)
5. `CHANGELOG.md`

## Recommended execution order

1. Phase 0
2. Phase 1
3. Phase 2
4. Phase 3
5. Phase 4

## Executive checklist

- [ ] Phase 0 completed
- [x] Phase 1 completed
- [x] Phase 2 completed
- [x] Phase 3 completed
- [x] Phase 4 completed
- [ ] Documentation consolidated and contradiction-free
- [ ] Ready for release
