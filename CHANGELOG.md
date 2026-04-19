# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.2.0] - Multi-result hardening

### Fixed

- **M1 — `execute_multi_result` collected only the first item in 2 of the
  4 batch shapes.** The pre-v3.2 implementation took an
  `if had_cursor { … } else { row_count }` shape that silently dropped
  every result set produced *after* the first one whenever the batch mixed
  cursors and row-counts. Worked for `cursor → cursor → cursor` and
  `row-count → row-count` (kind of — only first), broken for
  `row-count → cursor` and `cursor → row-count`.
  v3.2.0 introduces `collect_multi_results` which walks the full chain via
  raw `Statement::more_results` (`SQLMoreResults`), rebuilding a
  `CursorImpl` whenever `num_result_cols > 0`. Crucially, cursors are
  consumed via `cursor.into_stmt()` instead of being dropped, so
  `SQLCloseCursor` does **not** discard pending result sets.
  Covered by 4 new E2E regression tests under
  `tests/regression/m1_multi_result_batch_shapes.rs`.
- **M2 — `odbc_exec_query_multi` ignored pooled connection IDs.** Same
  bug class as M2 for `odbc_exec_query` in v3.1.1, fixed the same way:
  fall back to `state.pooled_connections` when the id is not in
  `state.connections`.
- **M7 — `MultiResultParser.getFirstResultSet` and
  `QueryResultMulti.firstResultSet` returned a fake empty buffer when the
  batch produced no cursors at all.** Callers had no way to tell "0 rows"
  from "no result set". `getFirstResultSet` now returns
  `ParsedRowBuffer?`. `QueryResultMulti.firstResultSet` is deprecated;
  prefer `firstResultSetOrNull`.

### Added

- **M3 — `MultiResultItem` (Dart) is now a sealed class.** Two variants:
  `MultiResultItemResultSet(value)` and `MultiResultItemRowCount(value)`.
  Pattern-match with Dart 3 `switch`/sealed exhaustiveness:
  ```dart
  switch (item) {
    case MultiResultItemResultSet(:final value): ...
    case MultiResultItemRowCount(:final value): ...
  }
  ```
  The legacy 2-field constructor (`MultiResultItem(resultSet:..., rowCount:...)`)
  is preserved as a deprecated factory for one minor cycle so existing
  code keeps compiling.
- **M4 — Multi-result wire format v2 with magic + version.** Layout:
  `[magic = 0x4D554C54 ("MULT")][version: u16 = 2][reserved: u16 = 0][count: u32]`.
  `decode_multi` (Rust) and `MultiResultParser.parse` (Dart) auto-detect
  v1 (no magic) and v2 (magic + version) framings, so old buffers in any
  storage / cache continue to round-trip without a breaking change.
  `encode_multi` always emits v2 since v3.2.0.
  - New constants: `MULTI_RESULT_MAGIC`, `MULTI_RESULT_VERSION` (Rust),
    `multiResultMagic`, `multiResultVersionV2` (Dart).
  - Legacy `encode_multi_v1` retained for compatibility tests.
- **M5 — Parameterised multi-result batches.** New end-to-end stack:
  - Engine: `execute_multi_result_with_params(conn, sql, &[ParamValue])`.
  - FFI: `odbc_exec_query_multi_params(conn_id, sql, params, params_len, ...)`.
  - Dart: `OdbcNative.execQueryMultiParams`,
    `NativeOdbcConnection.executeQueryMultiParams`,
    `AsyncNativeOdbcConnection.executeQueryMultiParams`,
    `IOdbcRepository.executeQueryMultiParams`,
    `IOdbcService.executeQueryMultiParams`,
    `TelemetryOdbcServiceDecorator.executeQueryMultiParams`,
    `ExecuteQueryMultiParamsRequest` worker message.
  Up to 5 positional `?` parameters are supported (same arity ceiling as
  the existing `executeQueryParams`). Both connection IDs and pooled IDs
  are accepted.
- **M6 ergonomics — `OdbcRepositoryImpl.executeQueryMulti` (single)** now
  unwraps the first result set via `firstResultSetOrNull`, returning a
  truly empty `QueryResult` only when the batch had zero cursors.

### Internal

- `ExecutionEngine::encode_cursor` now takes `&mut C` instead of consuming
  the cursor, so the multi-result paths can call `cursor.into_stmt()`
  afterwards to preserve pending result sets.
- 6 new lib unit tests in `protocol::multi_result::tests` (v2 framing
  round-trip, legacy v1 acceptance, version rejection, truncated header).

### Migration notes

- 100% backwards compatible at the source level. Existing callers that
  built `MultiResultItem(resultSet: ..., rowCount: ...)` directly keep
  compiling thanks to the deprecated factory.
- Wire-level: any pre-v3.2 buffer (v1 framing) still decodes; v3.2 emits
  v2 framing which includes a magic word and a version byte. Storage /
  cache schemes that round-trip the buffer through e.g. Redis are
  unaffected.
- Sealed-class migration path: callers using the runtime checks
  (`item.resultSet != null`) still work via the backward-compatible
  accessors. Dart 3 callers are encouraged to migrate to pattern matching
  with the new variants for compile-time exhaustiveness.

