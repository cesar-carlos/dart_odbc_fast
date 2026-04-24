# Performance & Reliability Notes

> **Last updated for:** v3.5.3

This document records architectural decisions with a measurable performance or reliability impact. It is not a benchmark report — run the benches locally to get numbers for your workload.

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

To save a baseline before upgrading:

```powershell
cargo bench --bench bulk_operations_bench --bench comparative_bench --bench metadata_cache_bench `
  | Out-File ..\..\bench_baselines\v3.5.3.txt
```

---

## Concurrency

| Design decision | Reasoning |
|---|---|
| `odbc_pool_get_connection` releases the global state mutex before calling `r2d2::Pool::get()` | Without this, every concurrent FFI call serialised behind slow pool checkouts (up to 30 s). Throughput under contention now scales close to `r2d2.max_size`. |
| `odbc_pool_close` drains live checkouts before removing the pool entry | Prevents a deadlock when other threads still hold pooled connections at shutdown. |
| `PoolAutocommitCustomizer` sets `autocommit(true)` on every checkout | One extra ODBC call per checkout; eliminates the worst case where a connection returned mid-transaction silently affected the next caller. |
| `recv_timeout` + structured worker-disconnect error | Converts an indefinite hang into an explicit `WorkerCrashed` error so the consumer can recover. |
| `read_exact` in disk-spill readback | Eliminates silent short-read truncation on Windows for large spills with no happy-path cost. |
| `Mutex<GlobalState>` granularity | Most critical path (`odbc_pool_get_connection`) is unblocked. Remaining FFI surface still serialises through the global state; granularising further is tracked as future work. |

---

## Memory and bounds

| Design decision | Reasoning |
|---|---|
| `parse_bulk_insert_payload` validates null-bitmap length up-front | Single `len()` check per nullable column; prevents corrupted writes. |
| `MAX_BULK_COLUMNS` / `MAX_BULK_ROWS` / `MAX_BULK_CELL_LEN` caps | Three integer comparisons per payload header; prevents allocation-bomb DoS. |
| `serialize_bulk_insert_payload` uses `try_into` for length casts | One branch per length field; returns `MalformedPayload` on overflow instead of silent truncation. |
| `SecureBuffer::with_bytes` | Closure-based access avoids the heap copy required by `into_vec` for short-lived consumers. |
| `SecretManager::with_secret` | Avoids the per-retrieve `Vec<u8>` clone when only read access is required. |

---

## Observability overhead

| Decision | Reasoning |
|---|---|
| `SpanGuard` RAII | Same nominal cost as manual `start/finish`; eliminates leaks of `QuerySpan` (with full SQL text) on every error path, reducing long-running memory growth. |
| `sanitize_sql_for_log` | Linear scan of the SQL string per log call. The default INFO-level path is gated behind `if !self.enabled { return }`; sanitisation only runs when the logger is enabled. Bypass with `ODBC_FAST_LOG_RAW_SQL=1`. |

---

## Safety / correctness

| Decision | Reasoning |
|---|---|
| `ffi::guard::call_int*` / `call_id*` / `call_ptr*` + `catch_unwind` | Single `catch_unwind` per FFI call (~tens of ns); converts Rust panics into stable error codes (`FfiError::Panic = -4`) instead of UB. |
| `quote_identifier_default` in `Savepoint` and `ArrayBinding` | One validation per identifier, allocation-free; prevents SQL injection via identifiers. |

---

## Known open work (active tracking)

These items are tracked in [`Features/PENDING_IMPLEMENTATIONS.md`](Features/PENDING_IMPLEMENTATIONS.md):

- **True chunk-by-chunk streaming** — `engine::streaming::execute_streaming` still materialises results internally before chunking (audit C7). Multi-result streaming FFI (`odbc_stream_multi_*`) added in v3.3.0 improves the surface but the per-cursor materialisation remains.
- **`Mutex<GlobalState>` granularisation** — the most critical pool path was unblocked; the rest of the FFI surface still serialises. Profiling under >16 concurrent callers will show this.
- **BCP / array-binding streaming** — bulk insert via `BulkCopyExecutor` and `ArrayBinding` does not stream; the full payload is materialised in the Rust engine.
