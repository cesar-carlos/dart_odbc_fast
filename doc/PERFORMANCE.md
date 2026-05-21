# Performance & Reliability Notes

> **Last updated for:** v3.8 (usage profiles)

This document records architectural decisions with a measurable performance or reliability impact. It is not a benchmark report — run the benches locally to get numbers for your workload.

---

## Recommended usage profiles (Dart)

[`OdbcUsageProfile`](../lib/domain/entities/odbc_usage_profile.dart) selects defaults
for [`ServiceLocator.initialize`](../lib/core/di/service_locator.dart): async vs
sync, worker count, backpressure, and the shape of
`recommendedConnectionOptions` / `recommendedPoolOptions`.

| Profile           | When to use                                   | Async | Workers | Pending cap |
| ----------------- | --------------------------------------------- | ----- | ------- | ----------- |
| `balanced`        | Default; apps that may open a few connections | yes   | 2       | 24          |
| `balancedFlutter` | Mostly one connection, UI responsiveness      | yes   | 1       | 16          |
| `balancedServer`  | Native pool + concurrent checkouts            | yes   | 4       | 32          |
| `highThroughput`  | Heavier server workloads with larger pools    | yes   | 6       | 48          |
| `legacy`          | CLI, tests, or minimal isolate overhead       | no    | 1       | unbounded   |

`ResultEncoding.rowMajor` remains the safe default for query payloads; prefer
columnar encodings only after benchmarking your workload (wide SQL Server rows
often hit async **blocking fallbacks** with columnar modes).

---

## Running benchmarks

From `native/odbc_engine`:

```powershell
# Criterion benches (HTML report in native/odbc_engine/target/criterion/)
cargo bench --bench bulk_operations_bench
cargo bench --bench comparative_bench
cargo bench --bench metadata_cache_bench

# Columnar v1 vs v2 encoding (with optional zstd)
cargo bench --bench columnar_v1_v2_encode

# Columnar v2 wire constants smoke (requires --features columnar-v2)
cargo bench --bench columnar_v2_placeholder --features columnar-v2
```

For Dart-side async concurrency comparisons, configure `ODBC_TEST_DSN` (or
`ODBC_DSN`) and run:

```powershell
dart run example/async_concurrency_benchmark.dart
dart run example/streaming_performance_benchmark.dart
```

The script uses `Stopwatch` and no extra packages. It compares:

- `workerCount: 1`
- `workerCount: 4`
- `workerCount: 4` with `ResultEncoding.columnar`
- `workerCount: 4` with `ResultEncoding.columnarCompressed`
- native pool with explicit `maxInFlight`
- streaming (`streamQueryBatched`)
- prepared statement reuse

Set `ODBC_BENCH_QUERY` or `ODBC_BENCH_STREAM_QUERY` to override the default
`SELECT 1 AS value` workload with a driver-specific slow or large-result query.
Use `ODBC_BENCH_PREPARED_QUERY` when the prepared-reuse scenario needs a
separate SQL statement.
Set `ODBC_BENCH_OUTPUT=json|csv` plus `ODBC_BENCH_OUT_FILE=...` to save a
structured baseline, for example:

```powershell
$env:ODBC_BENCH_OUTPUT="json"
$env:ODBC_BENCH_OUT_FILE="bench_baselines/async-worker-pool.json"
dart run example/async_concurrency_benchmark.dart
```

For focused streaming comparisons, use:

```powershell
$env:ODBC_STREAM_BENCH_QUERY="SELECT TOP 50000 * FROM Produto"
$env:ODBC_STREAM_BENCH_OUTPUT="json"
$env:ODBC_STREAM_BENCH_OUT_FILE="bench_baselines/streaming.json"
dart run example/streaming_performance_benchmark.dart
```

`streaming_performance_benchmark.dart` compares `streamQuery` and
`streamQueryBatched` with the same query and reports elapsed time, rows, chunks,
rows/s, `fetchSize`, and `chunkSize`.

To find slow Dart tests before they become a CI problem, run:

```powershell
dart run tool/test_slow_report.dart --top 20 --threshold-ms 500
```

Pass extra `dart test` arguments after `--`, for example:

```powershell
dart run tool/test_slow_report.dart --top 10 -- test/my_test
```

To enforce a local budget, add `--fail-threshold-ms`:

```powershell
dart run tool/test_slow_report.dart --top 20 --threshold-ms 500 --fail-threshold-ms 1500 -- test/infrastructure
```

For deterministic protocol/parser micro-benchmarks that do not need a DSN, run:

```powershell
dart test test/performance/protocol_performance_test.dart
```

The `P4.1` case reports row-major parse, columnar parse, frame accumulation
with small chunks, and streaming multi-result decoder timings. Use it as a
local before/after signal when changing Dart binary protocol code; it is a
sanity benchmark, not a cross-machine performance contract.

Benchmark baselines can be compared with:

```powershell
dart run tool/compare_benchmark_baseline.dart `
  --baseline bench_baselines/streaming-baseline.json `
  --current bench_baselines/streaming-current.json `
  --max-regression-percent 30
```

Live `test/my_test` table scans are bounded by default with `SELECT TOP N`.
Use `MY_TEST_ROW_LIMIT` to tune quick local coverage. Use
`RUN_LIVE_TESTS=1` to enable these live tests, and
`MY_TEST_FULL_TABLE_SCAN=1` only for deliberate full-table performance checks.

### Test categories and flags

| Category     | Flag                                                 | Purpose                                                               |
| ------------ | ---------------------------------------------------- | --------------------------------------------------------------------- |
| Unit/default | none                                                 | Deterministic tests that should run in normal `dart test` and CI.     |
| Live DB      | `RUN_LIVE_TESTS=1`                                   | Tests that need `ODBC_TEST_DSN` and may vary by local data volume.    |
| Stress       | `RUN_STRESS_TESTS=1` or legacy `RUN_SKIPPED_TESTS=1` | High-concurrency, timeout, or long-running stress validation.         |
| Performance  | `RUN_PERF_TESTS=1`                                   | Benchmark-style tests or scripts with runtime-sensitive expectations. |

Real-DSN async worker pool stress tests are deliberately gated separately from
normal skipped tests because driver scheduling varies. Run them only when you
want to validate local concurrency behavior:

```powershell
$env:RUN_SKIPPED_TESTS="1"
$env:ODBC_ASYNC_WORKER_POOL_STRESS="1"
dart test test/stress/async_worker_pool_real_dsn_stress_test.dart
```

To save a baseline before upgrading:

```powershell
cargo bench --bench bulk_operations_bench --bench comparative_bench --bench metadata_cache_bench `
  | Out-File ..\..\bench_baselines\v3.5.3.txt
```

---

## Concurrency

| Design decision                                                                               | Reasoning                                                                                                                                                                                                                                  |
| --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `odbc_pool_get_connection` releases the global state mutex before calling `r2d2::Pool::get()` | Without this, every concurrent FFI call serialised behind slow pool checkouts (up to 30 s). Throughput under contention now scales close to `r2d2.max_size`.                                                                               |
| `odbc_pool_close` drains live checkouts before removing the pool entry                        | Prevents a deadlock when other threads still hold pooled connections at shutdown.                                                                                                                                                          |
| `PoolAutocommitCustomizer` sets `autocommit(true)` on every checkout                          | One extra ODBC call per checkout; eliminates the worst case where a connection returned mid-transaction silently affected the next caller.                                                                                                 |
| `recv_timeout` + structured worker-disconnect error                                           | Converts an indefinite hang into an explicit `WorkerCrashed` error so the consumer can recover.                                                                                                                                            |
| `read_exact` in disk-spill readback                                                           | Eliminates silent short-read truncation on Windows for large spills with no happy-path cost.                                                                                                                                               |
| `Mutex<GlobalState>` granularity                                                              | Most critical path (`odbc_pool_get_connection`) is unblocked. Remaining FFI surface still serialises through the global state; granularising further is tracked as future work.                                                            |
| Async defaults via `ServiceLocator.initialize()`                                              | Default profile is `balanced`: `workerCount = 2`, `maxPendingRequests = 24`, `backpressureMode = waitForSlot`, `backpressureTimeout = 30s`. Use another `OdbcUsageProfile` when the app shape is clearer than one-size-fits-all defaults. |
| Direct `AsyncNativeOdbcConnection(...)` defaults                                              | Constructor defaults remain `workerCount = 1`, `maxPendingRequests = null`, and `backpressureMode = failFast`. Use `ServiceLocator` presets when you want profile-guided tuning instead of raw constructor defaults.                      |
| Async backpressure (`maxPendingRequests` / `asyncMaxPendingRequests`)                         | In services with native pools, keep the pending cap near `poolSize * 2` to `poolSize * 4` so the Dart worker queue does not hide saturation.                                                                                              |
| Worker isolates instead of raw threads                                                        | Dart consumers should scale with `workerCount` / `asyncWorkerCount`, not hand-spawn raw isolates around one connection. More workers only reduce bottlenecks when work can be routed across multiple connections or native-pool checkouts. |