### Tests

- Lib: 846 passed (was 842) / 0 failed / 16 ignored.
- regression_test: 78 passed / 0 failed / 4 ignored (the new
  `m1_multi_result_batch_shapes` tests are gated by `ENABLE_E2E_TESTS=1`).
- Dart unit (`test/{application,domain,infrastructure,core,helpers}`):
  418 passed / 0 failed / 3 skipped.
- `cargo clippy --all-targets --all-features -- -D warnings`: 0 warnings.
- `dart analyze lib test`: No issues found.

## [3.1.1] - E2E test stability fixes

### Fixed

- **`odbc_exec_query` ignored pooled connection IDs.** The function only
  looked up `state.connections` and returned `Invalid connection ID` for any
  id handed out by `odbc_pool_get_connection`. Brought the function in line
  with `odbc_exec_query_params`, `odbc_prepare` and the other paths that
  already accept both kinds of id (B added in v3.1.1).
- **`test_ffi_pool_release_raii_rollback_autocommit` could not exercise the
  RAII path on SQL Server.** It tried to dirty the connection with
  `odbc_exec_query("BEGIN TRANSACTION")` which SQL Server rejects with
  SQLSTATE 25000 / native error 266 ("mismatching number of BEGIN and
  COMMIT statements") because `SQLExecute` runs in autocommit-on mode by
  default. The test now flips `set_autocommit(false)` directly on the live
  pooled `Connection` (the same path `Transaction::begin` uses) and
  asserts that the next checkout observes a clean connection thanks to
  `PoolAutocommitCustomizer.on_acquire`.
- **`test_ffi_execute_retry_after_buffer_too_small_does_not_reexecute_side_effect_sql`
  used a SQL Server local temp table (`#name`).** Local temp tables are
  scoped per **physical** session, and the ODBC Driver Manager may
  multiplex several physical sessions over a single logical `Connection`,
  so the temp table was missing on the second statement. Switched to a
  permanent table named `ffi_exec_retry_guard_<pid>` plus an
  `INSERT … OUTPUT REPLICATE('X', 6000)` that returns a single result set
  (so `odbc_exec_query` actually sees the 6000-byte payload) while still
  proving the no-re-execute property via PRIMARY KEY constraint.
- **`tests/helpers/env.rs` got 4 broken assertions when `ODBC_TEST_DSN`
  pointed at SQL Server.** `get_postgresql_test_dsn` / `_mysql` / `_oracle`
  / `_sybase` all fall back to the global `ODBC_TEST_DSN`, but the tests
  asserted that the returned string contained the corresponding driver
  name (e.g. `"MySQL"`). When the developer only exports a single
  `ODBC_TEST_DSN` for SQL Server (the typical setup), all four asserts
  failed. They now skip gracefully when the available DSN points at a
  different engine, and only run for real when a per-engine env var is
  configured (or a multi-DB CI matrix is in place).

### Tests

- Lib: 858 passed / 0 failed / 0 ignored (was 856 / 2 / 0 with
  `--include-ignored`).
- regression_test: 78 passed.
- cell_reader_test: 32 passed (was 28 / 4).
- transaction_test: 16 passed.
- ffi_compatibility_test: 14 passed.
- `cargo clippy --all-targets --all-features -- -D warnings`: 0 warnings.

## [3.1.0] - Transaction control hardening

### Fixed

- **B1 / closes A1 regression via FFI** — `odbc_savepoint_create`,
  `odbc_savepoint_rollback` and `odbc_savepoint_release` no longer build SQL
  with `format!("SAVEPOINT {}", name)`. They now route through
  `Transaction::savepoint_create / _rollback_to / _release`, which run
  `validate_identifier` + `quote_identifier` for the active dialect. A
  savepoint name like `"sp; DROP TABLE x--"` arriving over the FFI is now
  rejected with `ValidationError` instead of being executed.
- **B2** — Dart could not reach the SQL Server savepoint dialect.
  `OdbcNative.transactionBegin` now exposes `savepointDialect` (default `0`
  = `SavepointDialect.auto`); the dialect propagates through
  `AsyncNativeOdbcConnection`, `BeginTransactionRequest`,
  `OdbcRepositoryImpl`, `IOdbcService.beginTransaction` and
  `TelemetryOdbcServiceDecorator`.
- **B4** — `Transaction::begin_with_dialect` no longer fires
  `SET TRANSACTION ISOLATION LEVEL <X>` blindly. The new
  `IsolationStrategy::for_engine` dispatches per `engine_id`:
  - SQL-92 dialect → `SET TRANSACTION ISOLATION LEVEL <X>` (SQL Server,
    PostgreSQL, MySQL, MariaDB, Sybase, Redshift, …).
  - SQLite → `PRAGMA read_uncommitted = 0|1`.
  - Db2 → `SET CURRENT ISOLATION = UR|CS|RS|RR`.
  - Oracle → only `READ COMMITTED` and `SERIALIZABLE`; the other two now
    return `ValidationError` instead of erroring at the driver.
  - Snowflake → silent skip (engine has no per-tx isolation).
- **B7** — `Transaction::commit` and `rollback` always attempt
  `set_autocommit(true)`, even when the underlying commit/rollback fails.
  Connections can no longer be returned to the caller stuck in
  `autocommit=off`.

### Added

- **`SavepointDialect::Auto`** (Rust) and `SavepointDialect.auto` (Dart) —
  resolved at `Transaction::begin` via `DbmsInfo::detect_for_conn_id`
  (`SQLGetInfo`). SQL Server resolves to `SqlServer`; everything else
  (PostgreSQL, MySQL, MariaDB, Oracle, SQLite, Db2, Snowflake, …) to
  `Sql92`. Wire mapping (stable):
  - `0` → `Auto` (default, recommended)
  - `1` → `SqlServer`
  - `2` → `Sql92`
- **`Transaction::savepoint_create / savepoint_rollback_to /
  savepoint_release`** — new public Rust methods that validate the name and
  emit the right SQL for the transaction's dialect (including the `RELEASE`
  no-op on SQL Server). `Savepoint::create / rollback_to / release` are now
  thin shims over them.
