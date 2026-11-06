# Performance & Reliability Notes

## Compression scratch reserve follow-up (2026-11-06)

The small compressed-batch regression reported in the previous section below
is addressed by reserving a bounded 8 KiB raw scratch buffer on the first
nonempty compressed frame. Existing workspaces reuse their capacity; empty
frames do not allocate scratch. Uncompressed sizing and payload serialization,
zstd level, compression threshold, fallback decisions, wire bytes and ABI are
unchanged. This trades a larger initial scratch capacity for fewer reallocations:
small payloads may retain 8 KiB instead of a smaller buffer until the workspace
is dropped. Large payloads still grow normally.

`columnar_compression_allocation_test` failed before the change with eight
allocation/reallocation calls and passes afterward with a budget of at most two
(output and scratch). Byte-exact tests cover NULL distributions, threshold
boundaries, workspace reuse, reserved output prefixes and empty frames.

Separate sequential Criterion processes on Windows x64 / Rust 1.93.0 used
logical processor 2 (affinity mask 4), AboveNormal priority, the release-equivalent
bench profile, 1-second warmup, 3-second measurement and 40 samples. The original
encoder, the preceding columnar optimization and this follow-up used the same
`encoder/streaming_columnar_compressed/16x100x8` fixture:

| Version | Forward time (us) | Reverse-order time (us) |
| --- | ---: | ---: |
| Original encoder | 597.60 | 589.12 |
| Previous columnar optimization | 579.76 | 591.87 |
| Scratch reserve follow-up | 556.95 | 547.58 |

The follow-up is about 7% faster than the original in both orders, removing
the observed small-batch regression. Its 95% intervals are 553.20-560.14 and
544.53-550.39 us, versus 587.44-608.41 and 580.29-599.72 us for the original.
Long separate-process control runs showed substantial drift, so those controls
were also checked with a paired experiment rather than treated as precise deltas.

`native/odbc_engine/examples/compression_paired_bench.rs` alternates the reference
and production encoders within each pair in one process. The reference reproduces
the pre-reserve orchestration using the same production framing, payload and zstd
helpers; it isolates the scratch allocation change, rather than comparing two
entire DLLs. Every fixture's bytes are compared before timing. Twenty warmup
pairs precede 101 measured pairs, with alternating order. Setup is outside timing;
encoding, allocation and result disposal are inside it. A deterministic bootstrap
(10,000 paired resamples, seed 20261106) estimates the median speed ratio.

The standalone release example was run twice with the same affinity and priority.
Ratios above 1 favor the follow-up; intervals are local 95% bootstrap intervals:

| Scenario | First paired speed ratio [95% interval] | Repeat [95% interval] |
| --- | ---: | ---: |
| Compressed, 100 rows x 8 columns | 1.02725 [1.02483, 1.02972] | 1.03190 [1.02752, 1.03388] |
| Compressed, 1,000 rows x 8 columns | 1.00760 [0.98785, 1.03725] | 0.99209 [0.97950, 1.02983] |
| Uncompressed numeric, dense | 0.99414 [0.97728, 0.99911] | 0.99157 [0.96919, 1.01170] |
| Uncompressed numeric, partial NULLs | 0.99696 [0.98055, 1.00856] | 1.01122 [0.98480, 1.02451] |
| Uncompressed numeric, all NULLs | 1.00171 [0.99841, 1.00582] | 1.00278 [0.99784, 1.00582] |
| Uncompressed mixed, 1,000 rows x 10 columns | 0.99893 [0.99752, 1.00231] | 0.99978 [0.99644, 1.00467] |

The small compressed case improves consistently by about 3%. No speedup is
claimed for larger compressed batches or uncompressed controls. The dense
control had a small 0.6-0.8% central slowdown; its first interval excluded 1,
but the repeat did not. There is no consistently significant control regression
across both runs, and the earlier uncompressed optimizations remain unchanged.
These component measurements do not imply database-throughput gains.

```powershell
cargo run --manifest-path native/Cargo.toml --release --locked --offline --example compression_paired_bench
```

## Rust columnar payload encoding (valid data, 2026-11-06)

Numeric payload sizing counts non-NULL cells, then checks the multiplication
and total length once, instead of performing checked additions for each cell.
The private payload writer now uses `Vec<u8>` directly: both its production
callers already provide vectors. Variable-width length checks and serialization
order remain unchanged. No public signatures, FFI symbols or layouts changed.