---

## Choosing a concurrency path

| Workload                                          | Prefer                                                                                                     | Notes                                                                                                                                                             |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Many independent short/medium queries             | `AsyncNativeOdbcConnection(workerCount: N)`                                                                | Open multiple connections. Same-connection calls remain serialized. See `example/high_concurrency_worker_pool_demo.dart`.                                         |
| Many request-style tasks with bounded DB capacity | Native pool + `ServiceLocator.initialize(useAsync: true, asyncWorkerCount: N, asyncMaxPendingRequests: M)` | Keep an explicit in-flight limit close to pool size. Set `M` near `poolSize * 2` or `poolSize * 4`. See `example/high_concurrency_pool_demo.dart`.                |
| Large result sets                                 | `streamQueryBatched` / `streamAsync`                                                                       | Streaming controls memory pressure better than raising result-buffer limits.                                                                                      |
| Many rows with stable column types                | `ResultEncoding.columnar`                                                                                  | Columnar reduces repeated row framing and now avoids an extra Dart column-to-row materialization step during decode. Keep row-major as default for compatibility. |
| One long query on one connection                  | Async execute lifecycle                                                                                    | Keeps Dart responsive, but does not make one native connection run multiple statements at once.                                                                   |

The high-concurrency examples accept `ODBC_CONCURRENCY_QUERY` so you can compare
serial vs worker-pool behavior with a local slow query instead of the default
`SELECT 1 AS value`.

---

## Memory and bounds

| Design decision                                                   | Reasoning                                                                                                                                                                                                |
| ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `parse_bulk_insert_payload` validates null-bitmap length up-front | Single `len()` check per nullable column; prevents corrupted writes.                                                                                                                                     |
| `MAX_BULK_COLUMNS` / `MAX_BULK_ROWS` / `MAX_BULK_CELL_LEN` caps   | Three integer comparisons per payload header; prevents allocation-bomb DoS.                                                                                                                              |
| `serialize_bulk_insert_payload` uses `try_into` for length casts  | One branch per length field; returns `MalformedPayload` on overflow instead of silent truncation.                                                                                                        |
| `SecureBuffer::with_bytes`                                        | Closure-based access avoids the heap copy required by `into_vec` for short-lived consumers.                                                                                                              |
| `SecretManager::with_secret`                                      | Avoids the per-retrieve `Vec<u8>` clone when only read access is required.                                                                                                                               |
| Reusable Dart FFI scratch buffer                                  | Reuses the common result buffer and `out_written` pointer inside an isolate, with a reentrancy fallback to preserve safety. Native `-2` responses should report required size so Dart can grow directly. |

---

## Observability overhead

| Decision               | Reasoning                                                                                                                                                                                                        |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SpanGuard` RAII       | Same nominal cost as manual `start/finish`; eliminates leaks of `QuerySpan` (with full SQL text) on every error path, reducing long-running memory growth.                                                       |
| `sanitize_sql_for_log` | Linear scan of the SQL string per log call. The default INFO-level path is gated behind `if !self.enabled { return }`; sanitisation only runs when the logger is enabled. Bypass with `ODBC_FAST_LOG_RAW_SQL=1`. |

---

## Safety / correctness

| Decision                                                            | Reasoning                                                                                                                              |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `ffi::guard::call_int*` / `call_id*` / `call_ptr*` + `catch_unwind` | Single `catch_unwind` per FFI call (~tens of ns); converts Rust panics into stable error codes (`FfiError::Panic = -4`) instead of UB. |
| `quote_identifier_default` in `Savepoint` and `ArrayBinding`        | One validation per identifier, allocation-free; prevents SQL injection via identifiers.                                                |

---

## Known open work (active tracking)

These items are tracked in [`Features/PENDING_IMPLEMENTATIONS.md`](Features/PENDING_IMPLEMENTATIONS.md):

- **True chunk-by-chunk streaming** — `engine::streaming::execute_streaming` still materialises results internally before chunking (audit C7). Multi-result streaming FFI (`odbc_stream_multi_*`) added in v3.3.0 improves the surface but the per-cursor materialisation remains.
- **`Mutex<GlobalState>` granularisation** — the most critical pool path was unblocked; the rest of the FFI surface still serialises. Profiling under >16 concurrent callers will show this.
- **BCP / array-binding streaming** — bulk insert via `BulkCopyExecutor` and `ArrayBinding` does not stream; the full payload is materialised in the Rust engine.