- **`TransactionHandle.runWithBegin(beginFn, action)`** (Dart) — static
  helper that opens a transaction, runs `action`, commits on success and
  rolls back on **any** thrown exception. Mirrors `Transaction::execute` on
  the Rust side and is the recommended way to write leak-proof transaction
  code in Dart.
- **`TransactionHandle.withSavepoint(name, action)`** (Dart) — runs `action`
  inside a named savepoint, releasing on success and rolling back to the
  savepoint on exception (transaction stays active).
- **`TransactionHandle.createSavepoint / rollbackToSavepoint /
  releaseSavepoint`** (Dart) — the wrapper now exposes the full savepoint
  surface so callers do not need to skip down to `OdbcService`.
- **`TransactionHandle implements Finalizable`** (Dart) — best-effort
  `NativeFinalizer` reclaims the small token allocated for tracking when the
  Dart object is GC'd without explicit commit/rollback. The transaction
  itself is rolled back by the engine in `odbc_disconnect`.
- **`Transaction::for_test_no_conn`** (Rust, `#[doc(hidden)]`) — convenience
  constructor for integration tests that exercise validation paths without
  a real connection.

### New tests

- `tests/regression/a1_ffi_savepoint_injection.rs` — 6 new tests covering
  every malicious-name case across both dialects, plus the `Auto` default.
- 4 new lib unit tests in `engine::transaction::tests` covering the new
  Db2 keyword, the SqlServer no-op `release`, the `from_u32` Auto default
  and identifier validation through the new methods.

### Documentation

- `example/transaction_helpers_demo.dart` — NEW demo showcasing
  `runWithBegin`, `withSavepoint` and the `SavepointDialect` wire codes.
- `example/savepoint_demo.dart` — updated to reference v3.1 helpers and
  point to the new demo.
- `example/README.md` — new entry under "Transactions / savepoints".

### Migration notes

- 100% backwards compatible at the source level. Existing callers that pass
  no `savepointDialect` keep working: they now use `Auto` instead of
  `Sql92`, which produces **identical SQL on every engine except SQL Server**
  (where the new behaviour is the correct one).
- Wire-level: the FFI default for the third argument of
  `odbc_transaction_begin` changed from `Sql92` to `Auto`. C callers passing
  the explicit literal `1` (= `SqlServer`) keep working unchanged. Callers
  that previously relied on the default value `0` to mean `Sql92` should
  pass `2` if they need the explicit pre-v3.1 behaviour, but typically just
  benefit from the new auto-detection.

### Added (v3.0.0)

- **Seven new capability traits** (SOLID design, opt-in by plugin):
  - `BulkLoader` — native bulk insert path per engine.
  - `Upsertable` — dialect-specific INSERT-OR-UPDATE SQL builder.
  - `Returnable` — append RETURNING / OUTPUT clause to DML.
  - `TypeCatalog` — extended type mapping using DBMS `TYPE_NAME`.
  - `IdentifierQuoter` — per-driver identifier quoting style.
  - `CatalogProvider` — driver-specific schema introspection SQL.
  - `SessionInitializer` — post-connect setup statements.
  - Lives in [`plugins/capabilities/`](native/odbc_engine/src/plugins/capabilities).
- **Four new driver plugins**:
  - `SqlitePlugin` — `ON CONFLICT`, `RETURNING`, PRAGMA setup, sqlite_master catalog.
  - `Db2Plugin` — `MERGE`, `FROM FINAL TABLE`, SYSCAT catalog, FETCH FIRST n ROWS.
  - `SnowflakePlugin` — `MERGE`, `RETURNING`, VARIANT/OBJECT/ARRAY type mapping, QUERY_TAG.
  - `MariaDbPlugin` — `RETURNING` (MariaDB-only), backtick quoting, UUID type.
- **Twelve new `OdbcType` variants**:
  `NVarchar`, `TimestampWithTz`, `DatetimeOffset`, `Time`, `SmallInt`,
  `Boolean`, `Float`, `Double`, `Json`, `Uuid`, `Money`, `Interval`.
