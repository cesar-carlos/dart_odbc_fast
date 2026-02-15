# FFI API (C ABI) — `odbc_*`

This document describes the public C ABI entrypoints implemented in
`native/odbc_engine/src/ffi/mod.rs`.

The API is **stateful**: most functions interact with a process‑global `GlobalState`.

## Lifecycle

### `odbc_init() -> int`

Initializes the async runtime and the ODBC environment.

- **Returns**: `0` on success; non‑zero on failure.

### `odbc_connect(conn_str: *const c_char) -> unsigned int`

Creates a new ODBC connection and stores it in global state.

- **Returns**: `conn_id > 0` on success; `0` on failure.
- **Errors**: use `odbc_get_error(...)` / `odbc_get_structured_error(...)`.

### `odbc_disconnect(conn_id: unsigned int) -> int`

Disconnects and removes the connection. Also rolls back any active transactions
belonging to that connection.

- **Returns**: `0` on success; non‑zero on failure.

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
- **Output format**: `[count: 4 bytes LE][foreach item: tag(1) + len(4) LE + payload]`. Tag `0` = result set (payload = standard binary protocol); tag `1` = row count (payload = 8 bytes i64 LE). Currently only the **first** result (result set or row count) is returned; full `SQLMoreResults` iteration is planned.

### Prepare / Execute / Cancel / Close (timeout support)

Workflow: `odbc_prepare` → `odbc_execute` (possibly multiple times) → `odbc_close_statement`. Optional `odbc_cancel` to request cancellation (see limitations below).

#### `odbc_prepare(conn_id, sql, timeout_ms) -> unsigned int`

Prepares a statement with optional query timeout.

- **Returns**: `stmt_id > 0` on success; `0` on failure.
- **timeout_ms**: `0` = no timeout; otherwise timeout in milliseconds. Uses ODBC `SQL_ATTR_QUERY_TIMEOUT` where supported (e.g. SQL Server, PostgreSQL).

#### `odbc_execute(stmt_id, params_buffer, params_len, out_buffer, buffer_len, out_written) -> int`

Executes a prepared statement. Same output contract as `odbc_exec_query` / `odbc_exec_query_params`.

- **Returns**: `0` on success; `-1` on error; `-2` if output buffer too small.
- **params_buffer** / **params_len**: Serialized `ParamValue` array; use `NULL` / `0` for no parameters.

#### `odbc_cancel(stmt_id) -> int`

Requests cancellation of a statement **currently executing**. **Limitation**: Full cancel (ODBC `SQLCancel`) requires an active execution context (e.g. background execution). Currently returns non‑zero with an error indicating cancel is not implemented; proper support is planned.

#### `odbc_close_statement(stmt_id) -> int`

Closes the prepared statement and releases resources. **Returns**: `0` on success; non‑zero on failure (e.g. invalid `stmt_id`). Statements for a connection are also removed when that connection is disconnected.

## Streaming (chunked copy-out over FFI)

Streaming provides a way to fetch a large encoded result in pieces without
allocating a huge buffer on the Dart side.

**Two modes:**

1. **Buffer mode** (`odbc_stream_start`): Executes the query, encodes the full
   result in memory, then yields fixed-size chunks. Bounded memory on the Dart
   side; engine holds the full result.

2. **Batched mode** (`odbc_stream_start_batched`): Cursor-based batching. Fetches
   `fetch_size` rows per batch, encodes each batch, and stores only the next
   batch in `BatchedStreamingState`. Memory is bounded in both Rust and Dart.
   Uses a worker thread that holds the HandleManager lock for the stream duration.

Both modes use the same `odbc_stream_fetch` and `odbc_stream_close` APIs.

### `odbc_stream_start(conn_id, sql, chunk_size) -> unsigned int`

Executes `sql`, encodes the entire result to the binary protocol, and creates a
stream handle that can be consumed in chunks (buffer mode).

- **Returns**: `stream_id > 0` on success; `0` on failure.

### `odbc_stream_start_batched(conn_id, sql, fetch_size, chunk_size) -> unsigned int`

Starts **cursor-based batched** streaming. Fetches up to `fetch_size` rows per
batch; each batch is then chunked into `chunk_size`-byte pieces for `odbc_stream_fetch`.

- **Returns**: `stream_id > 0` on success; `0` on failure.
- **fetch_size**: rows per batch (engine-side).
- **chunk_size**: bytes per FFI chunk (same semantics as `odbc_stream_start`).

### `odbc_stream_fetch(stream_id, out_buffer, buffer_len, out_written, out_has_more) -> int`

Fetches the next chunk. Works for both buffer and batched streams.

- **Returns**: `0` on success; non‑zero on failure.
- On success:
  - `out_written` is set to the bytes written for this chunk (may be `0` on EOF).
  - `out_has_more` is set to `1` if there is more, otherwise `0`.

### `odbc_stream_close(stream_id) -> int`

Releases the stream state (buffer or batched).

## Catalog / Metadata

Catalog functions use `INFORMATION_SCHEMA` (TABLES, COLUMNS) and return the same
binary protocol as `odbc_exec_query`. Decode with `BinaryProtocolDecoder`.

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

### `odbc_transaction_begin(conn_id, isolation_level) -> unsigned int`

Begins a transaction for an existing connection.

Isolation levels (ODBC mapping):

- `0`: ReadUncommitted
- `1`: ReadCommitted
- `2`: RepeatableRead
- `3`: Serializable

Returns `txn_id > 0` on success; `0` on failure.

### `odbc_transaction_commit(txn_id) -> int`

Commits and ends the transaction.

### `odbc_transaction_rollback(txn_id) -> int`

Rolls back and ends the transaction.

## Connection pool (r2d2)

### `odbc_pool_create(conn_str, max_size) -> unsigned int`

Creates a pool in global state.

Returns `pool_id > 0` on success; `0` on failure.

### `odbc_pool_get_connection(pool_id) -> unsigned int`

Checks out a pooled connection and stores it in `pooled_connections`.

Returns `pooled_conn_id > 0` on success; `0` on failure.

### `odbc_pool_release_connection(pooled_conn_id) -> int`

Releases the checked-out pooled connection back to the pool.

### `odbc_pool_health_check(pool_id) -> int`

Returns `1` if pool checkout succeeds, otherwise `0`.

### `odbc_pool_get_state(pool_id, out_size, out_idle) -> int`

Writes pool state:

- `out_size`: total connections
- `out_idle`: idle connections

### `odbc_pool_close(pool_id) -> int`

Closes and removes the pool. Any still-checked-out pooled connections must be
released first.

## Errors

### `odbc_get_error(out_buffer, buffer_len, out_written) -> int`

Writes the last error message (UTF‑8) into `out_buffer`.

### `odbc_get_structured_error(out_buffer, buffer_len, out_written) -> int`

Writes the last structured error into `out_buffer` (binary encoding).
When the ODBC driver provides diagnostic information, **SQLSTATE** (5 bytes) and
**native error code** (4 bytes LE) are preserved and included in the payload;
otherwise they are zero. Format: `[sqlstate: 5][native_code: 4 LE][message_len: 4 LE][message: N]`.

## Metrics

### `odbc_get_metrics(out_buffer, buffer_len, out_written) -> int`

Returns a JSON payload with metrics tracked inside the engine.

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