New tests compare complete numeric payloads and declared lengths against
independent expected bytes for empty, dense, partially NULL and all-NULL columns,
including integer extrema and several sizes around small vector boundaries.
A separate byte-exact test covers varchar/binary NULLs, empty values, arbitrary
bytes and Unicode, with compression enabled and disabled. Existing compressed
and golden-file tests remain in the suite.

The added `encoder/numeric_columnar` benchmark encodes two columns (Integer and
BigInt), each with 100,000 rows. Partial-NULL fixtures have one NULL per five
rows. Fixtures are constructed outside the timer; encoding, result allocation
and result disposal are measured. Existing mixed-type and compressed benchmarks
provide controls. The encoder baseline is from revision
`322fc1418bee76da8d28bab4bb5f02ac357f0b71`; the same benchmark harness was compiled
against the original and revised encoder.

Windows x64, Rust 1.93.0, repository bench profile (fat LTO, one codegen unit,
optimization level 3). Each scenario ran in a separate process, sequentially,
with no concurrent builds/tests: 1-second warmup, 3-second measurement and 40
samples, followed by the reverse execution order. Criterion central estimates:

| Scenario | Before / after (us) | Reverse-order before / after (us) |
| --- | ---: | ---: |
| Numeric, no NULLs | 538.06 / 464.64 | 584.96 / 554.44 |
| Numeric, 20% NULLs | 472.54 / 423.38 | 563.71 / 482.26 |
| Numeric, all NULLs | 203.98 / 148.54 | 206.27 / 151.40 |
| Mixed types, 1,000 rows x 10 columns | 26.684 / 24.548 | 27.369 / 23.621 |
| Compressed, 16 batches x 100 rows x 8 columns | 357.47 / 364.31 | 356.39 / 358.62 |

Uncompressed gains repeated in both orders: about 5-14% less time for dense
numeric data, 10-14% for partial NULLs, 27% for all NULLs and 8-14% for mixed
types. Reverse-order 95% intervals (before / after, us): dense 566.71-598.87 /
551.88-557.03; partial NULLs 558.33-569.70 / 479.91-485.46; all NULLs
205.22-207.34 / 150.25-152.59; mixed types 27.176-27.594 / 23.520-23.723.

The compressed control was 0.6-1.9% slower; its reverse-order intervals overlap
(354.83-357.99 / 357.52-359.85 us). No compression speedup is claimed. These
results measure encoding only, not database query throughput.

```powershell
cargo bench --manifest-path native/Cargo.toml --locked --offline --bench encoder_bench -- 'encoder/numeric_columnar/dense$' --warm-up-time 1 --measurement-time 3 --sample-size 40 --noplot
```

## Rust row-to-column conversion (valid data, 2026-11-06)

The converter now reserves space for the known row count after clearing each
destination column. This avoids incremental vector growth on fresh or growing
batches while retaining existing allocations for subsequent smaller batches.
The change applies to integer, bigint, varchar and binary columns in the
fallback streaming converter and bulk columnar encoding. It does not change
public signatures, ABI, wire bytes, NULL handling or numeric validation.

The added byte-equivalence test builds expected columns independently and checks
compressed and uncompressed output across batch sizes 0, 1, 17, 4097, 3, 0 and
501, including NULLs, Unicode, empty binary values and heap-backed binary cells.
It passed both before and after the optimization.

The `transpose_capacity` group in `fallback_transpose_bench` uses Criterion
`iter_batched`: input cloning occurs outside the timed routine; conversion and
destruction of the consumed row buffer occur inside it. Output destruction is
outside the timed routine. Mixed fixtures contain integer and 128-byte binary
columns; numeric fixtures contain integer and bigint columns. Both include
NULLs. No database is involved.

Windows x64, Rust 1.93.0, repository bench profile (fat LTO, one codegen unit,
optimization level 3), 1-second warmup, 2-second measurement, 30 samples. The
baseline converter is from revision
`322fc1418bee76da8d28bab4bb5f02ac357f0b71`. Binaries using the same benchmark
harness before/after the source change ran sequentially, then in reverse order with
each scenario in its own process. Criterion central time estimates:

| Scenario | Before / after | Reverse-order before / after |
| --- | ---: | ---: |
| Mixed, 1,000 rows | 29.322 / 20.562 us | 27.460 / 22.012 us |
| Mixed, 10,000 rows | 303.32 / 209.82 us | 292.05 / 291.24 us |
| Numeric, 10,000 rows | 268.97 / 216.24 us | 283.89 / 241.37 us |