- **Three new FFI entry points**:
  - `odbc_build_upsert_sql(conn_str, table, payload_json, ...)`
  - `odbc_append_returning_sql(conn_str, sql, verb, columns_csv, ...)`
  - `odbc_get_session_init_sql(conn_str, options_json, ...)`
- **Dart bindings**: `OdbcDriverFeatures` (in
  [`lib/infrastructure/native/driver_capabilities_v3.dart`](lib/infrastructure/native/driver_capabilities_v3.dart))
  with typed `buildUpsertSql`, `appendReturningClause`, `getSessionInitSql`,
  plus `DmlVerb` enum and `SessionOptions` class.
- New regression suites under
  [`native/odbc_engine/tests/regression/`](native/odbc_engine/tests/regression):
  `v30_capabilities`, `v30_upsert_dialects`, `v30_returning_dialects`,
  `v30_session_init`.
- **Documentation**: [`doc/CAPABILITIES_v3.md`](doc/CAPABILITIES_v3.md)
  with the full capability × engine matrix.

### Changed (v3.0.0)

- `PluginRegistry::detect_driver` now uses
  `DriverCapabilities::detect_from_connection_string` to map the connection
  string to a canonical engine id, then to a registered plugin id. MariaDB
  now has its own dedicated plugin instead of falling back to `mysql`.
- `from_odbc_sql_type` recognises additional SQL_* type codes
  (`SQL_TYPE_TIME`=92, `SQL_TYPE_DATE`=91, `SQL_GUID`=−11,
  `SQL_WCHAR/WVARCHAR/WLONGVARCHAR`=−8/−9/−10, `SQL_BIT`=−7, `SQL_REAL`=7,
  `SQL_FLOAT/SQL_DOUBLE`=6/8, `SQL_TINYINT`=−6, `NUMERIC`=2).

### Added (v2.1.0 — included in this release)

- **Live DBMS detection via `SQLGetInfo`** (resolves the v2.0 limitation where
  `DriverCapabilities::detect(_conn)` returned `default()`):
  - New `engine::DbmsInfo` struct with `dbms_name`, canonical `engine` id,
    `max_*_name_len`, `current_catalog` and embedded `DriverCapabilities`.
  - New `OdbcConnection::dbms_info()` and `OdbcConnection::driver_capabilities()`
    helpers that consult the live driver instead of parsing the connection string.
  - New FFI `odbc_get_connection_dbms_info(conn_id, buffer, buffer_len, out_written)`
    returning JSON with the live DBMS information.
  - `DriverCapabilities::detect(conn)` now actually queries the driver via
    `database_management_system_name()` and populates `engine` plus the
    server-reported `driver_name`.
- **Canonical engine ids** (`engine::core::ENGINE_*` constants):
  `sqlserver`, `postgres`, `mysql`, `mariadb`, `oracle`, `sybase_ase`,
  `sybase_asa`, `sqlite`, `db2`, `snowflake`, `redshift`, `bigquery`,
  `mongodb`, `unknown`. Stable across releases; exposed in JSON payloads
  under the new `engine` field.
- `PluginRegistry::plugin_id_for_dbms_name`,
  `PluginRegistry::get_for_dbms_name` and
  `PluginRegistry::get_for_live_connection` resolve plugins from the
  server-reported DBMS name (or the live connection itself) — MariaDB
  correctly falls back to the MySQL plugin.
- `DriverCapabilities::from_driver_name` now recognises:
  - `Microsoft SQL Server` (full Windows DBMS name)
  - `MariaDB` (distinct from MySQL)
  - `Adaptive Server Anywhere` and `Adaptive Server Enterprise`
    (distinct Sybase variants)
  - `IBM Db2`, `Snowflake`, `Amazon Redshift`, `Google BigQuery`
  - All `ENGINE_*` canonical ids round-trip
- Dart side:
  - `DatabaseEngineIds` constants matching the Rust ids.
  - `DatabaseType.fromEngineId(id)` (preferred over `fromDriverName` when
    the canonical id is available).
  - New enum values `DatabaseType.{mariadb, sybaseAse, sybaseAsa, db2,
    snowflake, redshift, bigquery, mongodb}`. The legacy `DatabaseType.sybase`
    is kept as a deprecated alias for `sybaseAse`.
  - `DbmsInfo` typed wrapper for the new FFI JSON payload.
  - `OdbcDriverCapabilities.getDbmsInfoForConnection(connId)` consumes the
    new FFI.
  - Raw `odbc_get_connection_dbms_info` binding in
    `lib/infrastructure/native/bindings/odbc_bindings.dart`.

### Changed

- `engine` field is now part of every `DriverCapabilities` JSON payload
  produced by `odbc_get_driver_capabilities`. Old clients ignore the extra
  field; new clients read it for accurate engine identification.
- `PluginRegistry::detect_driver` keeps its connection-string heuristic
  but is no longer the sole detection path — prefer
  `get_for_live_connection(conn)` once the connection is open.

### Removed

- _None_

### Fixed

- The audit gap "DSN-only connection strings always classified as `Unknown`"
  is resolved on the live-connection path: `odbc_get_connection_dbms_info`
  consults `SQL_DBMS_NAME` directly, which is populated by the Driver
  Manager for DSN-only strings.
