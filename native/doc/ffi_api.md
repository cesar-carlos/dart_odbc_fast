# FFI API (C ABI) — `odbc_*`

This document describes the public C ABI entrypoints implemented in
`native/odbc_engine/src/ffi/mod.rs`.

The API is **stateful**: most functions interact with a process‑global `GlobalState`.

## Lifecycle

### `odbc_init() -> int`

Initializes the async runtime and the ODBC environment.

- **Returns**: `0` on success; non‑zero on failure.

### `odbc_set_log_level(level: int) -> int`

Sets the log level for the native engine. Affects the `log` crate's max level filter.
A logger (e.g. env_logger) must be initialized by the host for output to appear.

- **level**: `0`=Off, `1`=Error, `2`=Warn, `3`=Info, `4`=Debug, `5`=Trace. Other values map to Off.
- **Returns**: `0` on success.

### `odbc_get_version(buffer, buffer_len, out_written) -> int`

Returns engine version as JSON for client compatibility checks.

- **Output**: UTF‑8 JSON `{"api":"0.1.0","abi":"1.0.0"}`.
  - **api**: package version from Cargo.toml.
  - **abi**: FFI contract version; bump on breaking changes.
- **Returns**: `0` on success; `-1` if buffer or out_written is null; `-2` if buffer too small.

### `odbc_validate_connection_string(conn_str, error_buffer, error_buffer_len) -> int`

Validates connection string format without connecting. Checks: non-empty, valid UTF-8,
at least one key=value pair, balanced braces. Does not verify driver availability
or server reachability.

- **Returns**: `0` if valid; `-1` if invalid (error message written to `error_buffer`).
- **error_buffer**: optional; if null or too small, returns -1 without writing.

### `odbc_connect(conn_str: *const c_char) -> unsigned int`

Creates a new ODBC connection and stores it in global state.

- **Returns**: `conn_id > 0` on success; `0` on failure.
- **Errors**: use `odbc_get_error(...)` / `odbc_get_structured_error(...)`.

### `odbc_connect_with_timeout(conn_str: *const c_char, timeout_ms: unsigned int) -> unsigned int`

Creates a new ODBC connection with login timeout.

- **Returns**: `conn_id > 0` on success; `0` on failure.
- **timeout_ms**: login timeout in milliseconds. Current implementation maps
  `0` to a minimum timeout of `1` second.

### `odbc_disconnect(conn_id: unsigned int) -> int`

Disconnects and removes the connection. Also rolls back any active transactions
belonging to that connection.

- **Returns**: `0` on success; non‑zero on failure.

## Audit logging

### `odbc_audit_enable(enabled: int) -> int`

Enables or disables in-memory audit event collection.

- **enabled**: `0` disables logging; non-zero enables logging.
- **Returns**: `0` on success; `-1` on failure.

### `odbc_audit_get_events(buffer, buffer_len, out_written, limit) -> int`

Returns audit events as a JSON array.

- **Returns**: `0` on success; `-1` on error; `-2` if `buffer` is too small.
- **limit**: max number of most recent events (`0` = all available).
- **Buffer contract**:
  - Caller provides `buffer` and `buffer_len`.
  - On success, `out_written` contains bytes copied.
  - On error, `out_written` is set to `0` when pointer is valid.

### `odbc_audit_clear() -> int`

Clears all in-memory audit events.

- **Returns**: `0` on success; `-1` on failure.

### `odbc_audit_get_status(buffer, buffer_len, out_written) -> int`

Returns audit status as a JSON object:

```json
{ "enabled": true, "event_count": 12 }
```

- **Returns**: `0` on success; `-1` on error; `-2` if `buffer` is too small.

## Query execution

### `odbc_exec_query(conn_id, sql, out_buffer, buffer_len, out_written) -> int`

Executes a query and writes the binary protocol into `out_buffer`.

