# Performance & Reliability Notes

> **Last updated for:** v4.5.1 (Dart FFI `asFunction` trampoline cache;
> shared protocol `ByteData` views; param serialize / DateTime parse
> allocation cuts; prior v4.5.0 binary float/bool wire + Dart dual-decode;
> prepared cache with inferable NULLs; stream prepared reuse; pool
> `sessionResetOnCheckout` opt-out + single checkout reset; FFI mid-size
> transient from 32 KiB; additive `streamChunkSizeBytes` /
> `blockFetchBatchSize`; server presets 1 MiB chunk + `lazyStrings`;
> prior v4.4.0 async XA + multi-stream knobs; prior v4.1.0 server profile
> columnar recommendation, CRUD columnar bulk benchmark baseline, harness
> `--crud` lane; service surface, pool/transaction hardening, native engine
> perf follow-ups with `block-cursor-fetch` and `statement-handle-reuse`
> default ON, FFI `GlobalState` sharded, `OwnedPreparedStatement` RAII
> for the prepared cache, release/bench profiles tightened).

This document records architectural decisions with a measurable performance or reliability impact. It is not a benchmark report — run the benches locally to get numbers for your workload.

---

## Native engine fetch and prepared cache (current defaults)

| Knob | Default | Effect |
| ---- | ------- | ------ |
| `block-cursor-fetch` feature | **enabled** | Cursor fetch goes through `engine::core::block_fetch::fetch_rows_into` (`BlockCursor` + `ColumnarAnyBuffer`) for queries whose columns can all be pre-bound. LOBs / `WLONGVARCHAR` without an advertised max length transparently fall back to the legacy per-row path. |
| `statement-handle-reuse` feature | **enabled** | `CachedConnection` keeps a per-connection LRU of `OwnedPreparedStatement` (RAII guard around the `mem::transmute` that fabricates the `'static` lifetime). `execute_query_with_params` rebinds on the cached statement when the param list is legacy/no-NULL. **Pooled** checkouts store `CachedConnection` in r2d2 and route `odbc_exec_query_params` / `odbc_exec_query` through `try_cached_legacy_params` / `execute_query_with_cached_connection` (wave 4.2). |
| `ODBC_FAST_BLOCK_FETCH_BATCH` env var | `256` | Batch size for `BlockCursor::fetch_with_truncation_check`. Invalid or missing values fall back to the default. Cached via `OnceLock`, so `std::env::var` is not consulted per query. |

Opt out at the crate level with
`odbc_engine = { version = "...", default-features = false, features = ["test-helpers", "observability"] }`.

The fetch dispatcher lives in `engine::fetch::fetch_cursor_into_row_buffer`
and decides between the legacy per-row loop and the block path; a separate
direct column-major path (`engine::core::columnar_fetch::fetch_columnar_into`)
populates `RowBufferV2` for non-FOR-JSON queries when columnar encoding is
requested, skipping the row-major intermediate. See
[`native/odbc_engine/ARCHITECTURE.md`](../native/odbc_engine/ARCHITECTURE.md)
for the dispatcher + sharded-state diagrams.

The FFI hot path used to lock a single `Mutex<GlobalState>` for every entry
point. Today metrics and the audit logger are `Arc` singletons (lock-free),
the per-connection error map lives in a dedicated `RwLock`, async requests
have their own `Mutex<AsyncRequestManager>`, and the legacy global error
slot lives behind its own `RwLock<LegacyGlobalError>` with `log::error!`
on poison. Lock ordering when more than one is taken is
`Outer → AsyncReqs → Errors (write) → Errors (read)`.

---

## Recommended usage profiles (Dart)

[`OdbcUsageProfile`](../lib/domain/entities/odbc_usage_profile.dart) selects defaults
for [`ServiceLocator.initialize`](../lib/core/di/service_locator.dart): async vs
sync, worker count, backpressure, and the shape of
`recommendedConnectionOptions` / `recommendedPoolOptions`.