- `MariaDB` is no longer silently classified as `MySQL`.
- `Adaptive Server Anywhere` and `Adaptive Server Enterprise` are no longer
  conflated.

## [2.0.0] - 2026-04-18

Hardening release driven by a full security and reliability audit. All
audited critical and high-severity findings are addressed. The Dart FFI ABI
is preserved (no client-side rebuilds required); only internal Rust APIs
have breaking adjustments.

### Added

- `ffi::guard` module with `call_int`/`call_ptr`/`call_id`/`call_size`
  helpers and `ffi_guard_int!`/`ffi_guard_id!`/`ffi_guard_ptr!` macros.
  Wrap any `extern "C"` body in these helpers so panics never unwind across
  the FFI boundary (resolves audit C1).
- `engine::identifier` module with `validate_identifier`,
  `quote_identifier`, `quote_identifier_default`, `quote_qualified_default`
  and `IdentifierQuoting` enum. Used by `Savepoint`/`ArrayBinding` to defeat
  SQL injection vectors (resolves A1, A2).
- `observability::SpanGuard` RAII helper; spans are now finished even on
  early `?` returns or panics (resolves A3).
- `observability::sanitize_sql_for_log` masks SQL literals before logging.
  Set `ODBC_FAST_LOG_RAW_SQL=1` to opt into raw logging in dev (A8).
- `protocol::bulk_insert::is_null_strict` plus length validation in
  `parse_bulk_insert_payload`. Truncated null bitmaps are now rejected as
  malformed payloads instead of being silently treated as "not null" (C9).
- `protocol::bulk_insert::MAX_BULK_COLUMNS`, `MAX_BULK_ROWS`,
  `MAX_BULK_CELL_LEN` resource caps to bound memory on hostile payloads
  (M2).
- `engine::core::ParallelMode` enum with `Independent` and
  `PerChunkTransactional` variants for `ParallelBulkInsert`. Per-chunk
  atomicity option (C8).
- `OdbcError` variants `NoMoreResults`, `MalformedPayload`,
  `RollbackFailed`, `ResourceLimitReached`, `Cancelled`, `WorkerCrashed`
  and `BulkPartialFailure { rows_inserted_before_failure, failed_chunks,
  detail }` for structured error reporting.
- `SecureBuffer::with_bytes` zeroises the buffer after the closure runs
  (resolves C5).
- `SecretManager::with_secret` borrows secret bytes without cloning (M12).
- `PluginRegistry::is_supported` introspection helper.
- `PoolOptions::connection_timeout` field for configurable acquire timeout
  (resolves A9 baseline).
- Pool now installs a `PoolAutocommitCustomizer` that forces
  `set_autocommit(true)` on every checkout regardless of
  `test_on_check_out` (resolves A14).
- `bench_baselines/v1.2.1.txt` placeholder for benchmark comparisons.
- New regression test suite under
  `native/odbc_engine/tests/regression/` covering the new safety helpers,
  identifier validation, span lifecycle, and bitmap corruption.

### Changed

- `OdbcError::sqlstate` is now used for structured "no more results"
  detection instead of substring matching on `e.to_string()` (resolves
  A13).
- `Savepoint::create` / `rollback_to` / `release` now validate and quote
  the savepoint name using `quote_identifier` (resolves A1).
- `ArrayBinding::bulk_insert_*` methods now quote table and column names
  via `quote_qualified_default`/`quote_identifier_default` (resolves A2).
- `Transaction::Drop` and `Transaction::execute` now log rollback failures
  via `log::error!` with conn id and source error context instead of using
  silent `let _ = ...` (resolves M3).
- `DiskSpillStream` gains an `impl Drop` that removes orphan temp files,
  preventing leaks on panic or early return (resolves M4).
- `StreamingStateFileBacked::fetch_next_chunk` now uses `read_exact`
  instead of a single `read`, so partial reads on Windows do not silently
  truncate chunks (resolves A6).
- `BatchedStreamingState`/`AsyncStreamingState::fetch_next_chunk`: receiver
  disconnect is now reported as `OdbcError::WorkerCrashed` instead of
  being treated as a clean EOF (resolves A5).
- `odbc_pool_get_connection` no longer holds the global state lock while
  calling `r2d2::Pool::get()`; the `Arc<ConnectionPool>` is cloned and
  the lock released before the blocking acquire, eliminating up to a
  30-second global stall per checkout (resolves C3).
- `odbc_pool_close` drains live checkouts before removing the pool entry,
  avoiding a deadlock when other code paths drop their wrappers after the
  map has been mutated (resolves C4).
- `odbc_stream_fetch` no longer panics with `expect("pending stream chunk
  exists")` when a pending chunk vanishes between length check and
  removal; returns `-1` with a structured error message instead (part of
  C1 hardening).
- `PluginRegistry::get_for_connection` now logs a warning when
  `detect_driver` resolves a name that is not registered (e.g. `mongodb`,
  `sqlite`), instead of silently returning `None` (resolves A7).
- `PluginRegistry::default` now logs registration failures via
  `log::error!` instead of using `unwrap_or_default` to swallow them (M15).