- **Returns**: `0` on success; non‑zero on failure.
- **Buffer contract**:
  - Caller provides `out_buffer` and `buffer_len`.
  - On success, `out_written` is set to the required/used number of bytes.
  - If buffer is too small, the function returns an error (and sets last error).

### `odbc_exec_query_params(conn_id, sql, params_buffer, params_len, out_buffer, buffer_len, out_written) -> int`

Executes a **parameterized** query and writes the binary protocol into `out_buffer`.

- **Returns**: `0` on success; `-1` on error; `-2` if output buffer is too small.
- **Parameters**:
  - `params_buffer`: serialized `ParamValue` array (binary format). Use `NULL` or `params_len == 0` to run a non‑parameterized query (same as `odbc_exec_query`).
  - `params_len`: length of `params_buffer` in bytes.
- **Buffer contract**: same as `odbc_exec_query` for `out_buffer` / `buffer_len` / `out_written`.
- **ParamValue format**: each parameter is `[tag: 1 byte][len: 4 bytes LE][payload]`. Tags: `0` Null, `1` String, `2` Integer (i32), `3` BigInt (i64), `4` Decimal (UTF‑8), `5` Binary. NULL parameters are not supported for binding yet.

### `odbc_exec_query_multi(conn_id, sql, out_buffer, buffer_len, out_written) -> int`

Executes **batch SQL** (e.g. multiple statements, stored procedures) and returns a **multi-result** binary buffer.

- **Returns**: `0` on success; `-1` on error; `-2` if buffer too small.
- **Output format**: `[count: 4 bytes LE][foreach item: tag(1) + len(4) LE + payload]`. Tag `0` = result set (payload = standard binary protocol); tag `1` = row count (payload = 8 bytes i64 LE). All results are returned via full `SQLMoreResults` iteration (batch SQL, stored procedures, multiple statements).

### Async Execute (poll-based)

### `odbc_execute_async(conn_id, sql) -> unsigned int`

Starts non-blocking execution and returns a `request_id`.

- **Returns**: `request_id > 0` on success; `0` on failure.

### `odbc_async_poll(request_id, out_status) -> int`

Polls request status.

- **Returns**: `0` on success; `-1` on invalid request or pointer.
- **out_status**:
  - `0`: pending
  - `1`: ready (result available via `odbc_async_get_result`)
  - `-1`: completed with error
  - `-2`: cancelled

### `odbc_async_get_result(request_id, out_buffer, buffer_len, out_written) -> int`

Retrieves the binary result for a completed async request.

- **Returns**: `0` on success; `-1` on error/invalid request; `-2` if buffer too small.

### `odbc_async_cancel(request_id) -> int`

Best-effort cancellation of a pending async request.

- **Returns**: `0` on success; `-1` if request is unknown.

### `odbc_async_free(request_id) -> int`

Releases resources associated with an async request.

- **Returns**: `0` on success; `-1` if request is unknown.

### Prepare / Execute / Cancel / Close (timeout support)

Workflow: `odbc_prepare` → `odbc_execute` (possibly multiple times) → `odbc_close_statement`. Optional `odbc_cancel` to request cancellation (see limitations below).

#### `odbc_prepare(conn_id, sql, timeout_ms) -> unsigned int`

Prepares a statement with optional query timeout.

- **Returns**: `stmt_id > 0` on success; `0` on failure.
- **conn_id**: accepts either a regular connection ID (`odbc_connect`) or a pooled
  connection ID (`odbc_pool_get_connection`).
- **timeout_ms**: `0` = no timeout; otherwise timeout in milliseconds. Uses ODBC `SQL_ATTR_QUERY_TIMEOUT` where supported (e.g. SQL Server, PostgreSQL).

#### `odbc_execute(stmt_id, params_buffer, params_len, timeout_override_ms, fetch_size, out_buffer, buffer_len, out_written) -> int`

Executes a prepared statement. Same output contract as `odbc_exec_query` / `odbc_exec_query_params`.

