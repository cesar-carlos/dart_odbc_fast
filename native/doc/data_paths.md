# Data paths (performance-oriented)

This document summarizes the main “data paths” implemented in the Rust engine for
handling larger datasets: streaming, batching, pooling, transactions, and array binding.

## 1) Query execution → binary protocol buffer

Most APIs ultimately produce a `Vec<u8>` encoded by:

- `protocol::RowBufferEncoder::encode(&RowBuffer)`

This buffer is the unit transported over FFI (`odbc_exec_query`, streaming batches, etc).

### 1.1 Spill-to-disk for large buffers

For cases where you want to build a large payload but avoid keeping it all in RAM,
the engine provides `engine::core::DiskSpillStream`:

- buffers in memory up to a threshold (default: 100 MB)
- then spills to a temp file under `std::env::temp_dir()`
- `read_back()` returns the final bytes and cleans up the temp file

This is a building block (not currently wired into the FFI query APIs by default).

### 1.2 Caches and protocol negotiation (supporting utilities)

These are supporting utilities that impact performance/compatibility:

- `engine::core::MetadataCache` (TTL + LRU) for table schemas
- `engine::core::PreparedStatementCache` (LRU) keyed by SQL strings
- `engine::core::ProtocolEngine` + `ProtocolVersion` for protocol version negotiation

## 2) Streaming

### 2.1 FFI streaming (chunked copy-out)

FFI streaming (`odbc_stream_*`) has two modes:

**Buffer mode** (`odbc_stream_start`):

- Executes the query
- Encodes the full result set into a `Vec<u8>`
- Lets the caller pull it in fixed-size chunks via `odbc_stream_fetch`

Use when: you need **bounded memory on the Dart side**, but can tolerate the engine holding the full result in memory.

**Batched mode** (`odbc_stream_start_batched`):

- Uses `engine::StreamingExecutor::execute_streaming_batched` internally
- Fetches up to `fetch_size` rows per batch, encodes each batch, stores only the next batch in `BatchedStreamingState`
- Same `odbc_stream_fetch` / `odbc_stream_close`; chunks are derived from batches
- Memory footprint is bounded to one batch (Rust and Dart)

Use when: you want **bounded memory on the Rust side too**, and can process results incrementally (e.g. large result sets, 50k+ rows with `fetch_size=1000`).

### 2.2 Engine-level batched streaming (callback)

`engine::StreamingExecutor::execute_streaming_batched` implements **cursor-based batching**:

- Fetches up to `fetch_size` rows at a time
- Encodes _each_ batch to a `Vec<u8>`
- Calls `on_batch(Vec<u8>)` for each batch
- Memory footprint is bounded to one batch

Use when: you call the Rust engine directly (no FFI) and want bounded memory. The FFI batched mode (`odbc_stream_start_batched`) wraps this for C/Dart consumers.

## 3) Batch execution

`engine::core::BatchExecutor` supports:

- `execute_batch(conn, Vec<BatchQuery>)` (simple loop)
- `execute_batch_optimized(conn, sql, param_sets)` (chunked by `batch_size`)

Note: at the moment `execute_batch_optimized` prepares and executes statements but
does not apply the `BatchParam` values (placeholder for future parameter binding).

## 4) Array binding (high-throughput inserts)

`engine::core::ArrayBinding` uses `odbc_api` column inserters:

- `bulk_insert_i32(...)`
- `bulk_insert_i32_text(...)`

It uses an internal `paramset_size` (default: 1000) and sends rows in chunks.

### 4.1 Parallel bulk insert (pool + rayon + array binding)

`engine::core::ParallelBulkInsert` provides a higher-level insert path:

- splits input columns into chunks
- runs chunk inserts in parallel using `rayon`
- each worker checks out a connection from `pool::ConnectionPool`
- inserts via `engine::core::ArrayBinding`

## 5) Connection pooling

`pool::ConnectionPool`:

- is backed by `r2d2`
- uses a single process-wide ODBC `Environment` via `OnceLock`
- validates connections on checkout (`test_on_check_out(true)` + `SELECT 1`)

Pool identity:

- `ConnectionPool::get_pool_id()` returns `server:port:uid` extracted from the connection string
  (database excluded to allow reuse when only the database changes).

## 6) Transactions (RAII + isolation + savepoints)

`engine::transaction::Transaction` provides:

- Isolation levels:
  - ReadUncommitted
  - ReadCommitted
  - RepeatableRead
  - Serializable
- Isolation is applied via SQL‑92:
  - `SET TRANSACTION ISOLATION LEVEL <...>`
- Autocommit is disabled on begin and restored on commit/rollback
- RAII safety:
  - if a `Transaction` is dropped while `Active`, it attempts `rollback()` and restores autocommit
- Savepoints:
  - `SAVEPOINT <name>`
  - `ROLLBACK TO SAVEPOINT <name>`
  - `RELEASE SAVEPOINT <name>`

## 7) Observability and security helpers (Rust API)

These are implemented in Rust and used by the engine/FFI:

- `observability::*`: `Metrics` (exposed via `odbc_get_metrics`), `StructuredLogger`, `Tracer`
- `security::*`: `SecretManager`, `Secret`, `AuditLogger`, secure buffers
- `handles::HandleManager`: owns the leaked `Environment` and stores `Connection<'static>` handles
- `async_bridge`: tokio runtime singleton used by `odbc_init` (and a blocking async runner)

## Practical notes / limitations

- **BCP (SQL Server bulk copy)**:
  - `engine::core::BulkCopyExecutor` is currently a stub unless feature `sqlserver-bcp` is enabled.
  - Even with the feature, the BCP path is not implemented yet.
- **FFI pooled connections**:
  - Pooled connections are tracked separately from `odbc_connect` connections; the FFI query API
    is designed around `conn_id` from `odbc_connect`.
- **E2E / coverage**:
  - E2E tests may self-skip when no DSN is configured. See:
    - `native/odbc_engine/E2E_TESTS_ENV_CONFIG.md`
    - `native/odbc_engine/MULTI_DATABASE_TESTING.md`