- `security::sanitize_connection_string` now respects ODBC `{...}`
  quoting and recognises additional secret keys: `secret`, `token`,
  `apikey`, `api_key`, `accesstoken`, `access_token`, `authorization`,
  `auth`, `sas`, `sastoken`, `sas_token`, `connectionstring`,
  `primarykey`, `secondarykey` (resolves M10).
- `protocol::bulk_insert::serialize_bulk_insert_payload` now uses
  `try_into` for length conversions and emits `OdbcError::MalformedPayload`
  on overflow instead of silent `as u32` truncation (resolves M8).
- `versioning::ApiVersion::current` now reads
  `env!("CARGO_PKG_VERSION")` instead of hardcoded `0.1.0` (resolves M17).
- Bumped Rust crate `odbc_engine` and Dart package `odbc_fast` from
  1.x → 2.0.0.

### Deprecated

- `SecureBuffer::into_vec` is deprecated. The returned `Vec<u8>` is no
  longer zeroised on drop. Prefer `SecureBuffer::with_bytes` for
  short-lived consumers (resolves C5).

### Fixed

- C1 — `odbc_stream_fetch` `expect`/`unwrap` no longer crosses FFI.
- C3 — Global mutex no longer held during `r2d2.get()` blocking call.
- C4 — `odbc_pool_close` drains checkouts before removing the pool entry.
- C5 — `SecureBuffer` exposes a zeroising consumer API.
- C6 — `execute_multi_result` now uses structured SQLSTATE detection for
  end-of-results (full row-count → multi-result handling deferred to v2.1
  with a refactored statement adapter).
- C9 — Truncated null bitmaps in bulk-insert payloads are now rejected.
- A1, A2 — Identifier interpolation in dynamic SQL is whitelisted +
  quoted.
- A3 — Span lifecycle bound to RAII guard, no leaks on early returns.
- A5 — Streaming receiver disconnect is now an explicit error.
- A6 — Disk-spill reads use `read_exact` to avoid short reads.
- A7 — Driver detection consistency surfaced via warning + new
  `is_supported` helper.
- A8 — SQL literals are masked in logs by default.
- A9 — `PoolOptions::connection_timeout` exposes acquire timeout.
- A13 — Structured `02000` SQLSTATE check replaces substring detection.
- A14 — `PoolAutocommitCustomizer` forces `autocommit(true)` per checkout.
- M3 — Transaction rollback failures are logged with context.
- M4 — Disk-spill orphan files cleaned up on drop.
- M8 — Wire-format length casts return errors on overflow.
- M10 — Connection-string sanitiser handles `{...}` and more keys.
- M12 — Secret retrieve dedup helper avoids extra heap copy.
- M15 — Registry default logs (rather than swallows) registration errors.
- M17/M18 — `ApiVersion::current` reads from `Cargo.toml`.

### Notes

- The pre-existing flaky test `ffi::tests::test_ffi_get_structured_error`
  (race in global state across tests) was not introduced by this release
  but should be fixed in v2.1 as part of the granular-locks rework.
- True chunk-by-chunk streaming (audit C7) and full row-count → multi-
  result handling (full C6) require a deeper refactor of the streaming
  worker and a new statement-adapter abstraction; tracked for v2.1.

## [1.2.1] - 2026-03-10

### Fixed

- FFI buffer-retry reliability hardening:
  - preserved stream chunks across `-2` retries in `odbc_stream_fetch`
  - preserved async payloads across `-2` retries in `odbc_async_get_result`
  - avoided re-execution for `-2` retries by serving pending payloads in:
    `odbc_exec_query`, `odbc_exec_query_params`, `odbc_exec_query_multi`,
    and `odbc_execute`
  - fixed `odbc_get_driver_capabilities` to return `-2` (instead of truncating
    JSON with success)
- Added regression coverage for retry semantics in stream, async, and execute
  paths (including side-effect safety check for prepared execute retry).
- Removed CI flakiness in async invalid-request tests by avoiding ID collision
  between `TEST_INVALID_ID` and generated invalid test IDs.

## [1.2.0] - 2026-03-10

### Added

- Schema reflection API for primary keys, foreign keys, and indexes:
  - `catalogPrimaryKeys(connectionId, table)` - Lists primary keys for a table
  - `catalogForeignKeys(connectionId, table)` - Lists foreign keys for a table
  - `catalogIndexes(connectionId, table)` - Lists indexes for a table
    (PRIMARY KEY and UNIQUE constraints)
- FFI exports: `odbc_catalog_primary_keys`, `odbc_catalog_foreign_keys`,
  `odbc_catalog_indexes`
- Full implementation from Rust engine -> FFI -> Dart bindings -> Repository ->
  Service
- Type mapping documentation consolidated:
  - Added "Type Mapping" section to README with implemented vs planned status
  - `doc/notes/TYPE_MAPPING.md` updated with verified implementation status
  - `columnar_protocol.dart` marked as experimental/not used
- Example: `example/catalog_reflection_demo.dart`
- Experimental typed parameter prototype:
  - `SqlDataType`, `SqlTypedValue`, and `typedParam(...)`