- **Returns**: `0` on success; `-1` on error; `-2` if output buffer too small.
- **params_buffer** / **params_len**: Serialized `ParamValue` array; use `NULL` / `0` for no parameters.
- **timeout_override_ms**: Precedence rule:
  - `0` → use timeout from `odbc_prepare` (or none if prepare used `0`).
  - `> 0` → override: use this value (in ms); minimum effective is 1 second.
- **Example**: `odbc_prepare(..., 30000)` + `odbc_execute(..., 2000, ...)` → 2 s timeout for this execution.
- **fetch_size**: optional execution fetch hint (`0` = default behavior).

#### `odbc_cancel(stmt_id) -> int`

Requests cancellation of a statement **currently executing**. **Limitation**: Full cancel (ODBC `SQLCancel`) requires an active ODBC statement handle. The prepare/execute flow is synchronous and does not hold a persistent statement handle during execution; cancel is planned for when async execution or streaming-with-cancel is implemented. **Workaround**: Use query timeout (`odbc_prepare` with `timeout_ms`, or `odbc_connect_with_timeout`) to bound execution time.

**Timeout vs cancel semantics**:
- **Timeout**: Set before execution; the driver aborts the query after the specified duration. Supported by SQL Server, PostgreSQL, and others via `SQL_ATTR_QUERY_TIMEOUT`.
- **Cancel**: Requested during execution; requires the caller to invoke cancel while another thread holds the executing statement. Not yet supported in the current synchronous prepare/execute flow.

#### `odbc_close_statement(stmt_id) -> int`

Closes the prepared statement and releases resources. **Returns**: `0` on success; non‑zero on failure (e.g. invalid `stmt_id`). Statements for a connection are also removed when that connection is disconnected.

#### `odbc_clear_all_statements() -> int`

Closes all tracked prepared statements and clears statement state.

- **Returns**: `0` on success; non-zero on failure.

**Statement handle reuse (opt-in)**: Build with `--features statement-handle-reuse` to enable LRU prepared-statement reuse per connection. Current implementation caches prepared handles with explicit lifetime management; keep this feature opt-in until your workload benchmark confirms gains.

## Streaming (chunked copy-out over FFI)

Streaming provides a way to fetch a large encoded result in pieces without
allocating a huge buffer on the Dart side.

**Two modes:**

1. **Buffer mode** (`odbc_stream_start`): Executes the query, encodes the full
   result, then yields fixed-size chunks. Bounded memory on the Dart side.
   When `ODBC_STREAM_SPILL_THRESHOLD_MB` is set (>0), large results spill to
   temp file; engine reads in chunks without holding full result in memory.

2. **Batched mode** (`odbc_stream_start_batched`): Cursor-based batching. Fetches
   `fetch_size` rows per batch, encodes each batch, and stores only the next
   batch in `BatchedStreamingState`. Memory is bounded in both Rust and Dart.
   HandleManager lock is used briefly to resolve the connection handle; stream
   execution then proceeds on the connection lock.

3. **Async batched mode** (`odbc_stream_start_async` + `odbc_stream_poll_async`):
   same cursor-based batching behavior as batched mode, but with explicit
   poll-based lifecycle and non-blocking readiness check before fetch.

All modes use the same `odbc_stream_fetch` and `odbc_stream_close` APIs.

### `odbc_stream_start(conn_id, sql, chunk_size) -> unsigned int`

Executes `sql`, encodes the entire result to the binary protocol, and creates a
stream handle that can be consumed in chunks (buffer mode).

- **Returns**: `stream_id > 0` on success; `0` on failure.
- **chunk_size**: bytes per FFI chunk; `0` = default (1024).

### `odbc_stream_start_batched(conn_id, sql, fetch_size, chunk_size) -> unsigned int`

Starts **cursor-based batched** streaming. Fetches up to `fetch_size` rows per
batch; each batch is then chunked into `chunk_size`-byte pieces for `odbc_stream_fetch`.

- **Returns**: `stream_id > 0` on success; `0` on failure.
- **fetch_size**: rows per batch (engine-side); `0` = default (100).
- **chunk_size**: bytes per FFI chunk; `0` = default (1024).