| Profile           | When to use                                   | Async | Workers | Pending cap | Recommended columnar encoding | Stream `chunkSize` | `lazyStrings` |
| ----------------- | --------------------------------------------- | ----- | ------- | ----------- | ----------------------------- | ------------------ | ------------- |
| `balanced`        | Recommended opt-in preset for general apps    | yes   | 2       | 24          | row-major                     | 64 KiB             | off           |
| `balancedFlutter` | Mostly one connection, UI responsiveness      | yes   | 1       | 16          | row-major                     | 64 KiB             | off           |
| `balancedServer`  | Native pool + concurrent checkouts            | yes   | 4       | 32          | **columnar**                  | **1 MiB**          | **on**        |
| `highThroughput`  | Heavier server workloads with larger pools    | yes   | 6       | 48          | **columnar**                  | **1 MiB**          | **on**        |
| `legacy`          | Default; CLI, tests, minimal isolate overhead | no    | 1       | unbounded   | row-major                     | 64 KiB             | off           |

**QueryResult vs columnar wire:** APIs that return `QueryResult`
(`executeQuery*`, `streamQuery*`) always request **row-major** wire via
`forQueryResultWire` (columnar requests are clamped). This avoids
columnar-wire → `List<List<dynamic>>` rematerialization. Server presets still
set repository `defaultResultEncoding` to columnar for
`executeQueryColumnar*` / `streamQueryColumnar*` only.

`ServiceLocator.recommendedStreamChunkSizeBytes` exposes the table's stream
chunk suggestion; public `streamQuery` / `streamQueryNamed` /
`streamQueryColumnar` / `streamQueryMulti` signature defaults remain 64 KiB —
pass `chunkSize: locator.recommendedStreamChunkSizeBytes` (and optional
`fetchSize`) explicitly for large scans. Those parameters forward through to
batched native start and each `streamFetch(bufferSize: chunkSize)` (async and
sync).

`ConnectionOptions.fromUsageProfile` for server presets enables `lazyStrings`
and sets `initialResultBufferBytes` to 1 MiB. Repository runners seed FFI via
`callWithBuffer(initialSize:)` for single-result, multi-result, and prepared
execute (clamped by `maxResultBufferBytes`). When the connection option is
null, runners use `defaultInitialResultBufferBytes` (64 KiB). Prepared
executions may override with `StatementOptions.initialBufferSize`.

FFI scratch vs transient: seeds below 256 KiB reuse the scratch pool; seeds at
or above 256 KiB (or `preferTransient`) use transient allocation for
zero-copy. The shared byte scratch (params + mid-size bulk ≤256 KiB) and
`ProtocolByteAccumulator` growth past 64 KiB snaps to the 1 MiB pool tier.

Buffered `executeQueryMulti*` timeouts are Dart-side only (`Future.timeout`);
they do not cancel in-flight worker FFI. Prefer `streamQueryMulti` when
cancellation matters.

`streamQuery*` `chunkSize` may be omitted (`null`): runners use
`ConnectionOptions.streamChunkSizeBytes` (1 MiB on server presets) or 64 KiB.

`LazyString` cells still equal `String` via `==`; use `.value` (or disable
lazy strings) when `is String` checks matter. ASCII text uses
`String.fromCharCodes` on decode.

Columnar modes need the native engine to export `odbc_execute_async_params_options`
so the worker isolate can start async execution with a non-row-major encoding.
Older engines without that symbol still fall back to a blocking query for
columnar requests.

---

## Running benchmarks

From `native/odbc_engine`:

```powershell
# Criterion benches (HTML report in native/odbc_engine/target/criterion/)
cargo bench --bench bulk_operations_bench
# Narrow a single Criterion case (useful when `encode_small_buffer_100_rows` is noisy):
cargo bench --bench bulk_operations_bench -- encode_small_buffer_100_rows
# Deterministic in-memory streaming copy guardrail (no DSN required):
cargo bench --bench bulk_operations_bench -- streaming_copy_next_chunk
cargo bench --bench comparative_bench
cargo bench --bench metadata_cache_bench

# Columnar v1 vs v2 encoding (with optional zstd)
cargo bench --bench columnar_v1_v2_encode

# Columnar v2 wire constants smoke (requires --features columnar-v2)
cargo bench --bench columnar_v2_placeholder --features columnar-v2

# Native engine follow-up micro-benches (no DSN required):
#   cell_reader_bench       — Integer/BigInt/Varchar/Binary/Date/Timestamp paths
#   encoder_bench           — RowBufferEncoder + direct columnar vs row-major
#   ffi_contention_bench    — synthetic N-thread FFI contention model
#   prepared_cache_bench    — cache hit vs cold prepare, parameterized path
cargo bench --bench cell_reader_bench
cargo bench --bench encoder_bench
cargo bench --bench ffi_contention_bench
cargo bench --bench prepared_cache_bench
```

Baselines are tracked in
[`native/odbc_engine/benches/baselines/README.md`](../native/odbc_engine/benches/baselines/README.md).
The cron workflow [`.github/workflows/native_bench_baseline.yml`](../.github/workflows/native_bench_baseline.yml)
runs the four follow-up benches weekly on a fixed Linux runner and uploads
the Criterion HTML as an artifact (non-blocking, no gating).

Orchestrated Dart benches (loads `.env`, optional compare):

```powershell
python scripts/run_dart_benchmarks.py --protocol --smoke
python scripts/run_dart_benchmarks.py --heavy --rows 5000
python scripts/run_dart_benchmarks.py --rust-micro
python scripts/run_dart_benchmarks.py --harness
python scripts/run_dart_benchmarks.py --crud --compare
# Full local epic (DSN + optional `Produto` table for --heavy):
python scripts/run_dart_benchmarks.py --all
```

`--all` runs protocol tests, Rust micro-benches, harness, CRUD latency
(`--crud`, 5k columnar bulk insert), smoke, heavy, and `--compare` against
`bench_baselines/*.baseline.json` (creates baseline files on first run). After
async runs, the script prints a short
`fallbacksToBlocking` summary per scenario (columnar should trend to **0**
once async encoding reaches the native async path).

Smoke compare tips: async `elapsedMs` is fractional (µs-based) to avoid
int-millisecond quantization on short `SELECT 1` runs. CRUD SELECT scenarios
use 1 warmup + median of 3 timed passes. Prefer `latencyP95Micros` / higher
`ODBC_BENCH_QUERY_COUNT` when judging async worker lanes; wall-clock qps on
24 queries remains noisy across machines.

Rust micro-benches are local guardrails, not CI pass/fail thresholds. The FFI
sync parameter path now borrows caller buffers only for the duration of each
sync call; async calls still copy params into owned memory before handing work
to background threads. Metadata cache hits keep schemas and opaque catalog
payloads behind shared handles internally; the FFI catalog hot path copies the
cached payload directly to the caller buffer without allocating an intermediate
`Vec`. Validate workload-level impact with the DSN-gated `comparative_bench`
when a local driver is available.

`comparative_bench` keeps `select/streaming` as the legacy buffer-materialised
streaming case and adds `select/streaming_batched_drain` for the true batched
streaming path. Treat the former as a compatibility/materialisation signal and
the latter as the bounded-memory streaming signal.

Optional environment knobs:

| Variable | Effect |
| -------- | ------ |
| `ODBC_BENCH_CONNECTION_COUNT` | Async benchmark parallel connections (default 4) |
| `ODBC_BENCH_QUERY_COUNT` | Async benchmark queries per scenario (default 24) |
| `ODBC_BENCH_TABLE` / `ODBC_BENCH_ROWS` | Defaults for `--heavy` when flags omitted |
| `BENCHMARK_MAX_P95_REGRESSION_PERCENT` | Passed to `tool/compare_benchmark_baseline.dart` |
| `BENCHMARK_MAX_FALLBACKS_DELTA` | Max allowed increase in `fallbacksToBlocking` vs baseline |
| `BENCHMARK_COMPARE_STRICT=1` | Fail if current JSON has scenarios not listed in baseline |
| `BENCHMARK_FAIL_ON_CRITERION_REGRESSION=1` | Make `scripts/run_dart_benchmarks.py --rust-micro` fail when Criterion reports "Performance has regressed." |
| `BENCHMARK_SAVE_RUST_MICRO_LOG=1` | Append a second Rust bench run log under `bench_baselines/` |