- Protocol performance benchmark suite:
  - `test/performance/protocol_performance_test.dart`

### Changed

- Reliability/performance hardening completed:
  - fail-fast nullability and per-type validation in `BulkInsertBuilder.addRow()`
  - text validation by character and UTF-8 byte length
  - canonical `double` mapping to fixed-scale decimal string
  - `DateTime` year range validation (`1..9999`)
  - complex unsupported-type error message construction via `StringBuffer`
- Documentation cleanup:
  - removed completed execution plans from `doc/notes/`
  - added `Validation examples` section in root `README.md`

### Removed

- Orphaned `native/telemetry/` directory (not compiled in workspace; actual
  implementation is in `native/odbc_engine/src/observability/telemetry/`)

### Fixed

- Streaming integration stability and cleanup:
  - unique dynamic test tables and safer assertions
- CI reliability:
  - Rust fmt alignment and test thread safety adjustments

## [1.1.2] - 2026-03-03

### Added

- `workflow_dispatch` support in publish workflow for manual pub.dev publishing

## [1.1.1] - 2026-03-03

### Changed

- Documentation updates and release automation alignment

## [1.1.0] - 2026-02-19

### Added

- Statement cancellation API exposed at high-level service/repository layers:
  `cancelStatement(connectionId, stmtId)`
- `UnsupportedFeatureError` in Dart domain errors for explicit unsupported capability reporting

### Changed

- Statement cancellation contract standardized as explicit unsupported at runtime
  (Option B path), with structured native error SQLSTATE `0A000`
- Sync and async cancellation paths now aligned with equivalent behavior and
  consistent unsupported semantics
- Canonical docs aligned for cancellation status and workaround guidance:
  `README.md`, `doc/TROUBLESHOOTING.md`, `example/README.md`

### Fixed

- Removed ambiguity between exposed cancellation entrypoints and current runtime
  capability by returning explicit unsupported contract instead of implicit behavior

## [1.0.3] - 2026-02-16

### Added

- New canonical type mapping documentation: `doc/TYPE_MAPPING.md`
- New implementation checklists:
  - `doc/notes/TYPE_MAPPING_IMPLEMENTATION_CHECKLIST.md`
  - `doc/notes/STATEMENT_CANCELLATION_IMPLEMENTATION_CHECKLIST.md`
  - `doc/notes/NULL_HANDLING_RELIABILITY_PERFORMANCE_PLAN.md`
- New/updated example coverage docs and demo files for advanced/service/telemetry scenarios

### Changed

- Root and docs indexes now reference canonical type-mapping documentation
- Master gaps plan now tracks open execution checklists for remaining gaps

### Fixed

- Documentation consistency across root README, `doc/README.md`, and notes references

## [1.0.2] - 2026-02-15

### Added

- **Documentation enhancement**: Expanded examples section with detailed feature overview and advantages for each API level (High-Level, Low-Level, Async, Named Parameters, Multi-Result, Pooling, Streaming, Savepoints)

### Changed

- _None_

### Fixed

- _None_

## [1.0.1] - 2026-02-15

### Added

- _Test release for automated publishing_

### Changed

- _None_

### Fixed

- _None_

## [1.0.0] - 2026-02-15

### Added

- **Async API request timeout**: `AsyncNativeOdbcConnection(requestTimeout: Duration?)` — optional timeout per request; default 30s; `Duration.zero` or `null` disables
- **AsyncError** new codes: `requestTimeout` (worker did not respond in time), `workerTerminated` (disposed or crashed)
- **Parallel bulk insert (pool-based) end-to-end**: Rust FFI `odbc_bulk_insert_parallel` now implemented and exposed in Dart sync/async service/repository stack
- **Bulk insert comparative benchmark**: new ignored Rust E2E benchmark test `e2e_bulk_compare_benchmark_test` for `ArrayBinding` vs `ParallelBulkInsert`

### Changed

- **Async dispose**: Pending requests now complete with `AsyncError` (workerTerminated) instead of hanging when `dispose()` is called
- **Worker crash handling**: When the worker isolate dies, pending requests complete with error instead of hanging
- **BinaryProtocolParser**: Truncated buffers now throw `FormatException('Buffer too small for payload')` instead of `RangeError`

### Fixed

- **Array binding tail chunk panic**: fixed `copy_from_slice` length mismatch when the final bulk-insert chunk is smaller than configured batch size

## [0.3.1] - 2026-01-29

### Changed

- **Improved download experience**: Native library download now includes retry
  logic with exponential backoff (up to 3 attempts)
- **Better error messages**: Download failures now show detailed troubleshooting
  steps and clearly explain what went wrong
- **HTTP 404 handling**: When GitHub release doesn't exist, provides clear
  instructions for production vs development scenarios
- **Connection timeout**: Added 30-second timeout to HTTP client to prevent
  hanging on slow connections
- **Download feedback**: Shows file size after successful download
- **CI/pub.dev detection**: Skip download in CI environments to avoid analysis
  timeout, with clear logging

### Fixed

- **pub.dev analysis timeout**: Hook now detects CI/pub.dev environment and
  skips external download, allowing pub.dev to analyze the package correctly