### `odbc_stream_start_async(conn_id, sql, fetch_size, chunk_size) -> unsigned int`

Starts **poll-based async batched** streaming. Execution/fetching runs in a
background worker. Use `odbc_stream_poll_async` to observe readiness.

- **Returns**: `stream_id > 0` on success; `0` on failure.
- **fetch_size**: rows per batch (engine-side); `0` = default (100).
- **chunk_size**: bytes per FFI chunk; `0` = default (1024).

### `odbc_stream_poll_async(stream_id, out_status) -> int`

Polls async stream lifecycle status.

- **Returns**: `0` on success; `-1` on invalid stream or null pointer.
- **out_status**:
  - `0`: pending (not ready for fetch yet)
  - `1`: ready (one or more chunks available through `odbc_stream_fetch`)
  - `2`: done (no more data)
  - `-1`: error
  - `-2`: cancelled

Recommended flow:
1. `odbc_stream_start_async(...)`
2. loop `odbc_stream_poll_async(...)`
3. when status is `1`, call `odbc_stream_fetch(...)`
4. when status is `2`, stop and call `odbc_stream_close(...)`

### `odbc_stream_fetch(stream_id, out_buffer, buffer_len, out_written, out_has_more) -> int`

Fetches the next chunk. Works for both buffer and batched streams.

- **Returns**: `0` on success; non‑zero on failure.
- On success:
  - `out_written` is set to the bytes written for this chunk (may be `0` on EOF).
  - `out_has_more` is set to `1` if there is more, otherwise `0`.

### `odbc_stream_cancel(stream_id) -> int`

Requests cancellation of a stream. Supported for batched and async-batched
streams; buffer-mode streams (`odbc_stream_start`) treat cancel as no-op.

- **Returns**: `0` on success; non‑zero if `stream_id` is invalid.
- After cancel, `odbc_stream_fetch` will eventually return `out_has_more = 0`.

### `odbc_stream_close(stream_id) -> int`

Releases the stream state (buffer or batched).

### Dart/worker usage (poll-based async stream)

```dart
final streamId = native.streamStartAsync(connId, sql);
if (streamId == null || streamId == 0) throw Exception(native.getError());

while (true) {
  final status = native.streamPollAsync(streamId);
  if (status == 0) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    continue;
  }
  if (status == 2) break; // done
  if (status == -1 || status == -2 || status == null) {
    throw Exception(native.getError());
  }
  final chunk = native.streamFetch(streamId);
  // decode/process chunk
}
native.streamClose(streamId);
```

## Catalog / Metadata

Catalog functions use `INFORMATION_SCHEMA` (TABLES, COLUMNS) and return the same
binary protocol as `odbc_exec_query`. Decode with `BinaryProtocolDecoder`.

### Metadata cache controls

#### `odbc_metadata_cache_enable(max_size, ttl_secs) -> int`

Configures metadata cache capacity and TTL (seconds).

- **Returns**: `0` on success; non-zero on failure.
- **max_size**: number of cache entries (`0` keeps current/default behavior).
- **ttl_secs**: entry TTL in seconds (`0` keeps current/default behavior).

#### `odbc_metadata_cache_stats(buffer, buffer_len, out_written) -> int`

Returns cache statistics as UTF-8 JSON.

- **Returns**: `0` on success; `-1` on error; `-2` if `buffer` is too small.

#### `odbc_metadata_cache_clear() -> int`

Clears metadata cache entries.

- **Returns**: `0` on success; non-zero on failure.

### `odbc_catalog_tables(conn_id, catalog, schema, out_buffer, buffer_len, out_written) -> int`

Lists tables from `INFORMATION_SCHEMA.TABLES`.

- **Returns**: `0` on success; `-1` on error; `-2` if buffer too small.
- **catalog** / **schema**: `NULL` or empty = no filter. Non-empty UTF‑8
  null‑terminated strings filter by `TABLE_CATALOG` / `TABLE_SCHEMA`.