The 1,000-row mixed case reduced time by 20-30%; the numeric case by 15-20%.
Reverse-order 95% intervals were 25.311-29.809 / 21.281-22.682 us (mixed 1,000)
and 265.56-310.33 / 232.66-250.16 us (numeric 10,000). The larger mixed case did
**not** show a repeatable improvement and is not counted as a confirmed gain.
The existing reused-buffer benchmark (16 batches of 1,000 rows, including input
cloning and encoding) measured 1.4163 / 1.3931 ms, with no indicated regression.
These are component measurements, not a claim about database throughput.

```powershell
cargo bench --manifest-path native/Cargo.toml --locked --offline --bench fallback_transpose_bench -- transpose_capacity --warm-up-time 1 --measurement-time 2 --sample-size 30 --noplot
```

## Rust decoder framing validation (local measurement, 2026-11-06)

`BinaryProtocolDecoder::parse` now checks the declared payload length before
allocating metadata or rows. Previously, a 16-byte header declaring one million
zero-column rows and one missing payload byte allocated 24,000,000 bytes before
returning `ValidationError`. The allocation regression test fails on the old
implementation and requires every allocation during rejection to stay below
1 KiB. Valid zero-column rows remain supported.

Public signatures, wire layout, FFI exports and accepted valid inputs are
unchanged. For inputs with multiple defects, a payload-size mismatch now takes
precedence over malformed metadata or cells. Tests for those deeper errors use
correct framing so that they still exercise their intended validation.

`native/odbc_engine/benches/decoder_validation_bench.rs` measures this invalid
header, a valid empty result and 1,000 valid NULL rows. Run each scenario in a
separate process using its name as a Criterion filter; a preceding allocation
stress case can affect the allocator state of later scenarios. Fixtures are
built and their success/error outcomes checked outside the timed loop.

The baseline decoder is from revision
`322fc1418bee76da8d28bab4bb5f02ac357f0b71`; the benchmark is identical in both
builds. Measurements use Windows x64, Rust 1.93.0 and the repository's release
equivalent bench profile (fat LTO, one codegen unit, optimization level 3).
These measurements concern a Rust decoder component, not database throughput.

Separate sequential processes used 1 second of warmup, 2 seconds of measurement
and 30 samples per scenario, then repeated in reverse order. Criterion time
estimates (central estimates, not end-to-end latency):

| Scenario | Before / after | Reverse-order before / after |
| --- | ---: | ---: |
| Invalid header, 1,000,000 declared rows | 9.3452 ms / 70.049 ns | 9.4474 ms / 66.737 ns |
| Valid empty result | 13.966 ns / 14.404 ns | 21.987 ns / 13.949 ns |
| Valid 1,000 NULL rows | 38.339 us / 36.762 us | 37.070 us / 36.069 us |

For the invalid header, forward 95% intervals were 9.2817-9.4115 ms before and
67.461-73.111 ns after; reverse intervals were 9.3657-9.5329 ms and
66.122-67.346 ns. The improvement is specific to avoiding allocation and traversal
before rejecting invalid framing. Valid-input timings do not establish a
general throughput improvement: the empty-result case changed direction between
runs, including a small slowdown in the forward run.

Reproduce each scenario independently, for example:

```powershell
cargo bench --manifest-path native/Cargo.toml --locked --offline --bench decoder_validation_bench -- invalid_million_rows --warm-up-time 1 --measurement-time 2 --sample-size 30 --noplot
```

## Named parameter parsing (local measurement, 2026-11-06)

The parser copies unchanged SQL spans instead of rebuilding them character by
character, dispatches special tokens by code unit, and keeps cache hits in a
small entry method. Cache capacity, insertion-order eviction, immutable name
lists, placeholder order, signatures and exception contracts are unchanged.

