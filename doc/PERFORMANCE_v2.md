# Performance & Reliability Notes — v2.0.0

This release delivers correctness, security and observability improvements
without disturbing the public Dart FFI ABI. The performance impact is
discussed below per change category.

## Concurrency improvements

| Change | Expected impact |
|---|---|
| `odbc_pool_get_connection` no longer holds the global state mutex while waiting on `r2d2::Pool::get()` (C3) | Eliminates a critical bottleneck where every concurrent FFI call could stall up to 30 s behind a single slow checkout. Throughput under contention scales close to `r2d2.max_size` instead of being serialised. |
| `odbc_pool_close` drains live checkouts before removing the pool entry (C4) | Prevents a deadlock during shutdown when other threads still hold pooled connections. |
| `PoolAutocommitCustomizer` (A14) | Adds a single `set_autocommit(true)` per checkout. Negligible cost; eliminates the worst-case where a connection returned to the pool mid-transaction silently affected the next user. |
| `recv_timeout`/structured worker-disconnect (A5) | No throughput impact; converts an indefinite hang into an explicit `WorkerCrashed` error so the consumer can recover. |
| `read_exact` in disk-spill readback (A6) | Identical happy-path cost; eliminates silent short-read truncation on Windows for large spills. |

## Memory and bounds

| Change | Expected impact |
|---|---|
| `parse_bulk_insert_payload` validates null-bitmap length up-front (C9) | Adds a single `len()` check per nullable column. Negligible cost; prevents corrupted writes downstream. |
| `MAX_BULK_COLUMNS` / `MAX_BULK_ROWS` / `MAX_BULK_CELL_LEN` (M2) | Adds three integer comparisons per payload header. Prevents allocation-bomb DoS. |
| `serialize_bulk_insert_payload` uses `try_into` for length casts (M8) | One additional branch per length field. Returns `MalformedPayload` on overflow instead of silent truncation. |
| `SecureBuffer::with_bytes` (C5) | Closure-based access avoids the heap copy required by `into_vec`. Faster *and* safer for the common short-lived consumer. |
| `SecretManager::with_secret` (M12) | Avoids the per-retrieve `Vec<u8>` clone of the underlying secret bytes when only read access is required. |

## Observability

| Change | Expected impact |
|---|---|
| `SpanGuard` RAII (A3) | Same nominal cost as the manual `start/finish` pair; eliminates leaks of `QuerySpan` (with full SQL text) on every error path. Reduces long-running memory growth. |
| `sanitize_sql_for_log` (A8) | Linear scan of the SQL text per log call. The default INFO-level path is gated behind `if !self.enabled { return }`; sanitisation only runs when the logger is enabled. Bypass with `ODBC_FAST_LOG_RAW_SQL=1`. |

## Safety / correctness

| Change | Expected impact |
|---|---|
| `ffi::guard::call_int*`/`call_id*`/`call_ptr*` + `expect → structured error` in `odbc_stream_fetch` (C1) | Single `catch_unwind` per FFI call when adopted (~tens of ns); converts UB into a stable error code. |
| `quote_identifier_default` in `Savepoint` and `ArrayBinding` (A1, A2) | One regex-style validation per identifier, allocation-free. Prevents SQL injection. |

## How to validate against your workload

1. Save current numbers as a baseline:

   ```powershell
   cd native\odbc_engine
   cargo bench --bench bulk_operations_bench --bench comparative_bench `
               --bench metadata_cache_bench `
   | Out-File ..\..\bench_baselines\v1.2.1.txt
   ```

2. Run the same benches after upgrading and diff. Most changes here are
   neutral or net-positive; the one expected speedup is concurrent
   pool-checkout throughput.

## Known limitations (tracked for v2.1)

- True chunk-by-chunk streaming (no full materialisation in
  `engine::streaming::execute_streaming`) — audit C7.
- Full row-count → multi-result handling (transition through
  `Statement::more_results` without re-borrowing `Prepared`) — audit C6
  remainder.
- `Mutex<GlobalState>` granularisation in `ffi/mod.rs` is partial: the
  most critical path (`odbc_pool_get_connection`) was unblocked, but the
  global state still serialises the rest of the FFI surface.