- **Output**: Standard binary protocol (columns: TABLE_CATALOG, TABLE_SCHEMA,
  TABLE_NAME, TABLE_TYPE; only BASE TABLE and VIEW).

### `odbc_catalog_columns(conn_id, table, out_buffer, buffer_len, out_written) -> int`

Lists columns for a table from `INFORMATION_SCHEMA.COLUMNS`.

- **Returns**: `0` on success; `-1` on error; `-2` if buffer too small.
- **table**: UTF‑8 null‑terminated. Use `"TABLE_NAME"` or `"schema.TABLE_NAME"`.
- **Output**: Standard binary protocol (columns: TABLE_CATALOG, TABLE_SCHEMA,
  TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, DATA_TYPE, IS_NULLABLE).

### `odbc_catalog_type_info(conn_id, out_buffer, buffer_len, out_written) -> int`

Returns distinct data types from `INFORMATION_SCHEMA.COLUMNS` (minimal type
info; not full ODBC `SQLGetTypeInfo`).

- **Returns**: `0` on success; `-1` on error; `-2` if buffer too small.
- **Output**: Standard binary protocol (single column: `type_name`).

## Transactions

Transactions are implemented with:

- Autocommit control (`set_autocommit(false/true)`)
- `commit()` / `rollback()`
- Isolation level applied via SQL‑92:
  `SET TRANSACTION ISOLATION LEVEL <READ COMMITTED | ...>`

### `odbc_transaction_begin(conn_id, isolation_level, savepoint_dialect) -> unsigned int`

Begins a transaction for an existing connection.

Isolation levels (ODBC mapping):

- `0`: ReadUncommitted
- `1`: ReadCommitted
- `2`: RepeatableRead
- `3`: Serializable

Savepoint dialect (determines SQL syntax for savepoints):

- `0`: SQL-92 (SAVEPOINT, ROLLBACK TO SAVEPOINT, RELEASE SAVEPOINT) — PostgreSQL, MySQL, etc.
- `1`: SQL Server (SAVE TRANSACTION, ROLLBACK TRANSACTION)

Returns `txn_id > 0` on success; `0` on failure.

### `odbc_transaction_commit(txn_id) -> int`

Commits and ends the transaction.

### `odbc_transaction_rollback(txn_id) -> int`

Rolls back and ends the transaction.

### Savepoints

Savepoint operations run inside an active transaction and keep the transaction active.
The SQL syntax depends on the `savepoint_dialect` passed to `odbc_transaction_begin`.

### `odbc_savepoint_create(txn_id, name) -> int`

Creates a savepoint (SAVEPOINT &lt;name&gt; or SAVE TRANSACTION &lt;name&gt; per dialect).

### `odbc_savepoint_rollback(txn_id, name) -> int`

Rolls back to the savepoint (ROLLBACK TO SAVEPOINT or ROLLBACK TRANSACTION per dialect).

### `odbc_savepoint_release(txn_id, name) -> int`

Releases the savepoint (RELEASE SAVEPOINT for SQL-92; no-op for SQL Server).

## Connection pool (r2d2)

### `odbc_pool_create(conn_str, max_size) -> unsigned int`

Creates a pool in global state.

Returns `pool_id > 0` on success; `0` on failure.

### `odbc_pool_get_connection(pool_id) -> unsigned int`

Checks out a pooled connection and stores it in `pooled_connections`.

Returns `pooled_conn_id > 0` on success; `0` on failure.

### `odbc_pool_release_connection(pooled_conn_id) -> int`

Releases the checked-out pooled connection back to the pool. Before return, any active
transaction is rolled back and autocommit is restored (RAII). Prepared statements for
this connection are closed.

### `odbc_pool_health_check(pool_id) -> int`

Returns `1` if pool checkout succeeds, otherwise `0`.

### `odbc_pool_get_state(pool_id, out_size, out_idle) -> int`