Bracket-escaped identifiers also remain intact: `SELECT [x]]:hidden], :visible`
now produces `SELECT [x]]:hidden], ?`, with only `visible` as a parameter.
The previous implementation incorrectly replaced `:hidden`. This follows
[SQL Server identifier escaping](https://learn.microsoft.com/en-us/sql/relational-databases/databases/database-identifiers).
Regression tests failed before the fix and now cover escaped identifiers,
Unicode, nested comments, dollar quoting and unterminated segments.

`benchmarks/named_parameter_benchmark.dart` builds SQL outside the timed loop,
uses eight warmups and 21 measured samples, and validates parameter counts.
Cold scenarios cycle through 512 distinct queries, exceeding the 256-entry
cache; the warm scenario cycles through 128. Separate sequential JIT processes
compared the original source with the final implementation, then reversed the
order. Output checksums matched. Environment: Windows x64, Dart 3.13.5.
The original parser was taken from revision
`322fc1418bee76da8d28bab4bb5f02ac357f0b71`.

| Scenario | Calls per sample | Before / after median (ms) | Reverse-order before / after (ms) |
| --- | ---: | ---: | ---: |
| Cold, 96 columns, no parameters | 4,096 | 71.516 / 13.769 | 73.561 / 13.432 |
| Cold, 96 columns, two parameters | 4,096 | 77.853 / 15.927 | 75.321 / 15.780 |
| Cold, 96 parameters | 4,096 | 40.182 / 30.808 | 38.744 / 31.343 |
| Warm cache, one parameter | 524,288 | 7.740 / 5.748 | 7.046 / 5.668 |

Independent bootstrap resampling of the medians (5,000 resamples, initial seed
20261106) gave reverse-order 95% speedup intervals of 5.12-5.72, 4.65-4.86,
1.22-1.27 and 1.17-1.27 respectively. Both execution orders favored the revision
in all four scenarios; these intervals describe this local sampling only.

These are parser microbenchmarks, not database throughput measurements. Keep
timings separate from correctness assertions to avoid machine-dependent tests.

## Parameter decoding (local measurement, 2026-11-06)

`deserializeParamValue` now reads lengths relative to the supplied byte view,
including nonzero `offsetInBytes`. Batch decoding shares one `ByteData` view
and scalar decoding no longer allocates unused payload views. Public signatures,
wire tags, returned values and binary payload sharing remain unchanged.

Run `benchmarks/param_decode_benchmark.dart` with the project package config.
The harness builds inputs outside the timer, performs eight warmups and records
21 samples per scenario, retaining a checksum of decoded output. The comparison
used the original decoder and the revised decoder in separate sequential JIT
processes, then repeated with their order reversed. Windows x64, Dart 3.13.5.

| Scenario | Calls per sample | Before / after median (ms) | Reverse-order before / after (ms) |
| --- | ---: | ---: | ---: |
| One integer | 100,000 | 4.303 / 3.545 | 4.319 / 2.788 |
| 256 integers | 2,000 | 23.362 / 7.831 | 19.939 / 7.175 |
| 256 mixed integer/text/null/decimal values | 2,000 | 25.697 / 19.008 | 22.364 / 16.306 |

The integer batches were 2.78-2.98 times faster and mixed batches 1.35-1.37
times faster in these runs. These are decoder microbenchmarks, not end-to-end
database throughput claims. Timing is reported separately from correctness
tests to avoid a machine-dependent pass/fail threshold.

Regression coverage is in `param_value_decode_view_test.dart`: all wire tags,
offsets, truncated views whose backing buffer still contains the missing bytes,
and binary payload sharing. Eight offset cases failed on the original decoder
with `FormatException` before the fix.

This document records architectural decisions with a measurable performance or reliability impact. Dated measurements below are historical snapshots; run the benches locally for your workload. Consumer-facing typical numbers live in the README **Performance quick reference**; native Criterion snapshots live in [`native/doc/performance_comparison.md`](../native/doc/performance_comparison.md).

---

## Native engine fetch and prepared cache (current defaults)

| Knob | Default | Effect |
| ---- | ------- | ------ |
| `block-cursor-fetch` feature | **enabled** | Cursor fetch goes through `engine::core::block_fetch::fetch_rows_into` (`BlockCursor` + `ColumnarAnyBuffer`) for queries whose columns can all be pre-bound. LOBs / `WLONGVARCHAR` without an advertised max length transparently fall back to the legacy per-row path. |
| `statement-handle-reuse` feature | **enabled** | `CachedConnection` keeps a per-connection LRU of `OwnedPreparedStatement` (RAII guard around the `mem::transmute` that fabricates the `'static` lifetime). Legacy parameters without NULL, or with a NULL type inferable from non-NULL siblings, use the prepared cache; descriptor-dependent and directed parameter paths still prepare directly. Repeated MULT streams also reuse prepared statements, but evict the entry on any failure, cancellation, or abandoned delivery. **Pooled** checkouts retain the cache in r2d2. |
| `ODBC_FAST_BLOCK_FETCH_BATCH` env var | `256` | Batch size for `BlockCursor::fetch_with_truncation_check`. Invalid or missing values fall back to the default. Cached via `OnceLock`, so `std::env::var` is not consulted per query. |

Transaction begin applies settings through the existing connection reference,
without evicting prepared statements. On commit or rollback, `CachedConnection`
queries `SQL_CURSOR_COMMIT_BEHAVIOR` and `SQL_CURSOR_ROLLBACK_BEHAVIOR` once per
physical connection. `SQL_CB_CLOSE` and `SQL_CB_PRESERVE` retain idle prepared
plans; `SQL_CB_DELETE`, unknown values and probe failures evict them. An
unrestricted mutable connection access still evicts the cache and invalidates
the capability snapshot. A failed completion makes the connection unusable.
Session-scoped isolation changes on SQL Server, SQLite and DB2 are reset to
their documented defaults after completion or pool reset; non-default
isolation adds one reset statement on those engines. Arbitrary settings made
by application SQL are not captured.

Pool checkin uses `SQL_ATTR_CONNECTION_DEAD` for a cheap liveness check. Drivers
that explicitly do not support that attribute use the configured health query.
An explicit pool health check always validates, including when checkout
validation is disabled. Checkout and release reservations prevent resize from
publishing a replacement pool while acquisition or cleanup is in progress.

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
Synchronous query/parameter/MULT result bytes and pending `-2` retries are
copied after releasing their respective map mutexes. Pooled busy accounting
remains reserved through result publication (including an error or pending
payload stash). Each connection still has its own ODBC mutex, so concurrent
queries on one connection serialize; distinct connections can copy results
without the outer mutex. Pending retry keys and their two-second TTL are
unchanged. Expired, replaced and cleared pending payloads are detached before
destruction; stream close/disconnect also releases encoded buffers and spill
files after unlocking the shared stream map.

With block fetch enabled, row-major streaming keeps at most one batch of
empty row vectors for reuse. Cells and their text/binary allocations are
released after each batch. The final partial batch and empty cursor expose
only valid current rows. Columnar compressed streaming reuses per-cursor raw
and compressed scratch buffers plus a zstd context; every column still emits
an independent frame. LOBs and FOR JSON continue through the legacy fetch
path when block binding is unsuitable. Columnar fallback keeps typed vectors,
metadata and the compression workspace for the cursor's lifetime; its
row-major row vectors are also recycled between batches.

Batched and MULT streams return fully copied output buffers to a private,
non-blocking per-stream pool. At most two idle buffers with capacity up to
8 MiB each are retained. Larger buffers are released, and Rust calls that
transfer an owned `Vec` keep that ownership with the caller.

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
`streamQueryColumnar` / `streamQueryMulti` / `streamQueryMultiBatches`
signature defaults remain 64 KiB —
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

FFI scratch vs transient: seeds below 32 KiB reuse the scratch pool; seeds at
or above 32 KiB (or `preferTransient`) use transient allocation so successful
payloads can be exposed zero-copy. The shared byte scratch (params + small
bulk frames) and
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
#   ffi_contention_bench    — synthetic N-thread FFI contention model (not an ODBC throughput measurement)
#   prepared_cache_bench    — cache hit vs cold prepare, parameterized path
#   buffer_recycle_bench    — fresh vs reused output buffer, including FFI copy
#   fallback_transpose_bench — one-shot vs reused row-to-column transposition
#   stream_param_decode_bench — copied vs borrowed FFI parameter payload
cargo bench --bench cell_reader_bench
cargo bench --bench encoder_bench
cargo bench --bench ffi_contention_bench
cargo bench --bench prepared_cache_bench
cargo bench --bench buffer_recycle_bench
cargo bench --bench fallback_transpose_bench
cargo bench --bench stream_param_decode_bench
```

For actual SQL Server FFI and streaming hot paths (read-only queries against
`sys.all_objects`), set `ODBC_LIVE_BENCH=1` and `ODBC_TEST_DSN` in the process
environment, then run `cargo bench --bench live_hotpaths_bench`. This covers
1/4/8 distinct connections, 100/1,000-row batched streams, repeated MULT,
and numeric/blob parameters with inferable NULL. The fixture is opt-in and
skips parameter cases rejected by the configured driver. It is not a
before/after comparison unless run against both revisions with the same
driver, server, features and fixture; results from the present revision alone
must not be claimed as an improvement.
The `row_major_100_sustained` group creates its worker threads and 1 MiB
output buffers before timing; each measured iteration runs ten queries per
connection and includes only barrier synchronization plus the production FFI
calls. The original `row_major_100` group includes thread creation and
output allocation and should not be interpreted as steady-state throughput.
Criterion sampling and duration for this bench can be set on the command line;
the benchmark no longer overrides those settings.

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
| `fetchSize: 1000` + `chunkSize` 1 MiB | Large scans | The async Result-service pattern in `example/streaming_demo.dart` uses the server profile chunk recommendation and processes one batch at a time. |
| `chunkSize` | Large scans (often **1–4 MiB**) | Fewer FFI fetch round-trips / resize loops; seed via `streamFetch(bufferSize:)` |
| Columnar / `streamQueryColumnar*` | Analytics pipelines that keep **typed numeric** columns or use `lazyStrings` | Avoids row `List` framing; **not** a free win for full `SELECT *` string/datetime materialization |
| Row-major `streamQueryBatched` | Wide `SELECT *` | Local `Produto` scans stay near ~19k rows/s; the 300–650k rows/s lane is a narrow bench table |
| Service `balancedServer` / `highThroughput` | Server apps already on the repository path | Columnar default for **typed** APIs; QueryResult APIs stay row-major wire; recommended stream chunk 1 MiB via `locator.recommendedStreamChunkSizeBytes` |
| `bulkInsertParallel` (pool ×4) | Inserts above ~1k rows | About 3× single-connection array binding on the local comparative bench |

Standalone `my_test` files default `chunkSize` to **1 MiB** when
`MY_TEST_FULL_TABLE_SCAN=1` (override with `MY_TEST_CHUNK_SIZE_BYTES`).

Dart `streamFetch` seeds the FFI buffer from the stream `chunkSize` so the first
allocation matches the native copy budget (`streamCallWithBuffer(initialSize:)`).

See also `example/recommended_performance_patterns_demo.dart`.

### Test categories and flags

Use [Test policy: canonical opt-in environment variables](TESTING.md#canonical-opt-in-environment-variables)
for suite gates. Benchmark-specific options are documented below.

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
| Repeated individual writes | Prepared `INSERT` | Prepare once and bind new values. Keep transaction boundaries explicit. |
| Batch writes | `bulkInsert` / `bulkInsertArray` on one connection | Build one bounded payload at a time. Prefer columnar `addColumnInt32` / `addColumnText` for column-shaped sources. See `example/bulk_insert_demo.dart`. |
| Independent parallel batches | `bulkInsertParallel` with a native pool | Measure against single-connection bulk with the same data and batch sizes; there is no universal row-count threshold. Match parallelism to available pool slots. The example reserves one slot for setup/cleanup and does not claim atomicity across parallel workers. |
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
| Many independent short/medium queries             | `AsyncNativeOdbcConnection(workerCount: N)`                                                                | Open multiple connections. Same-connection calls remain serialized. See the worker-count comparison in `example/async_concurrency_benchmark.dart`.                                         |
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
| `zeroCopyResultThresholdBytes` | `32 KiB` | `callWithBuffer` skips the `Uint8List.fromList` copy for successful transient payloads at or above this size. Sync param paths with large directed blobs use a transient allocation via `preferTransientFfiBufferForParams`. |
| Scratch pool | seeds `< 32 KiB` | Reusable scratch buffers still copy on return because the pool reuses memory on the next FFI call. Transient + zero-copy when `preferTransient` or `initialSize >= 32 KiB` (not gated on the 16 MiB max ceiling). |
| `odbc_release_buffer` | exported ABI 1.1 | C ABI hook for consumers that need it. Dart pairs its own `package:ffi` `malloc` buffers with `malloc.nativeFree`, so zero-copy remains available with older compatible native libraries. |

The ownership rule is intentionally narrow: this applies only to transient
buffers allocated by Dart. Native decompression results retain their separate
native release contract.

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

## Streaming and native columnar batched wire

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
(async and sync). For `streamQueryMulti` and `streamQueryMultiBatches`, the
same knobs forward to
`odbc_stream_multi_start_*_options` when available; older natives without the
options symbol keep the legacy entry (engine default fetch 100).
Wire tag 2 (continuation batch of the same SQL cursor) is coalesced in the
repository runner into one `QueryResultMultiItem` so stream item counts match
`executeQueryMultiFull` (growable row list — no per-batch `List.of` when the
list is already growable). `streamQueryMultiBatches` instead exposes every
tag-0/tag-2 batch as `QueryResultMultiBatchItem`; use it when work can be
performed per fetch and bounded decoded memory is preferable to coalesced
cursor semantics. Async
backends use `streamMultiStartAsync` + `streamPollAndFetch` (one isolate hop
when ready).

No-param `executeQuery` is a **one-shot** `execQuery` / empty-params path (not a
drained batched stream). Use `streamQuery*` for incremental delivery of large
results.

Columnar float/double decode builds `TypedColumnFloat64` (`Float64List`).
Row-major `Float` / `Double` and `Boolean` cells use little-endian IEEE-754
and a single `0`/`1` byte respectively; Dart also accepts their legacy UTF-8
representation. Date/time values remain ISO text.

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
coalesces tag-2 batches into one logical `QueryResultMultiItem` per cursor,
while `streamQueryMultiBatches` publishes each batch directly.

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

## Dart hot-path comparison

Run `dart run benchmarks/dart_hot_paths.dart` for cursor consumption and indexed
column access and complete fragmented framing; `--linear` retains the old
column helper for comparison. Output
contains 15 measured samples after six warmups, in microseconds. Each sample
uses eight rounds, except the single full frame which uses 64 rounds to reduce
timer noise. Complete framing uses one round per sample. Compare the same SDK,
machine and workload. Frames cover small
coalesced inputs, large/full-capacity inputs, fragmentation and retained lazy
text. When comparing revisions, copy the original accumulator into an ignored
working directory for accumulator-only comparisons. For end-to-end framing,
archive the baseline `lib/` tree and use a separate package configuration that
maps `package:odbc_fast` to that tree, keeping dependency and SDK paths fixed.
Copy the same benchmark to that directory; instrument only backing allocation
and pending-byte copy counters, without changing baseline algorithms. No DSN
or native ABI change is involved. Check distributions and repeat in reverse
execution order to assess noisy cases.

### Measured comparison (2026-09-30)

Windows x64, Dart 3.13.4 stable, one process at a time without concurrent test
suites. Baseline accumulator:
`7fe2b37f91d1338d19753c44d567387ead5bda80`; column baseline uses the retained
`result.cell` helper. Numbers below are medians per sample, not per operation.
The ratio interval resamples baseline and revised samples independently 10,000
times with seed 7, comparing their medians. A ratio below 1 favors the revision.

| Scenario | Baseline (ms) | Revised (ms) | Speedup | Revised/baseline 95% bootstrap interval |
| --- | ---: | ---: | ---: | --- |
| 500 frames, 32 bytes | 16.040 | 0.072 | 222.78x | 0.004–0.009 |
| 2,000 frames, 32 bytes | 84.362 | 0.222 | 380.01x | 0.002–0.003 |
| 8,000 frames, 32 bytes | 482.535 | 3.161 | 152.65x | 0.006–0.007 |
| 16 frames, 65,536 bytes | 26.831 | 3.152 | 8.51x | 0.109–0.120 |
| Single frame, 65,536 bytes (64 rounds) | 0.992 | 0.664 | 1.49x | 0.107–1.116 |
| 13-byte input fragments | 42.103 | 38.419 | 1.10x | 0.863–0.963 |
| Retained lazy text | 778.188 | 1.077 | 722.55x | 0.001–0.001 |
| Repeated column lookup | 598.942 | 5.972 | 100.29x | 0.010–0.010 |

Consumption no longer copies the remainder after each frame. For one pass over
8,000 32-byte frames, this removes 1,023,872,000 bytes of remainder copying;
cursor advancement copies none. Adding new bytes after delivering shared views
still detaches the backing and copies pending bytes once to preserve ownership.
The full-frame interval includes 1: this run establishes no significant change
in that noisy scenario. All other intervals favor the revision. These are local
JIT measurements, not a cross-platform performance guarantee.

The implementation regression run uses the canonical CI flags (`CI=true`,
`ENABLE_E2E_TESTS=0`, `RUN_SKIPPED_TESTS=0`, `RUN_LIVE_TESTS=0`). Additional checks
cover public exports, documentation, examples, and the CI protocol performance
tests. Local integration cases run without a DSN; live-driver cases explicitly
skip when their prerequisites are unavailable. No live database result is
claimed by this comparison.

Validation recorded for the earlier cursor/reader revision: `dart analyze`
reports no issues; the CI unit
command passes 1,607 tests with three explicit skips. The complementary core,
exports, documentation and examples suite passes 85 tests, and the CI protocol
performance suite passes 10. Local integration passes 16 cases with 25 explicit
live-driver skips. The CI slow-test check also passes its 1,500 ms threshold.

### Buffer and lifecycle safety comparison (2026-10-03)

Baseline `522dc45`, Windows x64, Dart 3.13.4 stable, sequential JIT processes
with no concurrent test suites. Each process uses six warmups and 15 measured
samples. The repeated run reverses process order. The following medians are
from that repeated run; bootstrap intervals resample the two median
distributions independently 2,000 times with seed 42. Ratios above 1 favor
the revision. They describe this machine, rather than a portable guarantee.

| Scenario | Baseline (microseconds) | Revised (microseconds) | Baseline/revised 95% interval |
| --- | ---: | ---: | --- |
| 500 frames, 32 bytes | 105 | 95 | 0.46–1.96 |
| 2,000 frames, 32 bytes | 236 | 239 | 0.71–1.23 |
| 8,000 frames, 32 bytes | 3,094 | 2,887 | 0.81–1.17 |
| 16 frames, 65,536 bytes | 3,251 | 3,277 | 0.86–1.15 |
| Single 65,536-byte frame, 64 rounds | 682 | 450 | 1.15–3.45 |
| 13-byte fragments | 35,645 | 18,060 | 1.91–2.03 |
| Complete 128 KiB frame, 1 KiB fragments | 6,104 | 200 | 15.12–43.25 |
| Complete 256 KiB frame, 1 KiB fragments | 19,283 | 193 | 56.80–110.98 |
| Complete 512 KiB frame, 1 KiB fragments | 58,963 | 222 | 110.28–363.22 |
| Complete 1 MiB frame, 1 KiB fragments | 191,704 | 366 | 400.32–626.79 |
| Retained lazy text | 1,095 | 882 | 1.18–1.37 |
| Indexed column lookup | 6,074 | 5,616 | 1.04–1.19 |

The small-frame/full-frame intervals include 1 for four retained scenarios;
the repeated run provides no statistically significant regression there.
The initial 500-frame sample looked slower, but that change did not persist
when execution order was reversed. Complete 1 MiB framing improved about
524 times in this local run.

| Complete framing size | Baseline pending bytes copied | Revised pending bytes copied |
| --- | ---: | ---: |
| 128 KiB | 8,323,072 | 65,536 |
| 256 KiB | 33,423,360 | 65,536 |
| 512 KiB | 133,955,584 | 65,536 |
| 1 MiB | 536,346,624 | 65,536 |

Owned header prefixes no longer expose backing on every fragment, and the
validated length is cached until completion. Pending bytes are copied once
when capacity grows from 64 KiB to 1 MiB in these cases. Further growth doubles
capacity, so assembly copies grow linearly rather than quadratically.
Backing allocation counters include all warmup and measured rounds, not live
heap size or every Dart object. For complete 1 MiB framing they fell from
21,227,372,544 to 22,020,096 bytes across 21 rounds.

The safety policy also has a measurable cost: after forced GC with only a
derived byte view, `ByteData` or lazy string retained, the old finalizer could
reuse the backing and corrupt the consumer's data. The separate allocation
probe reported zero new backing bytes and invalid retained data for `522dc45`;
the revision allocated 65,536 new backing bytes and preserved every view.
Automatic recycling of exposed backing is therefore removed. Only unexposed
abandoned buffers and explicit exclusive-ownership offers may enter the pool.

Run the ownership check separately from the fast unit budget:

```sh
dart test test/integration/protocol_frame_ownership_gc_test.dart
```

It launches a child Dart VM with a local service, requests GC through the VM
service, checks independent derived views after their original frames become
unreachable, and always kills the child on exit or its 30-second deadline.
The CI runs this as a separate step. It requires no DSN or native library.

Deterministic fakes cover concurrent initialization, interrupted spawn/handshake,
worker exit, partial failure, generation changes, completion evidence and late
resources. Native evidence is per invocation: missing status does not imply
consumption. A timeout completes the caller once while unresolved work retains
capacity; maintenance runs on its owning worker and checks every cleanup result.
Prepared XA resumption is adopted explicitly by immutable XID key. Unknown
transaction outcomes prohibit conflicting work and automatic transaction
decisions, including phases attempted inside a helper's callback. Dispose or
worker death reports unconfirmed cleanup, because a blocked FFI call cannot be
guaranteed to cancel from Dart. UTF-8 XID tests cover byte limits and invalid
surrogates; recovery of old non-ASCII branches requires their original bytes.

Validation of this safety revision: `dart analyze` reports no issues. The CI
unit command passes 1,668 tests with three explicit skips; core, public exports,
documentation and examples pass 85. FFI export verification confirms 111 symbols.
The protocol performance guard passes 10 tests and the standalone GC process
passes its ownership check. Local integration passes 17 cases with 25 explicit
live-driver skips. The slow-test budget passes its 1,500 ms threshold (the
slowest reported case was 1,023 ms); GC runs outside that unit budget. No live
database result is claimed. Late successful pool release/close and async free
also remove repository metadata, while the previously returned timeout remains
a failure with its original operation and request identifiers.