## [0.3.0] - 2026-01-29

### Added

- **Configurable result buffer size**: `ConnectionOptions.maxResultBufferBytes` (optional). When set at connect time, caps the size of query result buffers for that connection; when null, the package default (16 MB) is used. Use for large result sets to avoid "Buffer too small" errors. Constant `defaultMaxResultBufferBytes` is exported for reference.

## [0.2.9] - 2026-01-29

### Fixed

- **Async API "QueryError: No error"**: when executing queries with no parameters, the Dart FFI was passing `null` for the params buffer to `odbc_exec_query_params`, which caused invalid arguments and led to failures reported as "No error". The native bindings now always pass a valid buffer (e.g. `Uint8List(0)`) instead of `null`, so both sync and async (worker) paths work correctly for parameterless queries.

## [0.2.8] - 2026-01-29

### Added

- `scripts/copy_odbc_dll.ps1`: copies `odbc_engine.dll` from package (pub cache) to project root and Flutter runner folders (Debug/Release) for consumers who need the DLL manually

### Changed

- Publish `hook/` and `scripts/` in the package (removed from `.pubignore`): Native Assets hook runs for consumers so the DLL can be downloaded/cached automatically; script `copy_odbc_dll.ps1` is available in the package
- Minimum SDK constraint raised to `>=3.6.0` (required by pub.dev when publishing packages with build hooks)

### Fixed

- Async API (worker isolate): empty result (DDL/DML, SELECT with no rows) is now returned as `Result.ok(QueryResult(columns: [], rows: [], rowCount: 0))` instead of `Result.err(QueryError("No error", ...))` (fixes "No error" when executing CREATE TABLE, INSERT, ALTER, etc.)

## [0.2.7] - 2026-01-29

### Fixed

- Native DLL cache now keyed by package version (`~/.cache/odbc_fast/<version>/`) to avoid loading an older DLL when upgrading the package (fixes symbol lookup error 127 for new symbols e.g. `odbc_savepoint_create`)

## [0.2.6] - 2026-01-29

### Added

- README: "Support the project" section with Pix (buy developer a coffee)

### Changed

- Exclude `test/my_test/` from pub package via `.pubignore` (domain-specific tests)
- README: installation example updated to `^0.2.6`

## [0.2.5] - 2026-01-29

### Added

- Database type detection in tests: `detectDatabaseType()`, `skipIfDatabase()`, `skipUnlessDatabase()`
- Test helpers for conditional execution by database (SQL Server, PostgreSQL, MySQL, Oracle)
- `test/helpers/README.md` with usage and examples

### Changed

- Dart tests run sequentially (`--concurrency=1`) to avoid resource contention (ServiceLocator, worker isolates)
- Savepoint release test skipped on SQL Server (RELEASE SAVEPOINT not supported)

### Fixed

- Rust FFI E2E: `ffi_test_dsn()` loads `.env` and checks `ENABLE_E2E_TESTS`; invalid stream ID race in tests
- Dart integration test timeouts when running in parallel

## [0.2.4] - 2026-01-27

### Added

- Examples: multi-result, timeouts, typed params, and low-level wrappers

### Changed

- README: refresh API coverage and fix broken links

## [0.2.3] - 2026-01-27

### Changed

- CI: run only unit tests that do not require real ODBC connection (domain, protocol, errors)
- CI: exclude stress, integration/e2e, and native-dependent tests from publish pipeline

## [0.2.2] - 2026-01-27

### Changed

- Version bump for release

## [0.2.1] - 2026-01-27

### Fixed

- Fixed Native Assets hook to read package version from correct pubspec.yaml
- Fixed test helper to properly handle empty environment variables
- Fixed GitHub Actions cache paths and key format

### Changed

- Improved CI workflow: now builds Rust library before running tests
- Split unit and integration tests in CI for better organization
- Enhanced GitHub Actions workflows with proper dependency installation

## [0.2.0] - 2026-01-27

### Added

- Savepoints (nested transaction markers)
- Automatic retry with exponential backoff for transient errors
- Connection timeouts (login/connection timeout configuration)
- Connection String Builder (fluent API)
- Backpressure control in streaming queries

### Changed

- Async API with worker isolate for non-blocking operations
- Comprehensive E2E Rust tests with coverage reporting
- Improved documentation and troubleshooting guides

### Fixed

- Various lint issues (very_good_analysis compliance)
- Code formatting and cleanup

## [0.1.6] - 2025-12-XX

### Added

- Initial stable release
- Core ODBC functionality
- Streaming queries
- Connection pooling
- Prepared statements
- Transaction support
- Bulk insert operations
- Metrics and observability

[Unreleased]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v1.1.2...v1.2.0
[1.1.2]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v1.0.3...v1.1.0
[1.0.3]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.3.1...v1.0.0
[0.3.1]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.2.9...v0.3.0
[0.2.9]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.2.8...v0.2.9
[0.2.8]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.2.7...v0.2.8
[0.2.7]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.1.6...v0.2.0
[0.1.6]: https://github.com/cesar-carlos/dart_odbc_fast/releases/tag/v0.1.6