Writes pool state:

- `out_size`: total connections
- `out_idle`: idle connections

### `odbc_pool_get_state_json(pool_id, buffer, buffer_len, out_written) -> int`

Writes pool state as UTF-8 JSON into `buffer`. Returns `0` on success; `-1` on error; `-2` if buffer too small.

JSON format:

```json
{
  "total_connections": 10,
  "idle_connections": 8,
  "active_connections": 2,
  "max_size": 10,
  "wait_count": 0,
  "wait_time_ms": 0,
  "max_wait_time_ms": 0,
  "avg_wait_time_ms": 0
}
```

`wait_*` fields are reserved for future instrumentation (r2d2 does not expose them).

### `odbc_pool_set_size(pool_id, new_max_size) -> int`

Resizes the pool by recreating it with the new max size. All connections must be
released before resize. Returns `0` on success; `-1` on error (invalid pool,
connections checked out, or pool creation failed). r2d2 does not support in-place
resize; the pool is recreated with the same connection string.

### `odbc_pool_close(pool_id) -> int`

Closes and removes the pool. Before close, any checked-out connections have their
active transactions rolled back and autocommit restored (RAII). Prepared statements
for those connections are closed. Connections are then invalidated/removed from
global state.

## Bulk insert

### `odbc_bulk_insert_array(conn_id, table, columns, column_count, data_buffer, buffer_len, row_count, rows_inserted) -> int`

Performs bulk insert on a regular connection. When feature `sqlserver-bcp` is enabled, uses
`BulkCopyExecutor` (ArrayBinding path); otherwise uses `ArrayBinding` directly.

- **Returns**: `0` on success; `-1` on failure.
- **Data source**: current implementation reads table/columns/rows from `data_buffer`
  (serialized bulk payload); `table`/`columns`/`column_count`/`row_count` parameters are
  currently ignored by the Rust side.

### `odbc_bulk_insert_parallel(pool_id, table, columns, column_count, data_buffer, buffer_len, parallelism, rows_inserted) -> int`

Performs parallel bulk insert using a pool (`rayon` workers + pooled checkout). Uses
`bulk_insert_payload` (BulkCopyExecutor when `sqlserver-bcp` enabled, else ArrayBinding).
On partial failure, returns consolidated error with chunk indices and rows inserted before failure.

- **Returns**: `0` on success; `-1` on failure.
- **parallelism** must be `>= 1`.
- As above, table/column shape is taken from `data_buffer`.

## Errors

### `odbc_get_error(out_buffer, buffer_len) -> int`

Writes the last error message (UTF‑8) into `out_buffer`.

- **Returns**: bytes written (excluding null terminator), or `-1` on error.

### `odbc_get_structured_error(out_buffer, buffer_len, out_written) -> int`

Writes the last structured error into `out_buffer` (binary encoding).
When the ODBC driver provides diagnostic information, **SQLSTATE** (5 bytes) and
**native error code** (4 bytes LE) are preserved and included in the payload;
otherwise they are zero. Format: `[sqlstate: 5][native_code: 4 LE][message_len: 4 LE][message: N]`.
- **Return behavior**:
  - `0`: structured error written
  - `1`: no structured error available (`out_written = 0`)
  - negative values: failure (e.g., invalid pointers/buffer issues)

### `odbc_get_structured_error_for_connection(conn_id, out_buffer, buffer_len, out_written) -> int`

Same binary format as `odbc_get_structured_error`, but scoped to a specific connection.
Per-connection isolation: when `conn_id != 0`, returns only that connection's error (no global fallback).

- **conn_id**: connection ID; `0` = use global fallback (same as `odbc_get_structured_error`).
- **Return behavior**:
  - `0`: structured error written
  - `1`: no structured error for this connection
  - `-1`: invalid pointers or mutex error
  - `-2`: buffer too small

## Metrics

### `odbc_get_metrics(out_buffer, buffer_len, out_written) -> int`

Writes a fixed 40-byte binary payload (5 little-endian `u64` values):