`PERF_STRICT=1` with `dart test test/performance/` enables an extra timing check
on **P4.1b** (multi-result decoder: 1024-byte chunks vs 17-byte stress).

`benchmarks/m1_baseline.dart` and `benchmarks/m2_performance.dart` use
`benchmark_harness` [`AsyncBenchmarkBase`](https://pub.dev/packages/benchmark_harness)
via shared `benchmarks/odbc_async_benchmarks.dart`:

- **ODBC Init** — repeated `initialize()` after locator setup (later runs are
  often idempotent; local smoke only).
- **ODBC Connect** — one connect + disconnect per iteration (`m2` requires
  `ODBC_TEST_DSN`; `m1` skips connect when DSN is unset).

```powershell
dart run benchmarks/m1_baseline.dart
dart run benchmarks/m2_performance.dart
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

`streaming_performance_benchmark.dart` compares `streamQuery` (batched default
since v4.1.0) and `streamQueryBatched` with the same query and reports elapsed
time, rows, chunks, rows/s, `fetchSize`, and `chunkSize`. Use
`streamQueryBuffer` to exercise legacy buffer-mode `odbc_stream_start`.

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
  --max-regression-percent 30 `
  --max-p95-regression-percent 30 `
  --max-fallbacks-delta 5
```

Async JSON from `example/async_concurrency_benchmark.dart` includes
`queriesPerSecond`, `rowsPerSecond`, `latencyP95Micros`, and
`fallbacksToBlocking` for regression checks. Native pool scenarios also emit
`poolConnectMs` and `poolQueryMs` (checkout vs query time, wall-clock sum across
tasks).

Live `test/my_test` table scans are bounded by default with `SELECT TOP N`.
Use `MY_TEST_ROW_LIMIT` to tune quick local coverage. Use
`RUN_LIVE_TESTS=1` to enable these live tests, and
`MY_TEST_FULL_TABLE_SCAN=1` only for deliberate full-table performance checks.

### Streaming SELECT headroom (Phase 1)

Full-table `streamQueryBatched` measurements in `test/my_test` historically used
**row-major** wire and **64 KiB** FFI `chunkSize`. That combination often splits
a 1000-row wire frame across multiple FFI fetches (extra memcpy /
`BinaryFrameAccumulator` work) even when Dart still yields one logical batch
per ODBC `fetchSize`.

`select_timing_report_test` runs an A/B lane on the live Estacao DB:

| Lane | Encoding | chunkSize | Result (full materialize + rowCount) |
| ---- | -------- | --------- | ------------------------------------ |
| A | row-major | 64 KiB | Best for wide `SELECT *` text schemas (~22–33k rows/s) |
| B | columnar typed | 1 MiB | Slower when every cell is decoded to typed columns (~10–17k rows/s) |

Takeaways:

| Knob | Prefer when | Why |
| ---- | ----------- | --- |
| `chunkSize` | Large scans (often **1–4 MiB**) | Fewer FFI fetch round-trips / resize loops; seed via `streamFetch(bufferSize:)` |
| Columnar / `streamQueryColumnar*` | Analytics pipelines that keep **typed numeric** columns or use `lazyStrings` | Avoids row `List` framing; **not** a free win for full `SELECT *` string/datetime materialization |
| Service `balancedServer` / `highThroughput` | Server apps already on the repository path | Columnar default for **typed** APIs; QueryResult APIs stay row-major wire; recommended stream chunk 1 MiB via `locator.recommendedStreamChunkSizeBytes` |

Standalone `my_test` files default `chunkSize` to **1 MiB** when
`MY_TEST_FULL_TABLE_SCAN=1` (override with `MY_TEST_CHUNK_SIZE_BYTES`).

Dart `streamFetch` seeds the FFI buffer from the stream `chunkSize` so the first
allocation matches the native copy budget (`streamCallWithBuffer(initialSize:)`).

See also `example/recommended_performance_patterns_demo.dart`.

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

To repeat the focused native checks after cache or streaming changes:

```powershell
cargo bench --bench metadata_cache_bench
cargo bench --bench comparative_bench -- select
$env:BENCHMARK_FAIL_ON_CRITERION_REGRESSION="1"
python scripts/run_dart_benchmarks.py --rust-micro
```

---

## Bulk insert performance (Dart)

| Scenario | Prefer | Notes |
| -------- | ------ | ----- |
| Few rows (< ~100) | Prepared `INSERT` in a loop | Setup cost of [BulkInsertBuilder] is negligible; row-by-row is simpler. |
| Medium batches (100–1k rows) | `bulkInsert` / `bulkInsertArray` on one connection | Build the payload once with [BulkInsertBuilder.build]; pass the [Uint8List] directly to FFI (no extra copy). Prefer columnar `addColumnInt32` / `addColumnText` when source data is already column-shaped — avoids per-row `List<dynamic>` and bulk-copies `Int32List`/`Int64List` into the wire buffer. |
| Large batches (> ~1k rows) | `bulkInsertParallel` via [ConnectionPool] | Pool-backed parallel insert splits work across native workers. Size the pool to at least your target `parallelism` (often 4). |
| Analytics SELECT (many rows, stable types) | `ResultEncoding.columnar` | Reduces row framing overhead; benchmark before adopting in production. |
| Repeated statements | Prepared statement reuse | Keep one prepared handle per SQL shape; rebinding is cheaper than re-preparing. |

[BulkInsertBuilder.build] uses the same two-pass strategy as [serializeParams]:
phase 1 pre-encodes variable-width cells and computes the exact payload size;
phase 2 writes into a single pre-sized [Uint8List]. This avoids [BytesBuilder]
growth copies and an extra `Uint8List.fromList` at the FFI boundary.

Local benchmarks:

```powershell
# CRUD latency incl. columnar bulk build vs FFI split and pool parallel insert
$env:RUN_PERF_TESTS="1"
dart test test/performance/crud_latency_benchmark_test.dart --reporter expanded

# Emit/compare baseline JSON (5k columnar bulk scenarios)
python scripts/run_dart_benchmarks.py --crud --compare
# or manually:
$env:RUN_PERF_TESTS="1"
$env:BENCH_BASELINE_OUT="bench_baselines/crud-produto-5k.baseline.json"
dart test test/performance/crud_latency_benchmark_test.dart --reporter expanded

# Deterministic BulkInsertBuilder micro-benchmark (no DSN)
dart test test/performance/protocol_performance_test.dart
```

Example for parallel bulk insert: `example/bulk_insert_parallel_demo.dart`.

### Mass UPDATE / DELETE

Prefer **set-based SQL** (`UPDATE … WHERE …`, `DELETE … WHERE …`, or
dialect-specific batch statements) over prepared-statement loops when changing
many rows. Each prepared execution pays bind and round-trip overhead; the engine
is optimized for bulk insert and fetch paths, not row-by-row DML. Wrap large
changes in a transaction, use selective `WHERE` predicates, and consider
staging tables plus `MERGE` / `INSERT … SELECT` patterns when your dialect
supports them.

---

## Concurrency

| Design decision                                                                               | Reasoning                                                                                                                                                                                                                                  |
| --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `odbc_pool_get_connection` releases the global state mutex before calling `r2d2::Pool::get()` | Without this, every concurrent FFI call serialised behind slow pool checkouts (up to 30 s). Throughput under contention now scales close to `r2d2.max_size`.                                                                               |
| `odbc_pool_close` drains live checkouts before removing the pool entry                        | Prevents a deadlock when other threads still hold pooled connections at shutdown.                                                                                                                                                          |
| `ConnectionPool::get` runs one `pool_session_reset` per checkout                              | r2d2 `on_acquire` only runs after `connect`, not on idle checkout. Resetting in `get` keeps sessions clean even when `test_on_check_out` is false. `is_valid` runs the health query only so validation does not double the reset.         |
| `recv_timeout` + structured worker-disconnect error                                           | Converts an indefinite hang into an explicit `WorkerCrashed` error so the consumer can recover.                                                                                                                                            |
| `read_exact` in disk-spill readback                                                           | Eliminates silent short-read truncation on Windows for large spills with no happy-path cost.                                                                                                                                               |
| `Mutex<GlobalState>` granularity                                                              | Critical paths (pool checkout, metrics, audit, per-connection errors, async requests, legacy global error) are off the outer mutex. Connection, pool, transaction, stream, statement, and XA maps live in dedicated `ffi::state::*` shards. Residual `GlobalState` owns only `env` (+ optional BCP connection strings). |
| Async presets via `ServiceLocator.initialize(profile: ...)`                                   | Default profile remains `legacy` for compatibility. Opt in to `balanced` for `workerCount = 2`, `maxPendingRequests = 24`, `backpressureMode = waitForSlot`, and `backpressureTimeout = 30s`; use another `OdbcUsageProfile` when the app shape is clearer. |
| Direct `AsyncNativeOdbcConnection(...)` defaults                                              | Constructor defaults remain `workerCount = 1`, `maxPendingRequests = null`, and `backpressureMode = failFast`. Use `ServiceLocator` presets when you want profile-guided tuning instead of raw constructor defaults.                      |
| Async backpressure (`maxPendingRequests` / `asyncMaxPendingRequests`)                         | In services with native pools, keep the pending cap near `poolSize * 2` to `poolSize * 4` so the Dart worker queue does not hide saturation.                                                                                              |
| Worker isolates instead of raw threads                                                        | Dart consumers should scale with `workerCount` / `asyncWorkerCount`, not hand-spawn raw isolates around one connection. More workers only reduce bottlenecks when work can be routed across multiple connections or native-pool checkouts. |

### Native pool checkout cost and tuning

Default checkout path (`test_on_check_out = true`):

1. Optional health query (`SELECT 1`, or `Health_Check_Query` / `ODBC_POOL_HEALTH_CHECK_QUERY`)
2. One `pool_session_reset` in `ConnectionPool::get` (rollback + lock-timeout restore + autocommit)

Checkin still resets before returning the connection to the idle set.

For trusted low-latency pools where the health round-trip dominates, disable
validation with `Pool_Test_On_Checkout=false` in the DSN (aliases:
`test_on_check_out`, `TestOnCheckout`, …) or `ODBC_POOL_TEST_ON_CHECKOUT=0`.

To also skip **checkout** session reset (rollback / lock-timeout / autocommit),
set `PoolOptions(sessionResetOnCheckout: false)`, DSN `Pool_Session_Reset=false`,
or `ODBC_POOL_SESSION_RESET=0`. Prefer this only for trusted pools that never
leave open transactions or session overrides. **Checkin reset remains
unconditional.**

`poolHealthCheck` still performs a full r2d2 `pool.get()` (runs the health
query when `test_on_check_out` is on; it does not go through
`ConnectionPool::get`'s session reset). Prefer `poolGetState` /
`poolGetStateDetailed` for frequent monitoring.

---

## Choosing a concurrency path

| Workload                                          | Prefer                                                                                                     | Notes                                                                                                                                                             |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Many independent short/medium queries             | `AsyncNativeOdbcConnection(workerCount: N)`                                                                | Open multiple connections. Same-connection calls remain serialized. See `example/high_concurrency_worker_pool_demo.dart`.                                         |
| Many request-style tasks with bounded DB capacity | Native pool + `ServiceLocator.initialize(profile: OdbcUsageProfile.balancedServer/highThroughput)` | Keep an explicit in-flight limit close to pool size. Set `maxPendingRequests` near `poolSize * 2` or `poolSize * 4`. See `example/high_concurrency_pool_demo.dart`. |
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

## Zero-copy FFI result buffers (v4.1.0, safe subset)

| Knob | Value | Effect |
| ---- | ----- | ------ |
| `zeroCopyResultThresholdBytes` | `32 KiB` | `callWithBuffer` skips the `Uint8List.fromList` copy for successful payloads at or above this size when `odbc_release_buffer` resolves (ABI **1.1+**). Sync param paths with large directed blobs use a transient allocation via `preferTransientFfiBufferForParams`. |
| Scratch pool | seeds `< 256 KiB` | Reusable scratch buffers still copy on return because the pool reuses memory on the next FFI call. Transient + zero-copy when `preferTransient` or `initialSize >= 256 KiB` (not gated on the 16 MiB max ceiling). |
| `odbc_release_buffer` | exported | C ABI hook for releasing Dart `malloc` buffers; Dart uses the paired `malloc.nativeFree` finalizer today. |

Opt-out is automatic on older native builds that do not export the symbol — the helper falls back to copying.

---

## Async parameter isolate transfer (v4.1.0)

Worker requests that carry serialized parameter blobs (`ExecuteQueryParamsRequest`,
`ExecutePreparedRequest`, `ExecuteQueryMultiParamsRequest`,
`ExecuteAsyncStartParamsRequest`) use the same `TransferableTypedData` threshold
as bulk insert (`isolateTransferablePayloadThresholdBytes`, 32 KiB). Factory
helpers (`*.withSerializedParams`) avoid an extra isolate copy for large directed
parameter buffers on the async worker path.

---

## SQL Server native BCP (`sqlserver-bcp` feature)

| Item | Detail |
| ---- | ------ |
| Feature gate | `sqlserver-bcp` on `odbc_engine` (not in default features). Enables dynamic loading of vendor `bcp_*` symbols and the native `BulkCopyExecutor` fast path for SQL Server. |
| Dart / build | Rebuild the native asset with `--features sqlserver-bcp` (or enable the feature in your hook/CI matrix). Without it, bulk insert stays on the portable `ArrayBinding` path. |
| Runtime guard | Native BCP is **disabled at runtime** unless `ODBC_ENABLE_UNSTABLE_NATIVE_BCP=1` (or `true` / `yes`). **`supports_native_bcp`** is surfaced in `odbc_get_driver_capabilities` JSON; combine with `isNativeBcpAvailable` / `isUnstableNativeBcpEnabled` in `native_bcp_runtime.dart`. |
| Text columns | Native path supports `BulkColumnType::Text` (`SQLCHARACTER`) in addition to `I32` / `I64`. |
| Scope | Row-at-a-time native BCP for supported scalar types; full payload is still materialised in-engine (streaming BCP remains open work). |

---

## `streamQueryColumnar` and native columnar batched wire (v4.2)

`IQueryService.streamQuery` / `streamQueryNamed` / `streamQueryMulti` always
request **row-major** wire even when `ServiceLocator` / repository
`defaultResultEncoding` is columnar. That avoids rematerializing typed columns
into `QueryResult` row lists on server profiles. Prefer
`streamQueryColumnar*` (or `executeQueryColumnarParamValues`) when you want
columnar end-to-end. Low-level `streamStartAsync` follows the same row-major
policy.

For `streamQuery` / `streamQueryNamed` / `streamQueryColumnar`, optional
`fetchSize` (default 1000) and `chunkSize` (default 64 KiB) forward to batched
native start; each fetch seeds the FFI buffer with `bufferSize: chunkSize`
(async and sync). For `streamQueryMulti`, the same knobs forward to
`odbc_stream_multi_start_*_options` when available; older natives without the
options symbol keep the legacy entry (engine default fetch 100).
Wire tag 2 (continuation batch of the same SQL cursor) is coalesced in the
repository runner into one `QueryResultMultiItem` so stream item counts match
`executeQueryMultiFull` (growable row list — no per-batch `List.of` when the
list is already growable). Async
backends use `streamMultiStartAsync` + `streamPollAndFetch` (one isolate hop
when ready).

No-param `executeQuery` is a **one-shot** `execQuery` / empty-params path (not a
drained batched stream). Use `streamQuery*` for incremental delivery of large
results.

Columnar float/double decode builds `TypedColumnFloat64` (`Float64List`) from
UTF-8 wire text. Native binary scalar cells (float/bool/date on the wire) remain
a future protocol-version follow-up.

Batched stream framing (`ProtocolByteAccumulator.take`) transfers frame ownership
via views so drain loops avoid an extra `fromList` copy per message.

`IQueryService.streamQueryColumnar` / repository `streamQueryColumnar` call
`odbc_stream_start_batched_options` with `ResultEncoding.columnar` when the
loaded native library exports that symbol (v4.2+). Each batched chunk is a
columnar v2 protocol message decoded to `TypedColumnarResult` via
`parseColumnarToTyped`. Older natives that lack the options symbol fail with
`UnsupportedFeatureError` when columnar encoding is requested.

For a single-shot buffered query with native columnar encoding, use
`executeQueryColumnarParamValues` (`ResultEncoding.columnar`). Repository
extensions expose `streamQueryColumnarNative` as an explicit alias.

Buffered parsers (`parseBufferToQueryResult`, `MultiResultParser`) honor
`ConnectionOptions.lazyStrings` the same way streaming paths do.

Multi-result streaming (`odbc_stream_multi_*`) encodes each cursor in
fetch-sized batches. Tag `0` opens a result set; tag `2` continues the same
result set; tag `1` is row count. Dart `MultiResultStreamDecoder` preserves
frame boundaries (`isContinuationBatch` on tag 2); `streamQueryMulti`
coalesces tag-2 batches into one logical `QueryResultMultiItem` per cursor.

---

## Safety / correctness

| Decision                                                            | Reasoning                                                                                                                              |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `ffi::guard::call_int*` / `call_id*` / `call_ptr*` + `catch_unwind` | Single `catch_unwind` per FFI call (~tens of ns); converts Rust panics into stable error codes (`FfiError::Panic = -4`) instead of UB. |
| `quote_identifier_default` in `Savepoint` and `ArrayBinding`        | One validation per identifier, allocation-free; prevents SQL injection via identifiers.                                                |

---

## Known open work (active tracking)

These performance-sensitive items are tracked outside the feature backlog:

- **Single-result streaming (audit C7, resolved in v4.1.0)** — `streamQuery` and repository `streamQuery` now default to cursor-based batched streaming (`odbc_stream_start_batched` / `execute_streaming_batched`). Legacy buffer-mode `odbc_stream_start` / `execute_streaming` remains for `streamQueryBuffer` and spill-to-disk only; it still materialises the full result before byte-level FFI chunking.
- **Multi-result per-cursor materialisation (resolved in v4.2)** — `odbc_stream_multi_*` encodes each cursor in fetch-sized batches (tag `0` + tag `2` continuation frames). Memory stays bounded to one batch per active cursor.
- **Residual `GlobalState`** — delivered: maps for connections, pools,
  transactions, streams, statements, and XA branches are sharded under
  `ffi::state::*`. Residual `GlobalState` holds only `env` (+ optional BCP
  connection strings). Cross-category cleanup still nests locks in the
  documented order (`GLOBAL_STATE` → xa → transactions → pools → …).
- **BCP / array-binding streaming** — bulk insert via `BulkCopyExecutor` and `ArrayBinding` does not stream; the full payload is materialised in the Rust engine. Prefer `bulkInsertParallel` with bounded row batches from the Dart side until native streaming BCP lands.
- **Native binary scalars on wire** — `Float`/`Double`/`Boolean` now emit
  little-endian / single-byte payloads on the cell path (dual-support with
  legacy UTF-8 text in Dart). Date/time remain ISO text; a fixed-layout
  `ColumnData::Float64` columnar kind remains a separate follow-up.

Feature-level open work is tracked in
[`Features/PENDING_IMPLEMENTATIONS.md`](Features/PENDING_IMPLEMENTATIONS.md):

- **Columnar v2 default decision** - `ResultEncoding.columnar` and
  `ResultEncoding.columnarCompressed` are available, but row-major v1 stays the
  default until live workload benchmarks justify switching.
- **Live E2E / driver certification** - MSDTC, Oracle ref cursor and directed
  `OUT` coverage remain host-side opt-in because they depend on local drivers,
  DSNs and database privileges.