- query_count
- error_count
- uptime_secs
- total_latency_millis
- avg_latency_millis

### `odbc_get_cache_metrics(out_buffer, buffer_len, out_written) -> int`

Writes a fixed 64-byte payload with prepared-statement cache metrics
(`u64` counters + `f64` for average executions/statement).

### `odbc_clear_statement_cache() -> int`

Clears prepared-statement cache metrics/state.

## Driver helper

### `odbc_detect_driver(conn_str, out_buf, buffer_len) -> int`

Attempts to detect driver family from the connection string and writes the
detected name to `out_buf`.

- **Returns**: `1` if known driver detected; `0` if unknown (writes `"unknown"`).

### `odbc_get_driver_capabilities(conn_str, buffer, buffer_len, out_written) -> int`

Returns driver capabilities as a JSON object, detected heuristically from the
connection string (no active connection required).

- **conn_str**: null-terminated UTF-8 connection string.
- **buffer**: output buffer for JSON payload (UTF-8).
- **buffer_len**: size of buffer.
- **out_written**: actual bytes written.
- **Returns**: `0` on success; `-1` on error (e.g. null pointers, invalid UTF-8).

**JSON schema**:

```json
{
  "supports_prepared_statements": true,
  "supports_batch_operations": true,
  "supports_streaming": true,
  "max_row_array_size": 2000,
  "driver_name": "SQL Server",
  "driver_version": "Unknown"
}
```

**Capabilities by database** (heuristic from connection string):

| driver_name   | max_row_array_size | supports_* |
|---------------|--------------------|------------|
| SQL Server    | 2000               | all true   |
| PostgreSQL    | 2000               | all true   |
| MySQL         | 1500               | all true   |
| Unknown       | 1000               | all true   |

## Minimal usage example (C-style)

```c
int rc = odbc_init();
if (rc != 0) { /* read odbc_get_error */ }

unsigned int conn = odbc_connect("Driver={...};Server=...;UID=...;PWD=...;");
if (conn == 0) { /* read odbc_get_error */ }

unsigned int written = 0;
unsigned char buf[1024 * 1024];
rc = odbc_exec_query(conn, "SELECT 1 AS value", buf, (unsigned int)sizeof(buf), &written);
if (rc != 0) { /* read odbc_get_error */ }

odbc_disconnect(conn);
```

### Parameterized query example (C-style)

```c
/* Build params_buffer: e.g. one Integer(42).
 * Tag 2 = Integer, len 4, then 4 bytes LE of 42. */
unsigned char params_buf[9];
params_buf[0] = 2;                    /* tag Integer */
*(uint32_t *)(params_buf + 1) = 4;    /* len */
*(int32_t *)(params_buf + 5) = 42;    /* value LE */

unsigned int written = 0;
unsigned char out_buf[1024 * 1024];
rc = odbc_exec_query_params(conn, "SELECT ? AS value",
    params_buf, sizeof(params_buf), out_buf, sizeof(out_buf), &written);
if (rc != 0) { /* read odbc_get_error (rc == -2 if buffer too small) */ }
```

## Notes for Dart/Flutter integration

- The FFI functions are designed to work with **pre-allocated buffers**. For large results:
  - prefer `odbc_stream_*` (chunked copy-out) or a larger buffer for `odbc_exec_query`.
- Errors are stored in global state; after any non-zero return / `0` id, call:
  - `odbc_get_error(...)` or `odbc_get_structured_error(...)`.

### Adaptive usage (driver capabilities)

Use `odbc_get_driver_capabilities` to adapt behavior by database:

```dart
final caps = locator.nativeConnection.getDriverCapabilities(connectionString);
if (caps != null && caps.driverName == 'PostgreSQL') {
  // Use PostgreSQL-specific optimizations (e.g. LIMIT, array fetch)
} else if (caps?.driverName == 'SQL Server') {
  // Use SQL Server-specific patterns (e.g. TOP)
}
```


