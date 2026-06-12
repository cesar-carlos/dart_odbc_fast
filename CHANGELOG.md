# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [4.2.0] - 2026-06-12

### Added

- **`supports_native_bcp`** in `odbc_get_driver_capabilities` / `DbmsInfo.capabilities`
  JSON — reports compile-time + platform eligibility for SQL Server native BCP
  (`sqlserver-bcp` on Windows).
- **`DriverCapabilities.supportsNativeBcp`** and **`isNativeBcpAvailable`** —
  Dart mirrors for capability JSON plus the `ODBC_ENABLE_UNSTABLE_NATIVE_BCP`
  runtime guard.
- **Native BCP `Text` columns** — `sqlserver_bcp` binds `BulkColumnType::Text`
  via `SQLCHARACTER` (nullable via null bitmap).
- **`preferTransientFfiBufferForParams`** — sync parameterized query paths
  (`execQueryParams`, `execQueryMultiParams`, prepared `execute`) skip the
  scratch pool when param blobs are large so zero-copy results apply safely.
- **`odbc_stream_start_batched_options`** (native FFI) — batched cursor streaming
  with `ResultEncoding` wire layout (row-major, columnar v2, columnar compressed).
- **`streamQueryColumnarNative`** on `IOdbcRepository` extensions — explicit alias
  for columnar batched streaming.
- **`MULTI_STREAM_ITEM_TAG_RESULT_SET_BATCH` (tag `2`)** — continuation frames for
  per-cursor batched encoding in multi-result streaming.
- **`OdbcRepositoryState.defaultResultEncoding`** — `ServiceLocator` wires
  `recommendedResultEncoding` for `balancedServer` / `highThroughput`.
- **`CachedConnection::pool_session_reset`** and **`PooledConnectionWrapper::cached_mut`**
  — pooled FFI paths reuse prepared handles via `try_cached_legacy_params`.
- **`test/core/di/repository_profile_encoding_test.dart`** — profile default
  encoding contracts for `ServiceLocator` / `OdbcRepositoryImpl`.

### Changed

- **`zeroCopyResultThresholdBytes`** lowered from **64 KiB** to **32 KiB** when
  `odbc_release_buffer` resolves (ABI 1.1+).
- **`bulk_copy_from_memory`** — returns `UnsupportedFeature` with an explicit
  deferral message; use `bulk_copy_from_payload` (streaming BCP remains open
  work).
- **`streamQueryColumnar`** — requests columnar v2 on batched streaming FFI when
  available (`odbc_stream_start_batched_options`); falls back to row-major on
  older natives.
- **Multi-result streaming** — each ODBC result-set cursor is encoded in
  fetch-sized batches instead of full cursor materialisation.
- **`doc/PERFORMANCE.md`** — BCP capability JSON, Text column support,
  zero-copy threshold notes, columnar batched streaming semantics, automatic
  columnar defaults on server profiles, and pooled prepared-cache routing.
- **r2d2 pool connections** store `CachedConnection` so checkout retains the
  per-connection prepared-statement LRU.
- **`executeQueryParamValues` / `executeQueryParamBuffer`** — `resultEncoding`
  is optional; `null` applies the repository default (`columnar` on server
  presets via `ServiceLocator`).

## [4.1.1] - 2026-06-12

### Added

- **`test/infrastructure/native/bindings/ffi_exports_contract_test.dart`** —
  regression test that parses `odbc_exports.def` and verifies every `odbc_*`
  symbol has a Dart `lookup` (with documented exceptions for `otel_*` in
  `opentelemetry_ffi.dart` and `odbc_release_buffer` in `ffi_buffer_helper.dart`).
- **`isUnstableNativeBcpEnabled`** (`native_bcp_runtime.dart`) — Dart mirror of
  the native `ODBC_ENABLE_UNSTABLE_NATIVE_BCP` runtime guardrail.

### Changed

- **`doc/API_SURFACE.md`** — aligned with v4.1.0: ABI **1.1**, 96 exported
  symbols, `odbc_release_buffer`, batched streaming default, `streamQueryBuffer`,
  `recommendedResultEncoding`, and zero-copy threshold.
- **`streamQueryColumnar` dartdoc** on `IQueryService`, `IOdbcService`, and
  repository extensions — clarifies row-major `toTypedColumnar` conversion vs
  native columnar wire via `executeQueryColumnarParamValues`.
- **`doc/PERFORMANCE.md`** — `streamQueryColumnar` vs columnar wire paragraph;
  BCP runtime env documented with Dart helper reference.
- **`docs_contract_test.dart`** — stale-phrase guards and positive checks for
  `API_SURFACE.md` ABI 1.1 content.
- Stale ABI **1.0.0** example in `odbc_native.dart` updated to **1.1**.

## [4.1.0] - 2026-06-12

### Changed

- **CRUD bulk insert benchmark** — `test/performance/crud_latency_benchmark_test.dart`
  uses column-oriented `BulkInsertBuilder.addColumnInt32` / `addColumnText`
  instead of per-row `addRow`.
- **`bench_baselines/.gitignore`** — tracks `*.baseline.json` for regression
  compare while ignoring ephemeral `*.json` outputs.
- **Streaming C7 (batched default)** — `streamQuery` on `NativeOdbcConnection`,
  `AsyncNativeOdbcConnection`, and repository/service layers now routes through
  cursor-based batched streaming (`odbc_stream_start_batched`) instead of
  materialising the full result via `odbc_stream_start`. The `chunkSize`
  parameter is interpreted as `fetchSize` (rows per yielded chunk).
- **Repository streaming** — `streamNativeQueryWithFallback` no longer falls
  back to buffer-mode streaming; batched streaming is the only path.
- **Native multi-result streaming** — per-result-set encoding reuses
  `fetch_cursor_into_row_buffer` (block-cursor path when enabled).
- **Rust `execute_streaming`** — documented as legacy buffer-mode; shared
  `materialize_cursor_to_encoded` helper extracted. Prefer
  `execute_streaming_batched` / `start_batched_stream` for bounded memory.
- **FFI ABI version** bumped to **1.1** (additive: `odbc_release_buffer`).
- **`doc/PERFORMANCE.md`** — zero-copy FFI thresholds, async param transfer,
  and SQL Server `sqlserver-bcp` enablement notes.

### Added

- **`ResolvedOdbcUsageProfile.recommendedResultEncoding`** and
  **`ServiceLocator.recommendedResultEncoding`** — server presets
  (`balancedServer`, `highThroughput`) recommend `ResultEncoding.columnar` for
  analytics SELECT workloads; other presets keep row-major.
- **CRUD benchmark baseline export** — `test/performance/crud_latency_benchmark_test.dart`
  writes JSON when `BENCH_BASELINE_OUT` is set; reference baseline at
  `bench_baselines/crud-produto-5k.baseline.json`.
- **`scripts/run_dart_benchmarks.py --crud`** — runs the 5k columnar bulk CRUD
  lane and optional `--compare` against `crud-produto-5k.baseline.json`.
- **`streamQueryBuffer`** on sync and async native connections — explicit
  legacy buffer-mode streaming via `odbc_stream_start` for callers that need
  single-message accumulation or spill-to-disk semantics.
- **`odbc_release_buffer`** (native FFI, ABI 1.1) — releases buffers allocated
  with the host C `malloc` allocator.
- **Zero-copy FFI result subset** — `callWithBuffer` returns a
  `NativeFinalizer`-backed view for successful payloads ≥ 64 KiB when
  `odbc_release_buffer` resolves, avoiding the `Uint8List.fromList` copy on
  large query results.
- **`with_disconnect_cleanup`** (native) — centralises cross-map disconnect
  transitions ahead of further `GlobalState` lock sharding.
- **Transferable async param buffers** — `ExecuteQueryParamsRequest`,
  `ExecutePreparedRequest`, `ExecuteQueryMultiParamsRequest`, and
  `ExecuteAsyncStartParamsRequest` expose `withSerializedParams` factories that
  send large directed parameter blobs via `TransferableTypedData`.

### Breaking

- **Server usage profiles** — `OdbcUsageProfile.balancedServer` and
  `OdbcUsageProfile.highThroughput` now resolve
  `recommendedResultEncoding` to `ResultEncoding.columnar`. Per-query method
  defaults remain `ResultEncoding.rowMajor`; only callers that read
  `resolvedUsageProfile` / pass `recommendedResultEncoding` are affected. Opt
  back to row-major with `ResultEncoding.rowMajor` when benchmarking does not
  justify columnar for your driver.

## [4.0.1] - 2026-06-12

Patch confirming the 4.0 deprecation sweep is complete and removing the last
native `#[deprecated]` surfaces.

### Removed

- **`SecureBuffer::into_vec`** (native) — use `with_bytes` so sensitive bytes
  are zeroised on drop.
- **`COLUMNAR_DEFAULT_BATCH_SIZE`** (native) — unused re-export; use
  `block_fetch::configured_batch_size()` when batch sizing matters.

### Changed

- Example and doc comments updated to reference `executeQueryColumnarFromObjects`
  and `executeQueryParamValuesFromObjects` instead of removed 3.x APIs.
- `tool/generate_runners.py` no longer lists removed `getAsyncWorkerPoolStats`.

## [4.0.0] - 2026-06-12

Major breaking release completing the typed-parameter migration and removing
legacy Dart APIs deprecated since v3.9–v3.10. Native ABI, wire-format
(`MAGIC = 0x4F444243`, MULT v2), and exported Rust symbols are unchanged.

### Removed — breaking Dart API cleanup

- **Untyped `List<dynamic>` parameter surfaces** on `IQueryService`,
  `IOdbcService`, `IOdbcRepository`, telemetry decorators, and repository
  runners:
  - `executeQueryParams` → `executeQueryParamValues` or
    `executeQueryParamValuesFromObjects`
  - `executePrepared` → `executePreparedParamValues` or
    `executePreparedParamValuesFromObjects`
  - `executeQueryMultiParams` → `executeQueryMultiParamValues` or
    `executeQueryMultiParamValuesFromObjects`
  - `executeQueryColumnar` → `executeQueryColumnarParamValues` or
    `executeQueryColumnarFromObjects`
  - `executeQuery(sql, {params, connectionId})` no longer accepts `params`;
    use typed execute APIs or `executeQuery(sql, connectionId: id)` for
    parameterless convenience queries.
- **Deprecated connection overloads:** `executeQueryParamsFor`,
  `executeQueryColumnarFor`, and repository `executeQueryParamsFor`.
- **`QueryResultMulti.firstResultSet`** — use `firstResultSetOrNull` (distinguishes
  “no cursor” from “empty cursor”).
- **`MultiResultItem(...)` legacy factory** — use `MultiResultItemResultSet` /
  `MultiResultItemRowCount`.
- **`getAsyncWorkerPoolStats()`** — use `getWorkerPoolStats()` (`null` in sync
  mode).

### Added

- **`IQueryService` / `IOdbcService` typed bridges** in
  `i_query_service_extensions.dart`: `executeQueryParamValuesFromObjects`,
  `executePreparedParamValuesFromObjects`, `executeQueryMultiParamValuesFromObjects`,
  `executeQueryColumnarFromObjects` (exported from `package:odbc_fast/odbc_fast.dart`
  and re-exported via `ServiceLocator` for DI consumers).

### Migration guide (3.x → 4.0)

| 3.x (removed) | 4.0 replacement |
|---------------|-----------------|
| `executeQueryParams(id, sql, [1, 'a'])` | `executeQueryParamValuesFromObjects(id, sql, [1, 'a'])` or `executeQueryParamValues(id, sql, paramValuesFromObjects([...]))` |
| `executePrepared(id, stmt, [val], opts)` | `executePreparedParamValuesFromObjects(id, stmt, [val], opts)` |
| `executeQueryMultiParams(id, sql, params)` | `executeQueryMultiParamValuesFromObjects(...)` |
| `executeQuery(sql, params: [...], connectionId: id)` | `executeQueryParamValuesFromObjects(id, sql, [...])` |
| `result.firstResultSet` | `result.firstResultSetOrNull ?? QueryResult(...)` when a placeholder is required |
| `getAsyncWorkerPoolStats()` | `getWorkerPoolStats()` |

`QueryResult.rows` remains `List<List<dynamic>>`; use `QueryResultAccess` for
typed reads. Native low-level APIs (`NativeOdbcConnection.executeQueryParams`,
`executePrepared`) are unchanged.

### Changed — internal refactor (carried from 3.10.x prep, no ABI change)

Internal refactor and audit pass across the Rust native engine and Dart
layers. No public ABI, wire-format (`MAGIC = 0x4F444243`, MULT v2), or
exported-symbol changes. Behaviour is preserved; the work improves module
boundaries, test isolation, and maintainability.

### Changed — Dart clean architecture and service modularization

- **`OdbcService` split into capability delegates.** Query, pool, admin, and
  transaction orchestration move to `OdbcQueryService`, `OdbcPoolService`,
  `OdbcAdminService`, and `OdbcTransactionService`. `OdbcService` is now a
  thin façade that forwards each call; `IOdbcService` remains the aggregate
  contract for decorators and DI.
- **Domain types promoted out of infrastructure.** `ParamValue` (sealed),
  `DirectedParam`, `PoolOptions`, `DriverCapabilities`, `AsyncWorkerPoolStats`,
  `XaTransactionHandle`, and `SqlDataType` now live under `lib/domain/`.
  Infrastructure protocol modules delegate to or mirror these contracts at
  the FFI boundary.
- **`OdbcRepositoryImpl` decomposed into focused runners.** Connection,
  sync/prepared/multi query, stream, transaction, pool, admin, FFI dispatch,
  and result parsing each have a dedicated runner under
  `lib/infrastructure/repositories/runners/`, replacing a single monolithic
  implementation file.
- **`AsyncNativeOdbcConnection` split into `part` modules.** Worker lifecycle,
  channel dispatch, connection, pool, sync/async query, streaming, transactions,
  and stats are isolated in `async_*.dart` parts for easier navigation and
  review.
- **`NativeOdbcConnection` split into `part` modules.** Sync FFI connection,
  async/audit/metadata, transactions/XA, prepared/query/multi-result, catalog,
  pool/bulk, and streaming/dispose are isolated in `native_*.dart` parts;
  public API and behaviour unchanged.
- **`param_value.dart` split into `part` modules.** Wire encode/decode,
  typed conversion (`toParamValue`, `paramValuesFromObjects`), and literal
  validators are isolated in `param_value_wire.dart`,
  `param_value_conversion.dart`, and `param_value_validators.dart`; exports
  unchanged.
- **`odbc_native_query.dart` split into capability mixins.** Async execute,
  sync exec/multi + metrics/cache, catalog, prepare/execute, and bulk insert
  are isolated in `odbc_native_query_*.dart` parts; `OdbcNative` public API
  unchanged.
- **`bulk_insert_builder.dart` split into `part` modules.** Validation, public
  types, columnar storage, row API, and wire encoding are isolated in focused
  parts behind `_BulkInsertBuilderState`; builder behaviour unchanged.
- **`ParamValue` encoding (phases 2–3).** Domain sealed hierarchy with
  infrastructure two-pass wire encoding (pre-size, then single-buffer write).
  New typed entry points `executeQueryParamValues` /
  `executeQueryDirectedParams` route through the same FFI paths as the legacy
  APIs.
- **`QueryResultAccess` extension** on `QueryResult` adds low-risk typed
  row/column helpers (`columnIndex`, `cell`, `rowAsMap`, scalar getters)
  without changing underlying `List<dynamic>` storage.
- **`odbc_fast.dart` exports** extended for the new domain entities, helpers,
  and `SqlDataType`.
- **`TelemetryOdbcServiceDecorator` split into capability modules.**
  Query, pool, admin, and transaction instrumentation move to
  `TelemetryOdbcQueryDecorator`, `TelemetryOdbcPoolDecorator`,
  `TelemetryOdbcAdminDecorator`, and `TelemetryOdbcTransactionDecorator`
  with shared helpers in `telemetry_odbc_operations.dart`; the root decorator
  is a thin façade matching the `OdbcService` delegate layout.

### Changed — Rust native engine module splits

Monolithic engine and protocol files are split into cohesive submodules with
no intended behaviour change.

- **`ffi/`** — the ~10k-line `mod.rs` becomes a thin re-export root over
  `bulk`, `capabilities` (+ `helpers`), `catalog`, `connection`,
  `diagnostics`, `global`, `global_state`, `init`, `pool`, `query` (sync /
  async + `helpers`), `runnable`, `stream` (+ `helpers`), `statement`,
  `transaction`, and `xa`. Panic guards and `FfiError` codes (including
  `InternalLock` for poisoned runtime locks) stay ABI-stable.
- **`engine/core/execution/`** — replaces `execution_engine.rs` with
  `param_binding`, `result_encoding`, `multi_result_collect`, and focused
  unit tests.
- **`engine/streaming/`** — replaces `streaming.rs` with `chunk`, `columns`,
  `state`, `worker`, `multi_result`, and per-concern test modules.
- **`engine/transaction/`** — replaces `transaction.rs` with dialect SQL,
  savepoint handling, and isolation / access-mode / lock-timeout test suites.
- **`engine/xa/`** — replaces `xa_transaction.rs`; `xa_oci` wiring updated.
- **`protocol/bulk_insert/`** — replaces `bulk_insert.rs` with `common`,
  `legacy`, `v2`, and validation / round-trip test modules.
- **`protocol/param_value/`** — replaces `param_value.rs` with a `mod.rs` +
  `tests.rs` layout.
- **`plugins/detection.rs`** — driver / DBMS-name resolution extracted from
  `registry.rs`; registry focuses on registration and dispatch.
- **`plugins/oracle/`** — replaces monolithic `oracle.rs` with `catalog`,
  `type_catalog`, `session`, `bulk_loader`, `upsert`, `returning`, and
  focused unit tests.
- **`plugins/sqlserver/`** — replaces monolithic `sqlserver.rs` with `catalog`,
  `type_catalog`, `session`, `quoting`, `upsert`, `returning`, and tests.
- **`plugins/mysql/`** — replaces monolithic `mysql.rs` with `catalog`,
  `type_catalog`, `session`, `bulk_loader`, `upsert`, `returning`, and tests.
- **`engine/core/sqlserver_bcp/`** — replaces `sqlserver_bcp.rs` with
  `bound_column`, `execute`, `helpers`, `library`, `payload`, and tests.
- **`ffi/tests/query/`** — query FFI tests split into `async`, `prepare`,
  `sync`, `params`, and `timeout` modules under a thin `mod.rs` root.
- **`ffi/query/sync/`** — sync query FFI split into `exec`, `multi`, and
  `params` modules.

- **`plugins/postgres/`** — replaces monolithic `postgres.rs` with `catalog`,
  `type_catalog`, `session`, `bulk_loader`, `upsert`, `returning`, and tests.
- **`plugins/db2/`** — replaces monolithic `db2.rs` with `catalog`,
  `type_catalog`, `session`, `upsert`, `returning`, and tests.
- **`plugins/{snowflake,mariadb,sqlite,sybase}/`** — tier-2 dialect plugins
  split into `catalog`, `type_catalog`, `session`, `upsert`, `returning`, and
  focused unit tests; conflicting monolithic `*.rs` stubs removed in favour of
  directory modules (same hygiene as Oracle).
- **`lib/infrastructure/native/bindings/odbc_bindings.dart`** — FFI binding
  surface split into `part` modules (`connection`, `query`, `stream`,
  `transaction`, `xa`, `pool`, `types`); root library is a thin facade under
  50 lines.
- **`test/infrastructure/native/async_connection/`** — monolithic
  `async_native_odbc_connection_test.dart` decomposed into behaviour-focused
  suites with shared `fake_workers.dart`.
- **`engine/transaction/`** — transaction lifecycle extracted to `lifecycle.rs`;
  dialect-specific `BEGIN` / isolation / access-mode SQL moves to
  `dialect_sql.rs` apply helpers; savepoint hooks stay in `savepoint.rs`.
- **`lib/infrastructure/native/isolate/`** — `message_protocol` and
  `worker_isolate` split into query, stream, transaction, pool, and helper
  `part` modules; root libraries remain thin re-export facades.
- **`lib/infrastructure/native/protocol/param_value.dart`** — wire encoding,
  domain conversion, and validators split into `part` modules; root library
  stays under 150 lines.
- **`lib/infrastructure/native/protocol/bulk_insert_builder.dart`** —
  validation, columnar/row builders, and wire encode helpers split into
  `part` modules; root library stays under 150 lines.
- **`lib/infrastructure/native/bindings/odbc_native.dart`** — query FFI
  surface split from monolithic `odbc_native_query.dart` into `part` modules
  (`query_sync`, `query_async`, `query_prepare`, `query_catalog`,
  `query_bulk`); no ABI or behaviour change.

### Security — FFI `unsafe` audit (wave 4)

- **`// SAFETY:` coverage closed on remaining production sites.** OCI XA
  function-pointer fields (`engine/xa_oci.rs`), SQL Server BCP type aliases
  (`engine/core/sqlserver_bcp/library.rs`), `OwnedPreparedStatement` transmute
  alignment (`handles/owned_prepared.rs`), and inner helper blocks in
  `ffi/capabilities/helpers.rs` and `ffi/query/helpers.rs`. Wave 4 also
  documents `OutputAwareParams::bind_parameters_to`, `DtcXaBranch::Send`,
  connection/query sync SQL parsing, and XA recover buffer copies.
- **Criterion baselines (no local bench run required).** Synthetic micro-bench
  snapshots and refresh workflow live in
  `native/odbc_engine/benches/baselines/README.md`; the directory starts empty
  and the reference baselines are captured by the `native_bench_baseline.yml`
  workflow on the Linux runner — do not commit noisy per-developer snapshots.

### Added — performance regression harness (wave 4)

- **`test/performance/crud_latency_benchmark_test.dart`** — gated CRUD latency
  benchmark for async worker paths; complements native Criterion baselines.

### Performance — bulk encoding, native parse, and async bulk transport

- **Columnar typed `BulkInsertBuilder` APIs.** `addColumnInt32`,
  `addColumnInt64`, `addColumnText`, `addColumnDecimal`, `addColumnBinary`,
  and `addColumnTimestamp` accept typed column buffers (`Int32List`,
  `Int64List`, `List<String>`, `List<Uint8List>`, …) instead of per-row
  `List<dynamic>`. Fixed-width columns bulk-copy into the wire buffer; nullable
  columns use an optional parallel `isNull` mask. Row-oriented `addRow` remains
  supported and produces identical payloads.
- **`BulkInsertBuilder.build()` two-pass wire encoding.** Phase 1 pre-encodes
  text/decimal payloads and sizes the BLK2 buffer; phase 2 writes into a single
  pre-allocated `Uint8List` (no growing `BytesBuilder` / `List<int>` on the hot
  path). Documented in `README.md` and `doc/PERFORMANCE.md`.
- **Rust bulk payload parse zero-copy path.** `BulkCellBytes` shares one
  `Arc<[u8]>` backing buffer per parsed Text/Binary column; legacy and v2 parsers
  slice cells without per-cell `Vec` clones. `bulk_rows_from_vecs` keeps manual
  and test construction ergonomic.
- **Async bulk insert uses `TransferableTypedData`.** `bulkInsertArray` and
  `bulkInsertParallel` worker requests carry bulk payloads as transferable byte
  buffers across isolates (same pattern as query/stream fetch).
- **CRUD latency benchmark scenarios expanded.** Gated harness now reports bulk
  payload build time vs FFI insert time separately, plus pool-backed
  `bulkInsertParallel` (`RUN_PERF_TESTS=1`).
- **`param_value_conversion.dart`** — domain helper for typed parameter migration
  at repository boundaries (complements phase-3 `ParamValue` APIs).

### Fixed — runtime hardening (native)

- **Lock poison handling.** Central `LOCK_POISONED` diagnostic,
  `internal_lock_error()`, and `lock_mutex()` helper in `error/mod.rs`; FFI
  returns `FfiError::InternalLock` (-5). Tracing and telemetry paths log and
  recover from poisoned `RwLock` instead of silent loss; regression test
  `test_lock_poisoning_recovery` added.
- **`encode_multi` non-panicking contract.** `try_encode_multi` is the
  fallible encoder; `encode_multi` logs overflow and returns an empty buffer
  rather than panicking. `encode_row_count_only` and v1 helpers follow the
  same pattern.

### Fixed — module hygiene and test stability

- **Duplicate plugin modules.** Removed conflicting monolithic
  `plugins/{oracle,snowflake,mariadb,sqlite,sybase}.rs` files in favour of
  directory modules; registry wiring unchanged.
- **`binary_protocol_fuzz_test` timing.** Per-iteration 100 ms budget and
  30 s group timeout keep fuzz runs bounded in CI without false flakes from
  slow debug builds.

### Tests — FFI, E2E isolation, and Dart contract updates

- **E2E runner scripts.** `scripts/run_e2e_tests.ps1` and
  `scripts/run_e2e_tests.sh` load repo-root `.env`, map `RUN_SKIPPED_TESTS`
  to `ENABLE_SLOW_E2E_TESTS`, and run all 25 `e2e_*` integration suites
  (382 tests) with `--test-threads=1` and `--include-ignored`; `-Quick` /
  `--quick` skips slow stress paths.
- **FFI unit tests split** into `ffi/tests/{bulk,catalog,connection,diagnostics,errors,init,pool,query,stream,transaction,xa}` with shared `support.rs`; the `query` tree further splits into
  `async`, `prepare`, `sync`, `params`, and `timeout`. Maintenance scripts
  under `native/odbc_engine/scripts/` assist future splits.
- **E2E table isolation.** `unique_e2e_table(prefix)` generates
  pid + nanosecond + monotonic-counter names validated as SQL identifiers;
  `sql_drop_table_if_exists` is dialect-aware (SQL Server, Oracle, default
  `DROP TABLE IF EXISTS`). Bulk, benchmark, and FFI-regression E2E suites
  migrated off hard-coded table names to avoid parallel-run collisions.
- **ABI regression** — `abi_test.rs` pins `FfiError` layout, documented
  negative codes, `ParamDirection` `repr(u8)`, and MULT header constants.
- **Dart tests** — `mock_odbc_repository`, `i_query_service_extension_test`,
  `odbc_service_run_in_xa_transaction_test`, and `query_result_test` updated
  for typed-parameter APIs and `QueryResultAccess`.

## [3.10.1] - 2026-05-27 — Patch: CI repair, coverage expansion, docs alignment

PATCH bump per `doc/version/VERSIONING_STRATEGY.md`: no public Dart API
changes, no native ABI / wire format / exported symbol changes. Scope is
limited to CI hygiene, expanded unit coverage on previously
integration-only paths, README/example alignment with the 3.10 surface,
and a Dependabot bump for a release workflow action. The single touch
inside `lib/` (`OdbcAuditLogger.forTesting(...)`) is purely additive and
annotated `@visibleForTesting` — the default constructor and runtime
behaviour are unchanged.

### Fixed (CI — `loom` job and misplaced Dart steps)

- **Loom job now actually runs.** The loom models lived under
  `native/odbc_engine/tests/loom_state_test.rs` and were compiled
  through the `odbc_engine` crate, which pulls in `tokio`. `tokio` is
  not loom-compatible — its `AtomicWaker` exports are gated behind
  `#[cfg(not(loom))]` while `task::local` uses them unconditionally
  (tokio-rs/tokio#2510). Building with `RUSTFLAGS="--cfg loom"`
  therefore broke compilation with `error[E0432]: unresolved import
  crate::sync::AtomicWaker` before any model could run. Moved the
  models to a dedicated `native/loom_models/` workspace member whose
  only runtime dep is `loom`, and switched the CI `loom` job to
  `cargo test -p loom_models --release`. All three models now pass
  locally in ~42 s and the CI job is no longer permanently red.
  Removed the now-unused `loom = "0.7"` from
  `odbc_engine`'s `[dev-dependencies]`.
- **Dart unit / docs / example / perf steps were running under the
  loom job.** Because the `loom` job is `continue-on-error: true`, a
  real Dart test failure inside that job would be silently swallowed.
  Moved the entire Dart pipeline (`dart pub get`, `dart analyze`, FFI
  export check, unit-only test suite, docs and opt-in example smoke
  tests, protocol perf guard, slow-test budget) back to the `test`
  job where it enforces against PRs as intended. The loom job is now
  scoped to a single `cargo test -p loom_models --release` step.

### Tests (native — Rust unit coverage across plugins and observability)

Adds dedicated unit tests for the dialect plugins, observability
helpers, and the encoder result wrappers — all pure-logic paths that
previously relied on integration / e2e tests.

- `plugins/{mysql,postgres,sqlserver,snowflake,db2,oracle,mariadb,registry}`:
  `TypeCatalog::map_type_extended` branches, `CatalogProvider` SQL
  builders, `SessionInitializer` escapes, `Upsertable` / `Returnable`
  error variants, `Default` impl pin, and registry dispatch coverage for
  `upsert` / `returning` / `session_init` across every supported engine.
- `observability/tracing`: `SpanGuard` explicit-finish vs drop,
  `span_id` + metadata propagation, `active_span_count` assertions for
  the leak guard.
- `observability/logging`: `sanitize_sql_for_log` scientific notation
  (`e+10` / `e-3`) branch and `ENV_LOG_RAW_SQL=1` passthrough with env
  restoration so the suite stays hermetic.
- `engine/environment` and `protocol/encoder`: result wrapper edge
  cases and limit propagation paths previously exercised only by
  higher-level flows.

### Tests (Dart — public API surface, fakes, and extension overloads)

Adds focused Dart unit tests for the public API surface that previously
needed integration / e2e runs, plus a tiny additive testability hook on
`OdbcAuditLogger`.

- `lib/infrastructure/native/audit/odbc_audit_logger.dart` gains a
  `@visibleForTesting OdbcAuditLogger.forTesting({...})` constructor
  mirroring the existing `AsyncOdbcAuditLogger.forTesting` shape. The
  primary `OdbcAuditLogger(OdbcNative)` constructor stays the public
  default; only the field types changed (raw delegates instead of
  capturing `_native`), so the public API and behaviour are unchanged.
- `test/helpers/fake_async_native_for_errors.dart` grows extra
  delegates (`closeStatement`, etc.) so the audit logger fakes cover
  error paths previously exercised only end-to-end.
- New unit tests:
  `test/application/services/i_query_service_extension_test.dart`,
  `test/application/services/i_transaction_service_extension_test.dart`,
  `test/application/services/odbc_service_passthrough_test.dart`,
  `test/domain/entities/column_metadata_test.dart`,
  `test/domain/entities/dart_side_metrics_test.dart`,
  `test/domain/entities/odbc_event_test.dart` (expanded),
  `test/domain/entities/query_result_multi_test.dart` (expanded),
  `test/domain/entities/typed_columnar_result_test.dart`,
  `test/domain/services/simple_telemetry_service_test.dart`
  (expanded),
  `test/infrastructure/native/audit/odbc_audit_logger_test.dart`
  (expanded), and
  `test/infrastructure/native/protocol/multi_result_parser_legacy_test.dart`.

### Documentation

- Removed redundant `doc/PERFORMANCE_v2.md` redirect stub; `doc/PERFORMANCE.md`
  remains the single performance and benchmark guide.
- Removed redundant `doc/API_SURFACE_v2.md` redirect stub; `doc/API_SURFACE.md`
  remains the single FFI / Rust / Dart API reference.
- Removed redundant `doc/TEST_COVERAGE_v2.md` redirect stub; `doc/TESTING.md`
  remains the single test policy, CI scope, and coverage guide.
- README aligned with the 3.10 public API surface: Features section
  gained 6 bullets covering the four `IOdbcService` sub-interfaces, the
  event bus + sealed `OdbcEvent` hierarchy, `TypedColumnarResult`,
  `runInTransaction<T>` / `runInXaTransaction<T>`, opt-in `LazyString` +
  `SqlPointerCache` perf helpers, and X/Open XA / 2PC support. Streaming
  and multi-result bullets now mention `streamQueryNamed`,
  `streamQueryMulti`, and `executeQueryMultiParams`.
- README "API coverage" section: explicit cross-link to the four
  sub-interfaces (`IQueryService`, `ITransactionService`,
  `IPoolService`, `IAdminService`) plus a note about the
  `…For(Connection conn, …)` extensions; added ~13 previously omitted
  methods (`executeQueryDirectedParams`, `executeQueryColumnar`,
  `streamQueryColumnar`, `streamQueryMulti`, `streamQueryNamed`,
  `runInTransaction<T>`, `runInXaTransaction<T>`, `xaStart` /
  `xaRecover` / `xaResumePrepared`, `getWorkerPoolStats()`,
  `getConnectionDbmsInfo`, `setLogLevel`, `clearAllStatements`, and the
  `events` broadcast stream).
- README examples block: now lists all 36 `example/*.dart` files;
  previously 11 were only mentioned inline.
- Added `example/event_bus_demo.dart` showing `IAdminService.events`
  consumption against the sealed `OdbcEvent` hierarchy.
- Example audit follow-up: `quick_start_balanced_demo` and
  `async_service_locator_demo` use `OdbcUsageProfile.balanced`; existing
  demos prefer `executeQueryParamValues` / column-oriented bulk helpers where
  practical. New examples: `typed_columnar_demo.dart` (now also demonstrates
  `streamQueryColumnar`), `query_result_access_demo.dart`,
  `param_value_migration_demo.dart` (DSN-free), and `bulk_insert_demo.dart`.
  `run_in_transaction_demo` documents `ODBC_TEST_DSN` consistently.

### CI

- Bumped `softprops/action-gh-release` from 1 to 3 in
  `.github/workflows/release.yml` (Dependabot PR #4). No behavioural
  change for consumers; release workflow now tracks the maintained
  major.

## [3.10.0] - 2026-05-27 — Roadmap v3.x (additive + deprecation gradual)

Bumped from `3.9.0` as MINOR per `doc/version/VERSIONING_STRATEGY.md`:
backward-compatible public API additions only (new `IQueryService` /
`ITransactionService` / `IPoolService` / `IAdminService` sub-interfaces,
`IAdminService.events` + `OdbcEvent` sealed hierarchy,
`executeQueryColumnar` / `streamQueryColumnar`, `TypedColumnarResult`,
`LazyString`, `QueryResult.columnsMetadata`, `ColumnMetadata`,
`DartSideMetrics`, `SqlPointerCache`, `ConnectionOptions.slowQueryThreshold`,
9 `For(Connection)` overloads, `BinaryProtocolParser.parse(lazyStrings:)`,
`IOdbcRepository.dispose()` no-op default). Single non-breaking deprecation:
`IOdbcRepository.getAsyncWorkerPoolStats()` recommends
`getWorkerPoolStats()`. Native engine wire format (`MAGIC = 0x4F444243`,
MULT envelope, OUT1/RC1 trailers) and exported ABI (`odbc_exports.def`,
cbindgen, Dart FFI bindings) are unchanged.

### Performance — Engine nativo, follow-ups dos 4 sprints (defaults flipados, perf micro-otimizações, hardening, native temporal, loom, Sprint 3 final)

Continuação direta do plano `engine_perf_3_sprints_84fce471.plan.md`,
agora seguindo o follow-up `engine_perf_follow-ups_b8f0b22a.plan.md`.
Oito PRs em quatro fases, ordenados do menor risco/menor escopo (quick
wins) ao maior (finalização do split do `GlobalState`).

#### PR1.1 — Flip dos defaults (`block-cursor-fetch` + `statement-handle-reuse` on by default)

Decidido após CI matrix verde nas 4 combinações de feature e suíte
completa passando consistentemente: ambas as features de perf agora
fazem parte do `default` do `Cargo.toml`. Quem precisa do
comportamento legado (caminho per-cell + sem reuso de prepared) pode
opt-out via:

```toml
odbc_engine = { version = "...", default-features = false, features = ["test-helpers", "observability"] }
```

O fallback automático do `block-cursor-fetch` para LOBs/MAX sem
largura advertised continua intacto — drivers com schemas exóticos
não sofrem regressão. O `statement-handle-reuse` continua com o
`OwnedPreparedStatement` RAII que confina o `mem::transmute` em um
único ponto de unsafe com drop-order garantido por declaração de
campo em `CachedConnection`.

#### PR1.2 — Perf micro-otimizações (`BlockCursor` batch via env var, plugin RwLock, catalog cache key)

- **`ODBC_FAST_BLOCK_FETCH_BATCH` env var** (`block_fetch::configured_batch_size`):
  permite tunar o `batch_size` do `BlockCursor` em runtime sem
  recompilar. Default permanece `DEFAULT_BATCH_SIZE = 256`; valores
  inválidos ou ausentes caem no default. Cache via `OnceLock` para
  não pagar `std::env::var` a cada query.
- **Plugin lookup sem `Mutex`**: `ExecutionEngine::active_plugin`
  migrou de `Arc<Mutex<Option<Arc<dyn DriverPlugin>>>>` para
  `Arc<RwLock<...>>`. Reads por query (`current_plugin()`,
  `is_oracle_plugin_active()`) viram lock-free na ausência de
  escrita; writes (`set_connection_string`) continuam serializados
  mas são infrequentes.
- **`build_catalog_cache_key` sem alocação extra**: substitui
  `conn_id.to_string()` + `String::push_str` por um único
  `write!(&mut key, "{}:{}", conn_id, table)` com `String::with_capacity`
  reservada para o pior caso (10 dígitos + ':' + nome da tabela).
  Reduz de 2 para 1 alloc por catalog lookup.

#### PR1.3 — Safety hygiene (tripwire `mem::transmute`, log poison, init `ASYNC_REQUESTS`)

- **Tripwire `size_of` em `OwnedPreparedStatement`**: novo unit test
  `from_borrowed_transmute_size_invariant_holds` que valida que
  `Prepared<StatementImpl<'static>>` e `OwnedPreparedStatement` têm
  o mesmo tamanho. Se uma versão futura de `odbc-api` adicionar um
  campo lifetime-dependent ao `Prepared`, o teste falha — orientando
  o bug a quem deve corrigir antes de virar UB no cache.
- **Log explícito em poison de `RwLock`**: `connection_errors_read`
  e `_write` agora casam `PoisonError` e logam via `log::error!`
  antes de retornar `None`. Diagnostic loss silencioso vira observável.
- **Documentação + teste concorrente para init de `ASYNC_REQUESTS`**:
  doc-comment em `async_requests()` esclarece que `OnceLock::get_or_init`
  é thread-safe e o `Mutex` interno fica pronto imediatamente sem
  handshake separado. Novo test em `ffi/mod.rs::tests::async_requests_concurrent_init_is_lossless`
  exercita 16 threads × 32 inserts concorrentes via
  `lock_async_requests()` e valida que nenhum insert é perdido na
  race do primeiro acesso.

#### PR2.1 — Sprint 4.2: cache real na rota de params

`CachedConnection` ganhou `execute_query_with_params(sql, params)`
que mirror o `execute_query_no_params` mas re-binda parâmetros a cada
execute. O `OwnedPreparedStatement` é reusado por SQL key — re-bind
por execução é o padrão ODBC normal. `execute_stmt_with_params`
substitui o `param_values_to_input_params` + `stmt.execute` inline
para evitar duplicação.

Wire-up no FFI via novo helper `try_cached_legacy_params`:

- Quando o param buffer é uma legacy `ParamValue` list sem NULLs
  (plano `PreparedStandard`), roteia para o cache.
- Para DRT1 (`OUT`/`INOUT`), listas com NULL (plano `PreparedNullAware`
  que precisa de `parameter_descriptions`), ou erro de parse: cai no
  dispatcher original (`execute_query_with_param_buffer`).
- Pooled connections não têm cache hoje e continuam usando a rota
  original (documentado como follow-up).

`prepared_cache_bench` ganha o grupo `parameterized_hit_path` com
duas variantes (`cache_hit_rebind_only` vs `prepare_every_call`)
para medir o delta sintético.

#### PR2.2 — Tipos nativos em `block_fetch` para temporal (Date, Time, Timestamp)

`OdbcType::Date`/`Time`/`Timestamp` saem do caminho `WText` (UTF-16
→ UTF-8) e passam por `BufferDesc::Date`/`Time`/`Timestamp` nativos
do `odbc-api`. Os 3 novos formatadores em `block_fetch.rs`
(`format_date_into`, `format_time_into`, `format_timestamp_into`)
produzem ISO 8601 com:

- `Date`: `YYYY-MM-DD` (10 bytes)
- `Time`: `HH:MM:SS` (8 bytes, segundo-precisão)
- `Timestamp`: `YYYY-MM-DD HH:MM:SS.ffffff` (26 bytes, microsegundo-precisão)

A escolha de 6 dígitos para a fração de `Timestamp` cobre PostgreSQL,
MySQL, MariaDB, Snowflake e Oracle. SQL Server expõe 100-ns (7 dígitos)
no caminho WCHAR; o 7º dígito é dropped pelo formatador. Datetimes
truncados desta forma continuam parseáveis pelos decoders Dart
existentes (que toleram precisão variável).

Wire format **não muda** — continua text bytes. Apenas eliminamos a
passagem driver-WCHAR → `wide_buf` → UTF-16 → UTF-8 para esses 3
tipos. Ganho proporcional ao número de colunas temporais no result
set (caso comum em data warehouses).

`cell_reader_bench` ganha grupos `encode_date_only` e
`encode_timestamp_only`.

#### PR3.1 — Hygiene (baselines Criterion, CI cron, docs nativas)

- **`benches/baselines/README.md`**: documento o workflow de captura
  de baselines via `cargo bench -- --save-baseline default`. Diretório
  começa intencionalmente sem snapshots porque capturar em hardware
  heterogêneo geraria baselines ruidosos — a captura inicial é
  produzida pelo cron job do PR3.1 C10 no runner Linux de referência.
- **`.github/workflows/native_bench_baseline.yml`** (cron semanal +
  trigger manual via `workflow_dispatch`): roda os 4 benches sintéticos
  em `ubuntu-latest` e publica o HTML do Criterion como artefato com
  retenção de 30 dias. Sem gating — somente relatório.
- **`ARCHITECTURE.md`**: tabela de módulos atualizada com
  `engine::core::block_fetch`, `engine::core::columnar_fetch`,
  `engine::fetch`, `ffi::state`, `handles::owned_prepared`. Três
  diagramas mermaid novos: fetch paths (legacy vs block vs columnar),
  FFI state sharding (locks por categoria + lock ordering), prepared
  statement reuse (cache → owned wrapper → driver). Seção
  "Conventions" atualizada com a regra de defaults flipados e a
  política de poison logging.

#### PR3.2 — Loom tests opcionais (`tests/loom_state_test.rs`)

`loom = "0.7"` adicionado como dev-dependency e novo
`tests/loom_state_test.rs` com 3 modelos formais:

1. `errors_writer_reader_interleaving_never_loses_writes`: writer
   insere uma entrada enquanto reader em paralelo observa — loom
   explora todas as interleavings e confirma que o estado final
   sempre contém o valor escrito.
2. `outer_then_errors_does_not_deadlock_against_errors_only`: thread
   A adquire na ordem canônica (`outer → errors`), thread B só
   `errors`. Confirma ausência de ciclo.
3. `arc_metrics_singleton_is_observed_by_every_thread`: duas threads
   leem o mesmo `Arc<T>` lock-free — sanity-check de visibilidade.

O arquivo é gated por `#![cfg(loom)]` então em builds normais é uma
integração-test vazia. Para rodar: `RUSTFLAGS="--cfg loom" cargo test
--test loom_state_test --release --features ...`. Novo job CI
`loom` rodando esse comando em `ubuntu-latest` com
`continue-on-error: true` (non-blocking, timeout 30 min).

#### PR4.1 — Sprint 3 finalização (legacy global error em `RwLock` dedicado)

`state.last_error` e `state.last_structured_error` saem da
`GlobalState` e viram um `RwLock<LegacyGlobalError>` dedicado em
`ffi::state`. Reads do legacy error (caminho comum: polling Dart-side
depois de uma chamada FFI falhada) não precisam mais do outer mutex
da `GlobalState`. Os helpers existentes (`set_connection_error`,
`set_connection_structured_error`, `get_connection_error`,
`get_connection_structured_error`, `set_error`, `get_error`)
mantêm a mesma assinatura mas internalizam o split — `_state`
unused é deixado para preservar o shape dos call sites enquanto
nesse ciclo.

Novos helpers públicos em `state`:

- `legacy_global_error_read()` / `_write()`
- `set_legacy_global_error(msg)`
- `set_legacy_global_structured_error(err)`
- `legacy_global_error_message()`
- `legacy_global_structured_error()`

`tests/state_locking_order_test.rs` ganha 3 testes novos
(`legacy_error_message_round_trip`,
`legacy_structured_error_overwrites_plain_message`,
`legacy_error_message_defaults_to_no_error_string`) que pinam o
contrato do split.

Os 4 maps restantes (`connections`, `pools`, `transactions`,
`streams`, mais `xa_*`/`statements`) continuam dentro da
`GlobalState` porque requerem transições atômicas cross-categoria
(disconnect remove conexão + cancela transactions/streams; commit
de XA limpa branches em múltiplos maps). Mover esses corretamente
exige um helper `with_disconnect_cleanup`-style que adquire locks
na ordem canônica documentada — escopo grande o suficiente para
merecer seu próprio plano. O `GlobalState` agora carrega apenas o
estado que ainda precisa dessa atomicidade cross-categoria.

### Performance — Engine nativo, plano de 4 sprints (BlockCursor, columnar direto, FFI sharding, prepared cache real)

Entrega completa do plano de execução
`engine_perf_3_sprints_84fce471.plan.md`. Cinco fases (1 baseline +
4 entregas) com PRs independentes, feature flags onde apropriado
para coexistência com o caminho legado, e benches Criterion
sintéticos como linha-base reprodutível sem depender de DSN ODBC
real. ABI exportada (símbolos em `odbc_exports.def`, cbindgen,
bindings Dart) e wire format (`MAGIC = 0x4F444243`, MULT envelope,
OUT1/RC1 trailers) **não mudam** — quem usa o engine via FFI não
precisa fazer nada.

**Sprint 0 — Baseline e safety net.**

- 4 micro-benches Criterion sintéticos (`cell_reader_bench`,
  `encoder_bench`, `ffi_contention_bench`, `prepared_cache_bench`)
  em `native/odbc_engine/benches/`. Cada um isola uma fase e mede
  delta antes/depois sem precisar de DSN ativo. Registrados no
  `[[bench]]` block do `Cargo.toml`.
- `encoder_bench` ganha shapes 1k/10k/100k × 1/10/50 colunas com
  mistura row-major/colunar e o grupo
  `direct_columnar_vs_via_row_major` que comprova o ganho do
  Sprint 2 head-to-head.

**Sprint 1 — `BlockCursor` row-major (feature `block-cursor-fetch`).**

- Novo feature `block-cursor-fetch` (default OFF). Quando ligado,
  o fetch passa por `engine/core/block_fetch.rs::fetch_rows_into`
  que binda um `odbc_api::buffers::ColumnarAnyBuffer` no cursor e
  consome o result set em batches de 256 linhas via
  `BlockCursor::fetch_with_truncation_check(true)`. Reduz chamadas
  `SQLFetch` + `SQLGetData` de O(rows × cols) para
  O(rows / batch_size), com ganho esperado de 2–10x em SELECTs
  grandes especialmente sobre rede.
- Fallback automático para o caminho legado quando alguma coluna
  não tem largura advertised (LOB, MAX) ou exigiria buffer inline
  acima de 256 KiB por célula. A decisão é tomada **antes** do bind,
  pelo helper `plan_buffer_descs`, então não há recuperação no meio
  do fetch.
- Novo módulo `engine/fetch.rs` com dispatcher único
  `fetch_cursor_into_row_buffer` que centraliza o cfg-gate entre
  legacy `cursor.next_row()` e block-cursor. 6 dos 8 call sites
  originais (em `execution_engine.rs`, `streaming.rs`,
  `cached_connection.rs`) agora chamam o dispatcher; os 2 restantes
  (`encode_cursor`/`encode_cursor_v1` na rota multi-result) ficam
  no per-cell porque emprestam o cursor por `&mut C` —
  `BlockCursor::bind_buffer` exigiria propriedade.
- Matriz CI: jobs novos em `.github/workflows/ci.yml` rodam
  `cargo build` + `cargo test` com `--features block-cursor-fetch`
  e com `--features statement-handle-reuse` separadamente para
  bloquear regressões em ambos os perfis.

**Sprint 2 — Caminho colunar direto do cursor (mesma feature flag).**

- Novo `engine/core/columnar_fetch.rs::fetch_columnar_into`
  popula `ColumnData::{Integer, BigInt, Varchar, Binary}` direto
  dos views do `ColumnarAnyBuffer` (`AnySlice::as_nullable_slice`,
  `as_w_text_view`, `as_bin_view`), **sem** materializar o
  `RowBuffer` row-major intermediário. Elimina o
  `.clone()` por célula que o `row_buffer_to_columnar` antigo
  pagava em colunas Binary/Varchar (~50% menos RAM no path
  colunar).
- `encode_optional_cursor` em `execution_engine.rs` ganha
  branch condicional: quando `use_columnar` está ligado, o
  feature está on, e a query **não** é FOR JSON, vai pelo
  caminho direto; senão cai no Sprint 1 (row-major +
  `encode_query_result_payload`).
- `row_buffer_to_columnar` marcado como deprecated no doc-comment
  (ainda usado por `encode_for_bulk` e pela rota legacy/quando o
  feature está off).
- Regressão `tests/block_fetch_parity_test.rs` valida byte-a-byte
  que `ColumnarEncoder::encode(direct_v2)` produz exatamente os
  mesmos bytes que `ColumnarEncoder::encode(row_buffer_to_columnar(rb))`
  em fixtures sintéticos com inteiros, varchar com nulls/unicode,
  binary e mistura.

**Sprint 3 — Decomposição conservadora do `Mutex<GlobalState>`.**

- Novo módulo `native/odbc_engine/src/ffi/state/` com a estrutura
  sharded por categoria. Lock ordering canônica documentada no
  header do módulo: `GLOBAL_STATE → ASYNC_REQUESTS →
  connection_errors`.
- Imutáveis hoisteados para `OnceLock<Arc<_>>` (zero lock):
  - `state::ffi_metrics() -> Arc<Metrics>`
  - `state::ffi_audit_logger() -> Arc<AuditLogger>`
- Per-connection error map em `RwLock<HashMap<u32, ConnectionError>>`
  dedicado (escritores não bloqueiam outras categorias; leitores em
  paralelo via `RwLock::read`):
  - `state::set_connection_error`,
    `state::set_connection_structured_error`,
    `state::get_connection_error_message`,
    `state::get_connection_structured_error`,
    `state::clear_connection_error`.
- `AsyncRequestManager` em `Mutex<AsyncRequestManager>` próprio
  (em `ffi/mod.rs` por causa do acoplamento de tipos FFI). Polling
  de requests async não bloqueia mais a fila de queries síncronas.
- ~10 call sites em `ffi/mod.rs` migrados para os novos helpers:
  os 9 `Arc::clone(&state.metrics)` viram `state::ffi_metrics()`;
  todos os `state.audit_logger.X()` viram `state::ffi_audit_logger().X()`;
  os 7 acessos diretos a `state.connection_errors` viram os helpers
  do módulo; os 8 acessos a `state.async_requests` passam por
  `lock_async_requests()`.
- Funções `set_connection_error` / `set_connection_structured_error`
  preservaram a assinatura `(&mut state, ...)` para minimizar churn
  no chamador, mas internamente escrevem para o `RwLock` dedicado +
  o `state.last_error` legado.
- `tests/state_locking_order_test.rs` exercita as helpers sob
  carga concorrente (8 threads × 200 writes, leitores em paralelo)
  validando que não há deadlock e que escritas/leituras nunca
  corrompem o slot por conexão. Atestações estáticas adicionais
  garantem que `ffi_metrics`/`ffi_audit_logger` retornam o mesmo
  `Arc` (singleton estável).

**Sprint 4 — Prepared statement cache real
(feature `statement-handle-reuse`).**

- Novo `handles/owned_prepared.rs::OwnedPreparedStatement`
  encapsula o `mem::transmute` que alarga o lifetime do
  `Prepared<StatementImpl<'conn>>` para `'static`. O `unsafe`
  fica confinado em **uma única função** (`from_borrowed`) com
  contrato `# Safety` explícito; o acesso ao statement passa por
  `with_mut(F)` que reborrow-a sob o lifetime da closure, não
  vaza referência.
- `CachedConnection` declara `stmt_cache` **antes** de `conn` para
  que o drop glue execute `stmt_cache.drop()` primeiro,
  satisfazendo o invariante de drop-order que o
  `OwnedPreparedStatement::from_borrowed` exige. Documentado no
  header da struct para que reviewers futuros não reordenem.
- `PreparedStatementCache` em `engine/core/prepared_cache.rs`
  promovido de "bookkeeping LRU" a agregador de métricas
  cross-connection com novos métodos `record_hit()` e
  `record_prepare()`. A LRU de bookkeeping interna permanece como
  set autoritativo de SQLs tracked (para a FFI existente que
  inspeciona tamanho/eviction). O cache real de handles
  `Prepared` continua dentro de `CachedConnection` (per-conexão,
  via `OwnedPreparedStatement`).
- `tests/prepared_cache_invalidation_test.rs` cobre as novas
  invariantes: contadores `record_hit`/`record_prepare`
  independentes do `get_or_insert`; `record_execution` não afeta
  size/hits; snapshot `get_metrics` consistente com counters
  individuais; `clear` reseta a LRU mas preserva o histórico
  cumulativo de `cache_misses` e `total_executions`.

**Verificação local executada (Windows host):**

- `cargo fmt --check` — sem diffs.
- `cargo clippy --all-targets --all-features` — 0 warnings, 0 errors.
- `cargo test --all-targets --no-fail-fast` — todos passam (1542
  unit + integration).
- `cargo test --all-targets --features block-cursor-fetch --no-fail-fast`
  — todos passam.
- `cargo test --all-targets --features statement-handle-reuse --no-fail-fast`
  — todos passam.
- `cargo test --all-targets --all-features --no-fail-fast` — todos
  passam.
- `dart analyze` no workspace inteiro: `No issues found!`.

### Performance — Engine nativo (hot path SELECT, fetch e build)

Otimizações ortogonais aplicadas ao engine Rust após análise de
gargalos no caminho `fetch row → encode bytes → entregar ao Dart`.
Todas as mudanças preservam a ABI exportada (símbolos, layouts, wire
format) e o comportamento observável; quem usar o engine direto via
FFI não precisa mudar nada.

- **Leitura direta de inteiros (`CellReader`).** Colunas mapeadas
  como `OdbcType::Integer` e `OdbcType::BigInt` agora vão buscar o
  valor com `SQLGetData(SQL_C_SLONG)` / `SQL_C_SBIGINT` direto em um
  `Nullable<i32>` / `Nullable<i64>` na stack. O caminho anterior fazia
  `SQL_C_WCHAR` → `Vec<u16>` → `String::from_utf16_lossy` → `trim()`
  → `parse::<i32>()` → `Vec<u8>`, custando 5 alocações + duas
  transcodificações por célula numérica. Como `Integer` só recebe
  `SQL_INTEGER / SMALLINT / TINYINT / BIT` e `BigInt` só recebe
  `SQL_BIGINT`, a conversão lateral nunca era necessária. Drivers
  com tipagem dinâmica (ex.: SQLite com `INTEGER`-affinity) que
  ofereçam um valor não convertível para `i32` passam a falhar de
  forma explícita em vez de devolver bytes textuais sob um rótulo
  de coluna numérica (que já era inválido para o caminho colunar).
  Removidos os helpers `text_bytes_to_i32_le_bytes` /
  `text_bytes_to_i64_le_bytes` e seus testes; mantidos os testes
  de unicode e fallback de UTF-16 → UTF-8 para colunas textuais.
- **Reuso real do `binary_buf` em `CellReader::read_binary`.** A
  versão anterior fazia `mem::swap` + `Vec::with_capacity(out.capacity())`,
  realocando o buffer interno em **toda** célula binária. Agora o
  `binary_buf` mantém capacidade entre células e cada célula
  devolvida ao consumidor é uma cópia justa (`as_slice().to_vec()`)
  para não desperdiçar RAM em result sets longos. Resultado: 1
  alocação por célula em vez de 2, e capacidade amortizada na
  coluna inteira.
- **`QueryPlan` agora referencia o SQL em vez de cloná-lo.** O
  pipeline alocava `String::from(sql)` em `parse_sql` e nunca
  mutava a string. `QueryPlan<'a>` virou um wrapper de
  `&'a str` e os call sites internos (`execute_with_params*`,
  `execute_multi*`, `execute_direct_cached`, ...) chamam
  `validate_sql_not_empty(sql)` em vez de construir um plano
  descartado. Sem mudança de comportamento, uma alocação a menos
  por query.
- **Gate de logging por `log::log_enabled!` no `ExecutionEngine`.**
  Adicionado `StructuredLogger::is_enabled(Level)` e centralizado
  o setup do `SpanGuard` + `HashMap<span_id>` no helper
  `log_query_start`. A construção do span (que aloca
  `sql.to_string()` e toma o `Mutex<HashMap>` do `Tracer` duas
  vezes, uma no `start` outra no `Drop`) só acontece quando o
  logger está habilitado **e** o nível `Info` está ativo no `log`
  crate. Em produção com logging desligado, é zero overhead por
  query no caminho de tracing-bookkeeping.
- **Profile de release/bench mais agressivo (`native/Cargo.toml`).**
  - `lto = "thin"` → `lto = "fat"` (inlining cruzando `odbc-api`,
    `zstd`, `lz4`, nosso protocolo);
  - `codegen-units = 16` → `1` (mais oportunidade de inlining em
    troca de tempo de build);
  - `panic = "unwind"` explícito — `ffi/guard.rs` depende de
    `catch_unwind` para traduzir pânicos em códigos de erro
    estáveis no FFI; trocar para `abort` quebraria isso
    silenciosamente. O comentário no manifesto explica a decisão;
  - Novo `[profile.bench]` espelhando o release para que os
    números do Criterion reflitam o binário que efetivamente
    enviamos.
- **Código morto removido.** O módulo `protocol/arena.rs`
  (`Arena`, ~250 linhas + 17 testes) estava `pub use`'d no barrel
  do protocolo mas sem nenhum consumidor real (`SemanticSearch`
  + `grep` no workspace inteiro retornaram apenas os próprios
  testes do módulo). Removido junto com a referência no
  `tests/phase12_test.rs`.

Verificação local:

- `cargo check --all-targets`, `cargo clippy --all-targets`,
  `cargo fmt --check` e `cargo test --all-targets --no-fail-fast`
  passaram limpos na crate `odbc_engine` (1537 testes unitários +
  todas as suítes de integração).
- `dart analyze` no workspace: `No issues found!`.

Roadmap em 3 fases aplicado seguindo as regras do projeto. Todas as
mudanças são aditivas — nenhuma quebra de API pública. Suite Dart fica
em zero `dynamic` no `OdbcRepositoryImpl` e ganha mais de 30 novos
testes (1041 → 1100+ totais).

A Fase 4 do roadmap continua aditiva. Suite total: **1247 testes**
(1230 antes da Fase 4) + zero warnings em `dart analyze` para
`lib/`, `test/` e `example/`.

### Adicionado — Phase 4 (Runners, columnar surface, event bus, CI)

- **[PR1.1] `OdbcCatalogRunner`.** Novo
  `lib/infrastructure/repositories/runners/odbc_catalog_runner.dart`.
  Os 6 métodos `catalog*` (`catalogTables`, `catalogColumns`,
  `catalogTypeInfo`, `catalogPrimaryKeys`, `catalogForeignKeys`,
  `catalogIndexes`) foram migrados do `OdbcRepositoryImpl` para o
  runner via composição: o repositório mantém a API pública e
  delega. Runner é stateless (recebe `OdbcBackend`, lookups e
  helpers via construtor injection).
- **[PR1.2] `OdbcBulkRunner`.** Novo runner para `bulkInsert` e
  `bulkInsertParallel` (incluindo o caminho fallback single-conn
  quando `parallelism <= 1`). Mesma forma de composição do catalog
  runner.
- **[PR1.3] Mais 3 call sites migrados para `_runBoolFfi`.**
  `createSavepoint`, `rollbackToSavepoint` e `releaseSavepoint`
  agora usam o helper centralizado, fechando o agrupamento da
  família savepoint. `closeStatement`, `cancelStatement`,
  `poolReleaseConnection` e `poolClose` permanecem manuais por
  carregarem side-effects no caminho de sucesso (limpeza de maps);
  documentado como follow-up.
- **[PR1.4] Testes dos runners.** 17 novos testes
  (`test/infrastructure/repositories/runners/`) verificando
  validação de connection id, encaminhamento de argumentos,
  conversão de erro e o fallback do `bulkInsertParallel`.
- **[PR1] Resultado de tamanho.** `OdbcRepositoryImpl` saiu de 3517
  para ~3120 linhas (~11% menor) sem mudança de API pública.
- **[PR2.1] `executeQueryColumnar` + `streamQueryColumnar` no
  service-level.** Novo par de métodos em `IQueryService` que
  expõe `TypedColumnarResult` (column-major, com
  `Int32List`/`Int64List`/`Float64List` para colunas numéricas).
  Implementação em `OdbcService` aplica `toTypedColumnar()` ao
  resultado do repositório. Decorator de telemetria propaga.
- **[PR2.2] Flag `lazyStrings` opt-in no parser binário.**
  `BinaryProtocolParser.parse()` e `parseWithOutputs()` aceitam
  `lazyStrings: true`. Quando ativada, células de texto vêm como
  `LazyString` (decoding sob demanda); compatível com `==` contra
  `String` literais. Default permanece eager. A flag é
  thread-safe-equivalente em Dart (single isolate) e restaurada
  no `finally` para evitar leak entre chamadas.
- **[PR2.3] `QueryResult.columnsMetadata`.** Campo opcional
  aditivo em `QueryResult`. Populado pelo
  `_parseBufferToQueryResult` a partir de
  `ParsedRowBuffer.columns` (inclui `name` + tipo discriminador
  do protocolo). Legacy callers ficam com `null`.
- **[PR2.4] `IAdminService.getWorkerPoolStats()`.** Bridge
  infalível das estatísticas internas
  (`AsyncNativeOdbcConnection.getWorkerPoolStats()`) para o
  service-level. Retorna `null` em modo sync (sem worker pool) em
  vez de `Failure(UnsupportedFeatureError)`. Coexiste com o
  `IOdbcRepository.getAsyncWorkerPoolStats()` original (que
  permanece com `Failure` para callers existentes).
- **[PR2.5] Testes do PR2.** 11 novos testes:
  `executeQueryColumnar`/`streamQueryColumnar` em
  `odbc_service_orchestration_test.dart`, grupo `lazyStrings flag`
  em `binary_protocol_test.dart`, grupo `columnsMetadata` em
  `query_result_test.dart`, e `getWorkerPoolStats` no orchestration.
- **[PR3.1] Sealed `OdbcEvent`.** Novo
  `lib/domain/entities/odbc_event.dart` com 5 variantes:
  `ConnectionLost`, `WorkerRecovered`, `AutoReconnectAttempted`,
  `PoolResize`, `SlowQueryDetected`. Cada variante é `final class`
  com timestamp UTC + payload tipado. Re-exportado pelo barrel.
- **[PR3.2] Stream<OdbcEvent> events no IAdminService.**
  `OdbcRepositoryImpl` agora emite eventos em 4 pontos:
  `_withReconnect` emite `ConnectionLost` ao detectar drop;
  emite `AutoReconnectAttempted` a cada retry; o callback
  `_onUnderlyingWorkerRecovered` emite `WorkerRecovered`;
  `poolSetSize` emite `PoolResize` (capturando old/new size).
  `OdbcService` cria um `StreamController` broadcast que faz
  bridge do stream da repo, permitindo múltiplos consumers sem
  back-pressure. Método `closeEvents()` para shutdown explícito.
- **[PR3.3] 9 overloads `For` aceitando `Connection`.** Novas
  extensions `IQueryServiceConnectionOverloads` e
  `ITransactionServiceConnectionOverloads`. Métodos: `executeQueryFor`,
  `executeQueryParamsFor`, `executeQueryNamedFor`,
  `executeQueryColumnarFor`, `streamQueryFor`,
  `streamQueryNamedFor`, `streamQueryColumnarFor`,
  `beginTransactionFor`, `runInTransactionFor`. Removem o
  `conn.id` plumbing nos call sites; aditivos (não substituem).
- **[PR3.4] Migration demo.** Novo
  `example/sub_interfaces_migration_demo.dart` mostrando V1
  (depende de `IOdbcService`) versus V2 (depende só de
  `IQueryService`). Smoke test no `opt_in_examples_smoke_test.dart`
  garante que executa em modo describe-only.
- **[PR3.5] Testes do event bus.** 10 novos testes:
  `odbc_event_test.dart` (variantes + sealed exhaustiveness),
  `odbc_service_event_bus_test.dart` (broadcast, multi-listener,
  `closeEvents` cancela bridge, late subscriber).
- **[PR4.1] `.codecov.yml` + `fail_ci_if_error: true`.** Coverage
  threshold em 80% (project + patch) com 1% de drift band para
  PRs não-test. Workflow falha se o upload Codecov falhar (sem
  silent slips). Ignore patterns para `native/`, `example/`,
  `test/` e gerados.
- **[PR4.2] Bench baseline JSON em `sql_pointer_cache_bench_test`.**
  Quando `BENCH_BASELINE_OUT` é setada, o teste emite o arquivo
  no formato consumido por `tool/compare_benchmark_baseline.dart`
  com 2 cenários (`sql_cache.cached_acquire` e
  `sql_cache.baseline_alloc_free`). Opt-in: `dart test` casual
  não polui o working tree.
- **[PR4.3] `.github/dependabot.yml`.** Configuração weekly para
  3 ecosistemas: `pub` (raiz), `cargo` (`/native/odbc_engine`),
  `github-actions` (`/`). Limit de 5 PRs abertos por ecosistema,
  todos com label `dependencies` + label específica.
- **[PR4.4] `doc/ARCHITECTURE.md`.** Espelho Dart-side do
  `native/odbc_engine/ARCHITECTURE.md`. Cobre: layering com
  Mermaid, public API barrel, ServiceLocator (sync vs async
  stack), sealed `OdbcBackend`, sub-interfaces de `IOdbcService`,
  runners do repositório, event bus pipeline. Indexado a partir
  do `README.md` raiz.
- **[PR4.5] `docs_contract_test` reforçado.** Dois novos testes:
  `should_ship_dart_layer_architecture_doc` (verifica seções e
  link do README) e
  `should_ship_codecov_threshold_and_dependabot_configs` (verifica
  threshold 80% e os 3 ecosistemas dependabot).

### Mudou — Phase 4

- `IOdbcRepository` ganhou método `getWorkerPoolStats()` infalível
  (Future<AsyncWorkerPoolStats?>); coexiste com o
  `getAsyncWorkerPoolStats()` original.
- `IOdbcRepository` ganhou `Stream<OdbcEvent> get events`. O mock
  `MockOdbcRepository` retorna `Stream<OdbcEvent>.empty()` por padrão.
- `BinaryProtocolParser._decodeText` mudou retorno interno de
  `String` para `dynamic` (retorna `LazyString` quando
  `lazyStrings:true`). Comportamento default preservado.
- `QueryResult` ganhou campo opcional `columnsMetadata`. Construtor
  é aditivo (parâmetro opcional named).

### Future work — Phase 4 (não entregue por escopo)

- **D1 — Statement cancellation end-to-end.** Requer mudanças no
  Rust + ABI bump; planejado em PR dedicado.
- **A3 — Steps 4-9 do split do repositório.** Runners adicionais
  (Query, Transaction, Pool) seguirão o mesmo padrão de
  `OdbcCatalogRunner` quando features novas naturalmente caírem em
  cada categoria.
- **G2 — Hooks per-connection.** Pode ser construído em cima do
  event bus (filtro por `connectionId`); deferido até haver demanda
  concreta.

### Adicionado — Phase 4.1 (Improvements pass)

Hardening adicional sobre a Fase 4. Suite mantém 1247 testes verdes,
zero warnings em `dart analyze`. Novamente 100% aditivo / preservando
compat.

- **[Imp.1] `_runBoolFfiWithCleanup` helper.** Variante do
  `_runBoolFfi` que recebe um callback `onSuccess()` invocado
  no caminho de sucesso antes do `Success(unit)`. Migrados:
  `closeStatement` (limpa metadata maps), `poolReleaseConnection`
  (limpa connection ids + pool checkout), `poolClose` (limpa
  todos os checkouts do pool). `cancelStatement` permanece manual
  por carregar lógica de detecção de "unsupported feature".
- **[Imp.2] `_runIntFfi` helper.** Para FFI calls que retornam
  `int` com predicado de sucesso configurável. Migrados:
  `poolCreate` (`id != 0`), `clearAllStatements` (`code == 0`,
  combinado com `fold` para `Result<Unit>`).
- **[Imp.3] `ColumnMetadata` movido para `lib/domain/entities/`.**
  Era `dynamic` em `QueryResult.columnsMetadata` (anti-pattern por
  acoplamento ao infrastructure). Agora é
  `List<ColumnMetadata>?` fortemente tipado. O `OdbcType`
  permanece em infrastructure como extension `ColumnMetadataTypedView`
  (`col.type` ainda funciona). Re-exportado pelo barrel.
- **[Imp.4] `_decodeText` retorna `Object` ao invés de `dynamic`.**
  Trade-off conservador: o sealed `TextCell` completo seria
  melhor mas exigiria mudar o contrato externo `List<List<dynamic>>`
  das rows. `Object` já força não-null e o analyzer ainda checa
  contra retornos acidentais.
- **[Imp.5] `SlowQueryDetected` emission point implementado.** Novo
  campo `ConnectionOptions.slowQueryThreshold` (com
  `effectiveSlowQueryThreshold` defaulting a `queryTimeout * 0.8`).
  `_withReconnect` aceita `sqlForSlowQueryDetection` opcional que,
  quando combinado com threshold configurado, emite o evento via
  helper `_maybeEmitSlowQuery`. Aplicado nos 5 call sites de
  `_withReconnect` em `executeQuery*`. Best effort, nunca bloqueia.
- **[Imp.6] `MockOdbcRepository.emitEvent()` helper.** Mocks de
  testes podem agora driver o event bus syncronamente sem precisar
  estender o mock. `closeEvents()` para shutdown explícito.
- **[Imp.7] `OdbcEvent.toString()` em cada variante.** Cada um
  dos 5 eventos (`ConnectionLost`, `WorkerRecovered`,
  `AutoReconnectAttempted`, `PoolResize`, `SlowQueryDetected`)
  ganhou implementação custom de `toString()` para debugging em
  logs. `SlowQueryDetected` trunca SQL em 80 chars com elipse.
- **[Imp.12] Workflow GitHub Actions
  `.github/workflows/dart_bench_baseline.yml`.** Nova lane que
  roda em PRs tocando `lib/infrastructure/native/`,
  `test/performance/sql_pointer_cache_bench_test.dart` ou o
  comparator. Usa `BENCH_BASELINE_OUT` (introduzido na Fase 4
  PR4.2) para emitir JSON, compara contra
  `bench_baselines/sql_cache.json` (quando presente) via
  `tool/compare_benchmark_baseline.dart` e comenta no PR com a
  tabela de resultados. Informacional na ausência de baseline.
- **[Imp.13] Dartdoc snippets executáveis em APIs novas.**
  `IQueryService.executeQueryColumnar`,
  `IQueryServiceConnectionOverloads` (overloads `For`) e
  `IAdminService.events` ganharam exemplos completos no
  docstring (consumível por `dart doc` e renderizado no
  pub.dev).

### Mudou — Phase 4.1

- `IOdbcRepository.getAsyncWorkerPoolStats()` marcado com
  `@Deprecated`, recomendando `getWorkerPoolStats()` (que retorna
  `null` em sync mode em vez de `Failure`). A janela de
  deprecação se estende até a próxima major release. Mesma anotação
  em `IOdbcService` e `TelemetryOdbcServiceDecorator`.
- `BinaryProtocolParser._decodeText` retorna `Object` em vez de
  `dynamic`. Não muda comportamento — só o tipo no source.
- `QueryResult.columnsMetadata` é `List<ColumnMetadata>?` (era
  `List<dynamic>?`). Mudança aditiva — o constructor já aceitava
  qualquer lista; agora rejeita lista de tipo errado em
  compile-time.
- `ConnectionOptions` ganhou parâmetro nomeado opcional
  `slowQueryThreshold`. Default permanece `null`; sem mudança de
  comportamento para callers existentes.

### Future work — Phase 4.1

- **Split runners adicionais (Query, Transaction, Pool).**
  Cancelados deste pass — requerem mover ou expor 8+ helpers
  privados (`_streamNativeQueryWithFallback`, `_toQueryResult`,
  `_optionsFor`, `_withReconnect`, `_parseBufferToQueryResult`,
  `_streamingFailureFromException`,
  `_convertNativeErrorToFailure`, etc.). Merecem plano dedicado
  com design cuidadoso das fronteiras antes de mover código.
- **`TextCell` sealed completo.** Versão minimal (`Object`)
  entregue. Sealed completo exigiria mudar o contrato externo
  `List<List<dynamic>>` para `List<List<Object>>` ou similar —
  mudança quebrante.



### Adicionado — Phase 1 (Tipagem + CI + Refactors seguros)

- **[F1.1] `OdbcBackend` sealed class.** Novo
  `lib/infrastructure/native/odbc_backend.dart` com variantes
  `SyncBackend` e `AsyncBackend`. `OdbcRepositoryImpl` foi migrado
  do antigo `final dynamic _native` (que tinha 100 casts `as`) para
  pattern matching exaustivo via `_backend`. API pública preservada:
  os dois construtores existentes continuam funcionando
  (`OdbcRepositoryImpl(NativeOdbcConnection)` e
  `OdbcRepositoryImpl(AsyncNativeOdbcConnection)`).
- **[F1.2] Helper `_runBoolFfi` no repositório.** Centraliza o padrão
  switch-sync-vs-async + null-check + `_convertNativeErrorToFailure`
  para chamadas FFI que retornam `bool`. Usado em
  `commitTransaction`, `rollbackTransaction` e `poolSetSize`.
- **[F1.3] Coverage Dart no CI.** `.github/workflows/ci.yml` agora
  roda `dart test --coverage` + `format_coverage` + upload Codecov no
  job `coverage` (paralelo ao `cargo tarpaulin` para Rust).
- **[F1.4] `FakeAsyncNativeForRepositoryErrors` em
  `test/helpers/`.** Extraído do test file inline
  `odbc_repository_impl_test.dart`, agora reusável por outros suites.
- **[F1.5] `OdbcRepositoryImpl.dartSideMetrics()`.** Nova entity
  `DartSideMetrics` exposta no barrel. Conta connection ids,
  statement ids, named-param metadata, pooled connections e pool
  checkouts. Útil em endpoints de health.
- **[F1.6] Validação XML reforçada.** `_validateXmlShape` em
  `param_value.dart` agora verifica balanço de tags (`<` vs `>`) e
  aplica cap de 4 MB (mesmo padrão da validação JSON).
- **[F1.7] Dartdoc completo de
  `XaTransactionHandle.runWithStart`.** Documenta lifecycle states,
  concorrência, e quando preferir `runWithStartOnePhase`.

### Adicionado — Phase 2 (Performance aditiva + Observability)

- **[F2.1] `SqlPointerCache` (LRU 256 entries).** Cache de
  `Pointer<Utf8>` por SQL string em `lib/infrastructure/native/bindings/
  sql_pointer_cache.dart`. Elimina `toNativeUtf8 + malloc.free` em
  hot loops de SQL repetido. Acompanhado de microbenchmark
  comprovando que o caminho cached é mais rápido que o legacy.
- **[F2.2] `LazyString` aditiva.** Nova classe pública em
  `lib/infrastructure/native/protocol/lazy_string.dart`. Wrapper
  `Uint8List → String` com decodificação lazy + suporte a `==`
  contra `String`. Building block para consumers que querem evitar
  `utf8.decode` por célula em result sets grandes.
- **[F2.3] Fuzz tests do `BinaryProtocolParser`.** 11k iterações
  aleatórias (10k random bytes + 1k headers válidos com lengths
  corrompidos). Defesa-em-profundidade sobre os DoS guards. Limita
  cada parse a 100ms.
- **[F2.4] Telemetry decorator instrumenta streams.** Helper
  `_wrapStream<T>` emite eventos `stream.open` / `stream.close` /
  `stream.error` com chunk count + duration. Aplicado em
  `streamQuery`, `streamQueryMulti`, `streamQueryNamed`.
- **[F2.5] Diagrama Mermaid stream + recovery.** Novo bloco em
  `native/doc/async_api_guide.md` mostrando o caminho worker crash
  → handleWorkerCrash → onWorkerRecovered → repository state cleanup.
- **[F2.6] `profile_selection_guide.md`.** Decision tree completo
  (Flutter / CLI / server / batch ETL) + tabela com defaults
  resolvidos por profile + guia de quando override.

### Adicionado — Phase 3 (Arquitetura aditiva)

- **[F3.1] Sub-interfaces de `IOdbcService`.** Quatro novas
  interfaces (`IQueryService`, `ITransactionService`, `IPoolService`,
  `IAdminService`). `IOdbcService` agrega via `implements` —
  consumers existentes não quebram, novos podem depender só do
  subset que precisam (Interface Segregation Principle).
- **[F3.2] `TypedColumnarResult` + `toTypedColumnar()`.** Nova
  representação column-major com `Int32List`/`Int64List`/`Float64List`
  para colunas numéricas (sem boxing). `QueryResult` row-major
  permanece intacto. Conversão é opt-in via `toTypedColumnar(qr)`.
- **[F3.3] Zero-copy FFI: avaliação documentada.** Novo
  `native/doc/zero_copy_ffi_evaluation.md` com análise de viabilidade,
  pré-requisitos (Finalizable + symbol release Rust, ABI bump,
  cross-platform allocator audit) e decisão de adiar para
  feature-flag em release futuro.
- **[F3.4] `OdbcRepositoryState` extraído (Step 1 do split).** Maps
  de estado e helpers (`clearStatementMetadataForConnection`,
  `clearAll`, `validateStatementOwnership`, `dartSideMetrics`) movidos
  para `lib/infrastructure/repositories/repository_state.dart`. Plano
  completo do split (steps 2-9) documentado em
  `native/doc/repository_split_plan.md`. Steps subsequentes ficam
  para PRs dedicadas conforme a doc de plano.

### Mudou

- `lib/odbc_fast.dart` (barrel) ganha exports aditivos:
  `DartSideMetrics`, `LazyString`, `TypedColumnarResult` (e
  variantes), `toTypedColumnar`, `IQueryService`, `ITransactionService`,
  `IPoolService`, `IAdminService`. Nenhum export existente removido.

## [3.9.0] - 2026-05-25

### Fixed (pool de conexão e controle de transação)

- **[CRITICAL — pool]** `poolGetConnection` now records the connection string sentinel
  `"pool://<poolId>"` in `_connectionStrings` and registers ownership in the new
  `_poolCheckouts` / `_connectionPoolId` maps so that options, cleanup, and pool membership
  checks work correctly for pooled connections.
- **[CRITICAL — pool]** `poolReleaseConnection` now calls
  `_clearStatementMetadataForConnection` before removing the connection ID, preventing
  indefinite growth of `_namedParamOrderByStmtId` and `_statementConnectionByStmtId` for
  prepared statements opened on pooled connections.
- **[CRITICAL — pool]** `poolClose` now sweeps all checked-out connection IDs for the
  closing pool from every Dart-side map (`_connectionIds`, `_connectionStrings`,
  `_connectionOptions`, statement metadata) so callers cannot accidentally execute against
  invalidated native handles after pool destruction.
- **[CRITICAL — transaction]** `commitTransaction`, `rollbackTransaction`,
  `createSavepoint`, `rollbackToSavepoint`, and `releaseSavepoint` now validate both
  `connectionId` (must be an active connection in `_connectionIds`) and `txnId` (must be
  > 0) before calling the native layer; the native connection ID is also forwarded to
  `_convertNativeErrorToFailure` so async error reads are routed to the correct worker
  isolate instead of an arbitrary least-loaded one.
- **[HIGH — pool]** `disconnect()` now returns `ValidationError` immediately when called
  on a pool-owned connection, preventing the wrong native API (`odbc_disconnect` vs
  `odbc_pool_release_connection`) from being invoked.
- **[HIGH — pool]** Added `poolId <= 0` validation to `poolGetConnection`,
  `poolHealthCheck`, `poolGetState`, and `poolClose`, matching the existing guard in
  `poolSetSize`.
- **[HIGH — pool]** `poolHealthCheck` now returns `Failure(ConnectionError)` with
  structured-error detail when the pool check returns false, instead of `Success(false)`
  which was indistinguishable from "pool does not exist".
- **[HIGH — pool]** `bulkInsertParallel` now validates `poolId`, `table`, `columns`,
  `dataBuffer`, and `rowCount` before calling the native layer; the `poolReleaseConnection`
  result in the `finally` block is checked and logged via `AppLogger.warning` instead of
  being silently discarded.
- **[HIGH — async affinity]** `AsyncNativeOdbcConnection` now maintains a
  `_transactionConnectionById` map (`txnId → nativeConnectionId`) so that
  `_clearConnectionAffinity` can remove stale transaction worker entries when a connection
  is disconnected or pool-released.
- **[HIGH — async affinity]** `_transactionWorkerById` entries are now removed
  unconditionally after commit or rollback (not only on success), preventing stale
  transaction-to-worker mappings that would route subsequent operations to the wrong
  isolate.
- **[HIGH — transaction]** `TransactionHandle.runWithBegin` no longer attempts an
  emergency rollback after a commit failure: the native engine removes the transaction
  handle from its registry before issuing `SQL COMMIT`, making any subsequent rollback call
  a silent no-op. Cleanup is handled by `odbc_disconnect`.
- **[MEDIUM — transaction]** `TransactionHandle.createSavepoint`,
  `rollbackToSavepoint`, and `releaseSavepoint` now return `false` immediately when
  `_state != active`, preventing spurious FFI calls on committed, rolled-back, or
  failed transaction handles.
- **[MEDIUM — transaction]** `TransactionHandle.withSavepoint` now checks and throws
  `StateError` when `releaseSavepoint` fails on the success path, and when
  `rollbackToSavepoint` fails on the error path, so callers are never silently left with a
  savepoint in an unknown state.
- **[MEDIUM — transaction]** Savepoint name is validated in the repository before reaching
  FFI — empty or whitespace-only names now return `ValidationError` immediately.
- **[MEDIUM — pool]** `PoolOptions.toJson` now clamps `Duration` values to 0 before
  serialising to JSON, preventing negative millisecond values that would overflow Rust's
  `u64` fields.

### Fixed

- **[CRITICAL]** `OdbcService.executeQuery` now returns `Failure(ConnectionError(...))` instead of
  throwing when `connectionId` is null or empty — aligns with the `Result<T>` contract used by
  all other service methods and prevents unhandled exceptions inside `runInTransaction` helpers.
- **[CRITICAL]** `OdbcService.runInXaTransaction` calls `_xaSafelyAbort` on every XA phase failure
  (`xa_end`, `xa_prepare`, `xa_commit_prepared`, `xa_commit_one_phase`), not only on user-action
  failures — prevents XA branches from being left in an open state on the resource manager.
- **[CRITICAL]** Worker isolate in `workerEntry` now closes its `ReceivePort` when
  `NativeOdbcConnection` construction fails, so the main isolate detects the channel death instead
  of waiting for per-request timeouts.
- **[CRITICAL]** `TelemetryBuffer._startPeriodicFlush` timer no longer calls `flush()` before
  `onFlush?.call()`; the repository's `_exportBatch` calls `flush()` itself, so the previous double
  call silently discarded every time-triggered telemetry batch.
- **[CRITICAL]** `XaTransactionHandle.commitPrepared` sets `_state` to the new
  `XaState.failedAfterPrepare` (not `failed`) when the commit fails. Cleanup paths in
  `runWithStart` and `OdbcService._xaSafelyAbort` now correctly call `rollbackPrepared()` for this
  state instead of the wrong `xaRollbackActive` opcode.
- **[HIGH]** `BinaryProtocolParser` and `_BufferReader.readString` decode column names with
  `utf8.decode(..., allowMalformed: true)` instead of `String.fromCharCodes` (Latin-1), fixing
  silent corruption of non-ASCII column identifiers (Japanese, Arabic, etc.).
- **[HIGH]** `BulkInsertBuilder._validateTextColumn` validates `maxLen` exclusively in bytes (UTF-8
  encoded length) and no longer also compares against raw character count with the same limit —
  multi-byte strings were incorrectly rejected when `maxLen` was defined in characters.
- **[HIGH]** `ServiceLocator.initialize` and `shutdown` now dispose the sync
  `NativeOdbcConnection` as well as the async pool, preventing FFI handle leaks on re-initialization
  and app shutdown.
- **[HIGH]** `OdbcError.isRetryable` extended to include deadlock (`40001`, `40P01`) and
  ODBC timeout (`HYT00`, `HYT01`) SQLSTATEs in addition to the previous `08xxx` family.
  `ResourceLimitReachedError` overrides `isRetryable` to return `true` (consistent with its
  `category = transient`).
- **[HIGH]** `TransactionHandle.runWithBegin` attempts a best-effort rollback when commit fails
  (not only when `isActive`), preventing the DB transaction from remaining open after a commit
  failure (deadlock, disconnect, constraint error).
- **[HIGH]** `NativeOdbcConnection.dispose` resets `_isInitialized = false` so subsequent calls
  to `connect` correctly detect the uninitialized state.
- **[HIGH]** `callWithBuffer` (and `_ReusableFfiScratch.call`) clamp the initial buffer size to
  `min(initialSize, limit)` so callers passing `maxBufferBytes` smaller than 64 KB (the default
  initial size) now enter the retry loop instead of returning `null` without an FFI call —
  `PreparedStatement.execute(maxBufferBytes: N)` with N < 65 536 was silently broken.
- **[MEDIUM]** `OdbcService.dispose` now forwards to `IOdbcRepository.dispose` (new default no-op
  on the interface; overridden in `OdbcRepositoryImpl`) so async worker isolates are released when
  the service is disposed.
- **[MEDIUM]** `StructuredError.deserialize` uses `utf8.decode(..., allowMalformed: true)` to
  prevent a `FormatException` from escaping on malformed FFI payloads.
- **[MEDIUM]** `_isUnsupportedCancellation` removed the redundant raw `sqlState` comparison that
  was always covered by the normalized check.
- **[LOW]** `ParsedRowBuffer.columnNames` is now a `late final` field cached on first access,
  avoiding a new `List<String>` allocation on every getter call.
- **[LOW]** `ServiceLocator` property getters (`service`, `syncService`, `repository`,
  `nativeConnection`) throw an actionable `StateError` before initialization instead of a
  `LateInitializationError`.

### Performance

- **`serializeParams` single-buffer** — replaced the old `List<int>` grow + per-param `addAll` +
  final `Uint8List.fromList` with a two-pass strategy: phase 1 pre-encodes text/decimal payloads
  and computes the exact byte count; phase 2 writes all params directly into a single pre-sized
  `Uint8List` using `ByteData` setters. Eliminates every intermediate `List<int>` allocation per
  param and the final full-buffer copy. Impact is highest for queries with many or large string
  parameters.
- **`_connectionOptions` single lookup per operation** — added `_optionsFor(connectionId)` helper
  so that every execute method performs one `HashMap` lookup instead of two (one for `maxBytes`,
  one for `queryTimeout`). Applies to `executeQuery`, `executeQueryParams`,
  `executeQueryParamBuffer`, `executeQueryMultiFull`, `executeQueryMultiParams`, `streamQuery`, and
  the streaming path — i.e., every hot query method.
- **`_toQueryResultMulti` pre-sized list** — replaced `.map().toList()` with
  `List.generate(..., growable: false)` to pre-allocate the result list without the intermediate
  lazy iterator.
- **Row-major v1 parse** — `_parseRowMajorV1` now pre-allocates fixed-size row lists with
  `List.generate` + `List.filled` instead of creating one growable `List<dynamic>` per row;
  for large result sets this removes O(rowCount) header allocations and eliminates incremental
  `add` amortisation overhead.
- **Binary cell decode** — `_convertData` returns the `Uint8List.sublistView` directly for binary
  columns instead of copying via `Uint8List.fromList`; callers that need a mutable independent
  copy can use `Uint8List.fromList(cell as Uint8List)`.
- **Column names in QueryResult** — `_parseBufferToQueryResult` and the streaming path now use
  the cached `ParsedRowBuffer.columnNames` instead of re-mapping `columns.map((c) => c.name)`
  on every parse call.
- **`getError` / `detectDriver`** — replaced `Int8List.map((e) => e.toUnsigned(8)).toList()` +
  `utf8.decode` with a zero-allocation `Pointer.cast<Uint8>().asTypedList(n)` view; removes one
  `List<int>` allocation per native error read and per driver detection call.
- **`execQueryMultiParams` param copy** — replaced O(n) Dart byte-by-byte loop with
  `setAll(0, paramsBuffer)` (bulk memcpy delegate), matching the existing approach in other
  `_withParamsBuffer` paths.
- **`deserializeParamValue` OUT payload** — uses `Uint8List.sublistView` instead of `sublist`
  for the per-param payload slice; avoids one copy per OUT/INOUT parameter in DRT1 responses.

### Changed

- `BulkInsertBuilder.build` uses `BytesBuilder` instead of a growing `List<int>` + final
  `Uint8List.fromList` copy, reducing GC pressure for large bulk inserts by eliminating one full
  buffer copy.
- `BulkInsertBuilder._validateTextColumn` no longer calls `utf8.encode` when `maxLen == 0`
  (unlimited), avoiding a full UTF-8 encoding pass that was unconditionally allocated per cell.
- Added `XaState.failedAfterPrepare` to the public `XaState` enum to distinguish a commit failure
  after a successful `xa_prepare` from other failure modes.
- `IOdbcRepository` now declares a default no-op `dispose()` method so implementations can
  override it without breaking existing mock implementations.
- `ServiceLocator.shutdown` doc updated to reflect that sync resources are now also released.

### Changed

- Columnar encoder compression threshold raised from 100 bytes to 1 024 bytes
  per column payload; sub-1 KB columns now skip the zstd round-trip whose
  overhead exceeded the transfer savings at that size.
- `odbc_pool_get_connection` now logs a `warn!` when the pool is closed between
  the r2d2 checkout and the state re-lock so orphaned pooled connections become
  visible in logs instead of being silently registered.
- `odbc_transaction_begin_v3` documents the `savepoint_dispatch` concurrency
  limitation (global state mutex held for the duration of savepoint SQL) with a
  tracking comment (`ISSUE-TXN-SAVEPOINT-LOCK`) for the follow-up `Arc<Transaction>`
  refactor.
- `pool/mod.rs` `GLOBAL_POOL_ENV` now carries an explicit architecture note
  explaining that pool connections and direct connections use independent ODBC
  environments; environment-level settings applied via `odbc_init` do not
  propagate to pool connections and vice-versa.
- `Arena::allocate` and `Arena::allocate_aligned` now document their oversized
  allocation strategy in their `# Safety` sections; the `unsafe impl Sync`
  blocks carry explicit rationale comments.
- Examples and internal comments were refreshed to match the current `xa-dtc`,
  DRT1 / `OUT1` / `MULT`, Oracle `REF CURSOR` and `ResultEncoding` behavior.
- Documentation drift checks and opt-in example smoke tests now pin the
  canonical DRT1/OUT1/MULT matrix, live-driver flags and stale backlog wording.
- CI and local validation now include DSN-free docs/example smoke tests, with
  `doc/TESTING.md` owning the canonical live-driver opt-in flags.
- Native FFI sync parameter paths now borrow parameter buffers only for the
  duration of the call instead of copying them first; async paths still take an
  owned copy for worker safety. Streaming chunk reads now share internal copy
  helpers, and multi-result row-count frames avoid an extra small payload
  allocation. FFI buffer writes now go through shared internal helpers, and
  `bulk_operations_bench` includes a deterministic `streaming_copy_next_chunk`
  guardrail.
- Native metadata cache hits now use shared internal schema/payload storage so
  catalog cache reads avoid deep clones on the hot path. Catalog FFI cache hits
  copy the shared payload directly into the caller output buffer while keeping
  the existing ABI and Dart API unchanged.
- Benchmark tooling now distinguishes materialised streaming from batched
  streaming in `comparative_bench`, and `scripts/run_dart_benchmarks.py` can
  opt in to failing on Criterion regression reports with
  `BENCHMARK_FAIL_ON_CRITERION_REGRESSION=1`.

### Security

- `SAFETY:` comments added to 15+ previously unannotated `unsafe` blocks across
  `ffi/mod.rs` and `ffi/columnar_decompress.rs`, covering `set_out_written_zero`,
  `set_out_written_needed`, `odbc_get_version`, `odbc_get_error`,
  `odbc_get_structured_error`, `odbc_get_structured_error_for_connection`,
  `odbc_get_metrics`, `odbc_get_cache_metrics`, `odbc_async_poll`,
  `odbc_stream_poll_async`, `odbc_stream_fetch`, `odbc_pool_get_state`,
  `odbc_pool_get_state_json`, `odbc_bulk_insert_array`,
  `odbc_columnar_decompress`, `odbc_columnar_decompress_free`,
  `odbc_pool_create`, `odbc_pool_create_with_options`, and `savepoint_dispatch`.
  All existing `Safety:` comments at call sites were normalised to `// SAFETY:`.

### Fixed

- `odbc_connect_with_timeout`: `timeout_ms = 0` now correctly maps to no login
  timeout (driver default) instead of a 1-second minimum; sub-1000 ms values
  are rounded up to 1 second as before.
- `odbc_pool_release_connection` and `odbc_pool_close`: removed `.expect()` on
  `HashMap::remove` so a race between pool inspection and removal returns an
  explicit error instead of panicking (guarded by `FfiError::Panic` but now
  avoids the path entirely).
- `execute_multi_result_inner` and `execute_multi_result_with_params_inner`:
  four `encode_multi(...).expect(...)` calls replaced with `try_encode_multi?`
  so oversized multi-result payloads propagate `OdbcError::ResourceLimitReached`
  to the Dart caller instead of panicking at the FFI boundary.
- `run_buffered_connection_call`: `out_written` pointer is now zeroed on all
  mutex-failure and connection-lock-failure paths; previously a subset of
  those paths returned an error code without writing to `out_written`, leaving
  the caller-supplied pointer with its original (stale) value.
- `apply_lock_timeout` (MySQL/MariaDB and DB2 paths): two `.expect()` calls
  replaced with `OdbcError::InternalError` returns; the conditions are
  unreachable in practice but panics are not acceptable in production paths.
- `odbc_columnar_decompress`: address-reuse guard added to `DECOMPRESS_ALLOCATIONS`
  — if a freshly-allocated buffer address is already registered the function now
  returns `FfiError::InternalLock` instead of silently clobbering the existing
  entry, which would have caused a use-after-free or double-free on the old caller.
- `odbc_transaction_begin_v3`: mutex-poison failure after a successful
  `Transaction::begin` now logs an explicit `error!` message so operators can
  identify that `conn_id` is permanently stuck in `transaction_begins_in_progress`
  (the connection is blocked from new transactions until the process restarts).
- `Arena::allocate(size > chunk_size)`: returned a pointer into a chunk that was
  only `chunk_size` bytes; callers that wrote beyond `chunk_size` would silently
  corrupt heap memory. Now allocates a dedicated oversized chunk of exactly `size`
  bytes; the regular current chunk is preserved for subsequent smaller allocations.
- `Arena::allocate_aligned(size > chunk_size)`: recursed infinitely because each
  recursive call found the same oversized `size` exceeding the freshly-created
  `chunk_size` chunk. Now handled with the same dedicated oversized-chunk path
  as `allocate`.
- `odbc_pool_set_size`: error message when the pool is closed or invalidated
  during a concurrent resize now says "Pool was closed while resize was in
  progress" instead of the generic "Invalid pool ID", making it easier to
  distinguish a race from a missing-pool programming error.

- Native FFI no longer replays cached results after a `-2` buffer-too-small
  response; retries now execute through the normal call path without hidden
  pending-result state.
- Synchronous parameterized FFI entrypoints now reject `NULL` parameter buffers
  when `params_len > 0`, matching the async parameter validation contract.
- Batched, async, and multi-result streaming FFI entrypoints now accept checked
  out pool connection IDs and keep pool busy accounting active until the stream
  worker finishes.
- Connection-string validation now rejects extra closing braces instead of
  accepting them through saturating brace-depth arithmetic.
- Columnar and compressed columnar query paths now reuse singleton pipelines,
  and telemetry export no longer holds the global telemetry mutex while the
  exporter performs blocking work.

## [3.8.1] - 2026-05-22

### Added

- Native FFI `odbc_execute_async_params_options` (additive) so parameterized
  async execution can request `ResultEncoding` (row-major, columnar v2, or
  columnar compressed) on the background task; Dart bindings and the worker
  isolate forward `resultEncodingWire` from `ExecuteAsyncStartParamsRequest`.

### Changed

- `executeQueryParamBuffer` on async connections attempts the native async path
  for all result encodings when the options symbol is present, reducing
  `fallbacksToBlocking` for columnar workloads.
- FFI export-surface validation now derives the canonical symbol list from Rust
  `#[no_mangle] extern "C"` entrypoints and checks `.def`, `cbindgen`, generated
  header, and Dart native lookups for drift.

### Fixed

- Windows native exports now include `odbc_columnar_decompress` and
  `odbc_columnar_decompress_free`, keeping compressed columnar v2 decoding
  available through the DLL export table.

## [3.8.0] - 2026-05-21

### Added

- **`OdbcUsageProfile`** presets (`balanced`, `balancedFlutter`,
  `balancedServer`, `highThroughput`, `legacy`) with a centralized resolver for
  async workers, backpressure, connection defaults, pool defaults, and
  recommended pool size.
- **`ConnectionOptions.fromUsageProfile`** and **`PoolOptions.fromUsageProfile`**
  for login/query timeouts, reconnect-on-drop, and pool eviction knobs aligned
  with each profile.
- **`ResolvedOdbcUsageProfile`** as a public value object for inspecting the
  effective preset shape exposed by `ServiceLocator`.
- Example **[`example/quick_start_balanced_demo.dart`](example/quick_start_balanced_demo.dart)**.
- **Native unit test coverage (`odbc_engine`):** expanded colocated `#[cfg(test)]`
  suites across protocol (`bulk_insert`, `param_value`, `multi_result`,
  `encoder`), engine core (batch/execution binding plans, ref cursor, spill,
  metadata cache, driver capabilities), streaming/XA/transaction state and SQL
  shape checks, FFI guard/columnar validation, plugin catalog dialect helpers,
  security/sanitize/audit, and pool configuration—without requiring a live ODBC
  DSN. Full lib + integration tarpaulin run reaches **~60%** line coverage
  (up from **~55%** before this push); reproduce with
  `python native/odbc_engine/scripts/run_coverage.py`.
- **SQL Server BCP unit tests (`sqlserver-bcp`):** Windows-only validation and
  `build_bound_columns` coverage with the feature enabled; the `sqlserver-bcp`
  Cargo feature now enables `libloading` for native DLL loading.

### Changed

- [`ServiceLocator.initialize`](lib/core/di/service_locator.dart) keeps the
  historical **`OdbcUsageProfile.legacy`** default for SemVer compatibility.
  Use **`initialize(profile: OdbcUsageProfile.balanced)`**,
  **`balancedFlutter`**, **`balancedServer`**, or **`highThroughput`** to opt in
  to the new async presets. Call **`locator.shutdown()`** on exit when using
  async mode.
- [`ServiceLocator`](lib/core/di/service_locator.dart) exposes
  **`usageProfile`**, **`recommendedConnectionOptions`**,
  **`recommendedPoolOptions`**, **`recommendedPoolMaxSize`**, and
  **`resolvedUsageProfile`** derived from the active profile plus explicit
  async overrides.
- Corrected the async-default documentation in [`doc/PERFORMANCE.md`](doc/PERFORMANCE.md)
  so `ServiceLocator.initialize()` and direct `AsyncNativeOdbcConnection(...)`
  defaults are described separately.
- **Batch and execution param routing:** extracted
  `plan_batch_param_binding`, `plan_query_param_binding`,
  `plan_multi_result_param_binding`, `encode_row_count_only`, and batch routing
  helpers (`batch_query_uses_optimized_path`, `should_skip_batch_optimized_execution`,
  `batch_param_set_chunk_count`) so production paths and unit tests share the
  same dispatch logic.
- **Telemetry console export:** `ConsoleExporter` delegates to
  `observability::telemetry::console::export_trace` so JSON trace export is
  covered by unit tests.

### Fixed

- **Transaction begin race on the same connection:** native `odbc_transaction_begin*`
  now serializes `begin` per `conn_id`, preventing two concurrent callers from
  opening overlapping local transactions on the same connection.
- **Pooled checkout transaction support:** `conn_id` values returned by
  `odbc_pool_get_connection` now work across the full local transaction
  lifecycle (`begin`, `commit`, `rollback`, savepoints) instead of failing when
  passed to `beginTransaction`.
- **`TransactionHandle.runWithBegin` false-success path:** the Dart helper now
  throws `StateError` when commit fails, so callers never receive a successful
  action result for a transaction that did not commit.
- **Pool resize config loss:** `poolSetSize(...)` now recreates the native pool
  from the resolved runtime config snapshot, preserving `PoolOptions`, checkout
  validation, and any configured health-check query after resize.
- **`benchmark_harness` m1/m2 scripts:** restored compilation and meaningful
  timings by using `AsyncBenchmarkBase`, shared `benchmarks/odbc_async_benchmarks.dart`,
  connect/disconnect per iteration, and `scripts/run_dart_benchmarks.py --harness`.
- **Rust Clippy (`-D warnings`):** wired batch routing helpers into production
  code (fixing `dead_code` on test-only exports), simplified `async_bridge`
  test `block_on`, and replaced a redundant `vec!` in batch executor tests.

## [3.7.0] - 2026-05-14

### Added

- **Async worker pool:** `AsyncNativeOdbcConnection(workerCount: ...)` and
  `ServiceLocator.initialize(useAsync: true, asyncWorkerCount: ...)` allow
  opt-in parallel worker isolates while keeping the default at `1`.
- **Async parameterized FFI:** added optional
  `odbc_execute_async_params(conn_id, sql, params_buffer, params_len)` with
  Dart capability fallback for older native binaries.
- **High-concurrency examples:** added
  `example/high_concurrency_worker_pool_demo.dart` and
  `example/high_concurrency_pool_demo.dart`, documented in README,
  `example/README.md`, `native/doc/async_api_guide.md`, and
  `doc/PERFORMANCE.md`.
- **Async backpressure and stats:** added
  `AsyncNativeOdbcConnection(maxPendingRequests: ...)`,
  `ServiceLocator.initialize(asyncMaxPendingRequests: ...)`,
  `AsyncErrorCode.resourceExhausted`, and `getWorkerPoolStats()` for Dart-side
  worker pool counters.
- **Async backpressure wait mode:** added
  `AsyncBackpressureMode.waitForSlot` and timeout configuration for FIFO
  waiting when callers prefer short queueing over immediate failure.
- **Per-worker diagnostics:** worker pool stats now include per-worker
  routed/completed/failed/timeout/fallback/cancel counters and latency
  aggregates.
- **Service diagnostics:** `IOdbcService` and `IOdbcRepository` now expose
  `getAsyncWorkerPoolStats()`.
- **Async benchmark/check tooling:** added
  `example/async_concurrency_benchmark.dart` and
  `tool/check_ffi_exports.dart`.
- **Opt-in result encoding:** added `ResultEncoding` on Dart parameterized query
  paths and the additive FFI symbol `odbc_exec_query_params_options` for
  row-major v1, columnar v2, and compressed columnar v2 selection with fallback
  to row-major on older native runtimes.
- **Opt-in concurrency validation:** added Dart real-DSN stress coverage for
  multi-connection parallelism, same-connection serialization, and native pool
  checkout/query/release with an explicit in-flight limit.
- **Slow-test diagnostics:** added `tool/test_slow_report.dart` to run
  `dart test --reporter json`, report the slowest tests, and optionally fail
  when a configured slow-test budget is exceeded.
- **Streaming benchmark:** added `example/streaming_performance_benchmark.dart`
  to compare `streamQuery` and `streamQueryBatched` with text/json/csv output.
- **Benchmark baseline comparison:** added
  `tool/compare_benchmark_baseline.dart` for JSON benchmark regression checks.
- **Protocol parser benchmark coverage:** expanded
  `test/performance/protocol_performance_test.dart` with DSN-free row-major,
  columnar, frame accumulator, and streaming multi-result decoder timings.

### Changed

- Async worker routing now distributes independent calls by worker load and
  preserves affinity for connection, statement, transaction, stream, and async
  request handles.
- Async result and stream fetch payloads use `TransferableTypedData` across
  isolates when possible, and streaming frame assembly uses an incremental
  accumulator to reduce avoidable copies.
- FFI buffer growth can jump directly to `out_written` when a native call
  reports the required size with `-2`.
- Async worker crash/dispose paths now clear worker-handle affinities for the
  discarded worker before recovery or shutdown.
- Async worker-pool stress thresholds now compare parallel/concurrent timings
  against a local serial baseline instead of fixed wall-clock limits.
- Live `test/my_test` table scans are bounded by default via
  `MY_TEST_ROW_LIMIT`, skipped unless `RUN_LIVE_TESTS=1`, and require
  `MY_TEST_FULL_TABLE_SCAN=1` for deliberate full-table performance runs.
- The Produto live streaming check now uses `streamQueryBatched` so the default
  path exercises bounded streaming chunks instead of materializing as one large
  stream unit.
- Async responsiveness/concurrency unit tests now use deterministic fake worker
  delays instead of SQL Server `WAITFOR`, keeping live slow-query coverage in
  stress tests.
- Columnar v2 Dart decoding now fills row-major output directly instead of
  materializing a full intermediate column list before transposing.
- Binary frame accumulation now keeps a chunk queue and only copies when a
  complete frame spans multiple chunks.
- Dart FFI buffer calls now reuse a per-isolate scratch buffer with a
  reentrancy fallback, reducing repeated buffer and `out_written` allocations.
- Async worker pool p95 latency snapshots are cached until new samples arrive.
- Rust row-to-columnar conversion now preallocates the target column list and
  keeps binary columns in the columnar binary representation.
- High-concurrency examples now print directly to stdout, document the worker
  isolate/threading model, and accept `ODBC_CONCURRENCY_QUERY`.

### Fixed

- Parameterized async execution now follows `start -> poll -> get_result ->
  free` when supported, with best-effort cancel/free on timeout and fallback to
  the existing blocking worker path on older runtimes.
- Async stream cleanup now attempts `streamCancel` before `streamClose` when a
  stream exits before normal completion.
- Cancellation documentation now distinguishes best-effort async cancellation,
  stream cancellation between batches, and statement cancellation that may be
  unsupported by a runtime/driver path.
- Native FFI buffer-too-small (`-2`) paths now report the required byte count
  through `out_written` consistently, including stream fetch and metadata
  helpers.

## [3.6.1] - 2026-05-13

Patch release: Rust FFI and wire-format throughput, safer bulk v2 defaults, and
tighter regression coverage. No Dart SDK constraint change.

### Added

- **Bulk payload v2:** Dart `BulkInsertBuilder.build()` now emits the `BLK2`
  wire format by default and exposes `BulkPayloadVersion { legacy, v2 }`.
  Rust auto-detects v1/v2 in `odbc_bulk_insert_array` and
  `odbc_bulk_insert_parallel`, preserving compatibility with existing payloads.
- **Regression coverage:** added Rust coverage for bulk v2 binary cells with
  embedded `NUL`, variable-length binary cells, truncation and max-length
  validation, pending-result replay, per-connection errors, parallel bulk
  chunking, and streaming spill encoding. Dart coverage now verifies the v2
  default, legacy format opt-in, binary `NUL` preservation, and `maxLen`
  validation. Opt-in Rust E2E coverage now exercises bulk v2 binary readback,
  global-state availability during long FFI calls, pool close/resize busy
  guards during in-flight pooled execution, and spill-backed streaming.

### Fixed

- **Binary bulk insert correctness:** v2 variable-width cells carry a per-cell
  length, so binary values such as `Uint8List([1, 0, 2])` are no longer
  truncated at the first `0x00`.
- **FFI concurrency:** long ODBC calls in connection lifecycle, query,
  prepared execution, catalog metadata, savepoint/XA transitions, streaming,
  pool release/close, and bulk insert paths no longer run while `GLOBAL_STATE`
  is locked. The global mutex is now limited to lookup/registration,
  pending-buffer replay, metrics, and error recording.
- **Pool close/resize safety:** pooled connections temporarily removed from
  global state for active FFI calls are tracked as busy, preventing pool close
  or resize from racing an in-flight operation.
- **SQL Server E2E:** null-only parameterized execution test uses
  `CAST(? AS INT)` so SQL Server Native Client does not fail with ambiguous type
  inference for `@P1` (native error 11506).

### Changed

- **Bulk/streaming performance:** pool-based parallel bulk insert uses row
  ranges/views on the default ArrayBinding path to avoid cloning each chunk's
  full payload. Row-buffer encoding now preallocates the final wire buffer,
  spill encoding avoids per-chunk temporary `Vec` allocations, and file-backed
  streaming keeps the spill file open while fetching chunks instead of
  reopening/seeking on every read. `odbc_stream_fetch` now copies stream chunks
  directly into the caller buffer, avoiding an intermediate `Vec` allocation
  and removing the pending-chunk copy path on `-2` retries. Binary cell reads
  retain the internal scratch-buffer capacity between cells to reduce repeated
  allocations on binary-heavy result sets. Bulk payload serialization
  preallocates the expected output size, legacy bulk text/binary parsing copies
  only the trimmed cell bytes, and multi-result encoding validates/preallocates
  payload size before writing. Columnar encoding writes uncompressed column
  payloads directly into the final buffer, parameter-list serialization writes
  into one preallocated buffer, and ArrayBinding SQL assembly avoids temporary
  `Vec` joins for placeholders/columns. The `sqlserver-bcp` feature keeps a
  documented chunk materialization fallback because the BCP executor consumes
  an owned payload.
- **Statement reuse docs:** documentation now states that
  `statement-handle-reuse` remains opt-in and that the default path keeps only
  metrics/cache metadata, not reusable statement handles.

## [3.6.0] - 2026-05-02

### Added

- **Async diagnostics parity:** the worker-isolate backend now exposes
  per-connection structured error retrieval, aligning async error diagnostics
  more closely with the sync/native backend.
- **Regression coverage:** added Dart and Rust tests for repeated named
  placeholders, parameterized execution with more than five parameters,
  parameterized multi-result execution, NULL-heavy parameter binding, async
  statement metadata invalidation, and async streaming fallback behavior.
- **Test coverage expansion:** unit/component coverage was extended in Dart for
  parser, prepared-statement, async-wrapper, repository-gap, driver capability,
  library loader, telemetry, and stress-oriented paths; Rust and opt-in E2E
  coverage were expanded for `>5` parameters, repeated named-parameter flows,
  NULL scenarios, and batch / multi-result execution paths.
- **Examples:** `example/named_parameters_demo.dart` now demonstrates repeated
  named placeholders and `>5` named parameters; `example/multi_result_demo.dart`
  now includes `executeQueryMultiParams`; `example/README.md` lists additional
  demos that were previously omitted from the index.

### Fixed

- **Parameterized execution limit:** removed the artificial runtime cap of 5
  parameters across direct execution, prepared statements, named-parameter
  execution (`executeQueryNamed`, `prepareNamed`, `executePreparedNamed`),
  parameterized multi-result execution, and batch execution. Named parameters
  benefit from the same fix because they are expanded into the positional
  runtime pipeline before execution. The effective limits now come from the
  package protocol safety cap and the underlying driver/database.
- **Named parameter semantics:** repeated placeholders such as `@id` / `:id`
  now preserve occurrence order and correctly reuse the same input value at
  every positional expansion.
- **Named parameter parsing robustness:** placeholder rewriting now skips SQL
  string literals, identifier quotes, line comments, nested block comments, and
  PostgreSQL-style dollar-quoted strings, avoiding accidental rewrites inside
  SQL text.
- **Typed NULL binding and inference:** Rust parameter binding now uses typed
  input parameters instead of coercing everything through strings, improving
  correctness for `NULL`, binary values, mixed integer/BigInt families, and
  metadata-driven parameter descriptions in direct, prepared, directed, and
  batch paths.
- **Async statement invalidation:** `clearAllStatements`, `disconnect`, and
  reconnect flows now clear Dart-side prepared-statement metadata so stale
  statement IDs do not survive after the native layer invalidates them.
- **Async multi-result fallback:** `streamQueryMulti` now degrades gracefully to
  `executeQueryMultiFull` when the async worker cannot start a streaming
  multi-result session, matching the sync/native fallback behavior on older
  binaries.
- **Native library loading during development:** the native asset hook now
  prefers local workspace builds before the version cache, reducing the chance
  of running tests against stale native binaries.

### Changed

- **Runtime performance and internals:** execution and batch hot paths now use
  dynamic ODBC parameter binding collections, reuse shared column-description
  helpers, and reduce repeated plugin-lock work during row-shape discovery.
- **Public docs/comments:** Dart and Rust API comments were updated to remove
  the obsolete "up to 5 parameters" wording and to document repeated named
  placeholder support.
- **README / API docs:** `README.md` and `doc/API_SURFACE.md` now describe
  dynamic parameter counts, repeated named placeholder behavior, and the current
  async XA limitation more explicitly.

## [3.5.4] - 2026-04-24

### Added

- **Dart API surface:** public exports now include driver capabilities,
  driver feature helpers, and pool option types from `package:odbc_fast/odbc_fast.dart`.
- **High-level native controls:** repository/service layers now expose advanced
  pool creation with `PoolOptions`, `poolSetSize`, live `DbmsInfo`
  introspection, `setLogLevel`, and `clearAllStatements`.

### Fixed

- **Rust FFI safety:** telemetry, columnar decompression, async requests,
  streaming, pool, transaction, and query entry points are hardened so panics do
  not cross FFI boundaries and disconnected resources are cleaned up more
  consistently.
- **Protocol robustness:** row, multi-result, parameter, columnar, and
  decompression paths now reject malformed or oversized payloads with explicit
  errors instead of relying on truncating casts or unbounded decode paths.
- **ODBC execution correctness:** batch execution reuses prepared statements for
  parameterized batches, preserves SQL Server `FOR JSON` row shapes, and avoids
  silent re-execution after pending result expiry.
- **XA state handling:** runtime `unwrap()` paths in XA state transitions were
  replaced with error propagation.
- **E2E Docker stack:** the test-runner image now supports IBM Db2 CLI packages
  that ship `libdb2.so.1` without `libdb2o.so.1` by creating a compatibility
  alias during image build.

### Changed

- **Performance:** streaming, row encoding, columnar conversion, compression,
  metrics, async runtime usage, and parallel bulk insert hot paths reduce
  avoidable allocation, copying, and lock contention.
- **Tests:** added focused Rust regression coverage for FFI/protocol safety and
  Dart tests covering the newly public API exports and service/repository
  delegation paths.

## [3.5.3] - 2026-04-24

### Fixed

- **Rust doctests:** `native/odbc_engine/src/ffi/guard.rs` no longer uses
  `ignore` Rust code fences for illustrative FFI snippets. Those blocks are now
  `text`, so `cargo test --include-ignored` / `cargo test --doc` do not try to
  compile non–self-contained examples.
- **MSDTC / XA regression smokes:** `xa_dtc_sqlserver_*` tests require
  `ENABLE_MSDTC_XA_TESTS=1` in addition to `ENABLE_E2E_TESTS` and a SQL Server
  DSN. Without it the tests return early (pass) instead of failing on
  `SQL_ATTR_ENLIST_IN_DTC` when a DSN is present but MSDTC enlist is
  unavailable. Helper: `should_run_msdtc_xa_tests()` in
  `native/odbc_engine/tests/helpers/e2e.rs`.

### Changed

- **Docs:** `doc/development/msdtc-recovery.md` documents `ENABLE_MSDTC_XA_TESTS`
  and updates the local PowerShell runbook.

## [3.5.2] - 2026-04-24

### Fixed

- **CI / clippy (Linux):** `output_aware_params` imported `size_of` unconditionally
  while only using it on Windows code paths. The import is now `#[cfg(windows)]`,
  fixing `clippy -D warnings` (`unused import`) on Linux runners.

## [3.5.1] - 2026-04-24

### Fixed

- **CI / Linux build (Rust):** fixed `output_aware_params` text boxing so input
  text uses owned buffers consistently (`TextBox`), resolving `E0308` on Linux
  runners (`expected VarCell<Box<[u8]>, Text>, found VarCell<&[u8], Text>`).
- **CI / rustfmt:** applied formatting normalization in the DRT1 execution path
  and related regression files so `cargo fmt --all -- --check` passes again.

## [3.5.0] - 2026-04-24

### Fixed

- **DRT1 / `OUT1` (Dart):** `BinaryProtocolParser` now compares the trailer
  to the **little-endian u32 of `b"OUT1"`** (same on-wire four bytes as
  `RowBufferEncoder::append_output_footer` in `native/odbc_engine`). The
  previous constant (`0x4F555431`) was the u32 of `b"1TUO"`; native results with
  real `OUT` / `INOUT` values no longer arrive with empty
  `QueryResult.outputParamValues`.
- **DRT1 + multi-result (Rust):** the directed OUT engine path
  (`execute_query_with_bound_params_and_timeout`) no longer silently discards
  extra result sets from `SQLMoreResults`. When the drain is empty (single result
  set — the common case) the wire format is **unchanged** (ODBC magic + `OUT1`).
  When drain has items, the engine emits a **MULT** envelope (same v2 framing as
  `execute_multi_result`) followed by `OUT1`, so stored procedures that also
  perform DML or return multiple `SELECT` result sets now deliver all items to
  the caller.
- **DRT1 + MULT RowCount-first (Rust):** when a DML-first stored procedure
  starts with an `INSERT`/`UPDATE`/`DELETE` (no initial cursor), the engine
  previously discarded the affected-row count (`let _rc = ...`) and emitted a
  spurious empty `ResultSet` as the first MULT item. The row count is now
  captured and emitted as `MultiResultItem::RowCount(n)`, so the on-wire item
  order faithfully mirrors the logical execution order.
- **DRT1 + MULT RowCount-first (Dart):** `OdbcRepositoryImpl._parseMultiDirectedBuffer`
  previously always mapped item[0] to `QueryResult.columns/rows/rowCount`,
  silently discarding it when item[0] was a `RowCount`. Now, when item[0] is a
  `RowCount`, the primary fields remain empty and **all** items (including
  item[0]) are surfaced in `QueryResult.additionalResults`, preserving order and
  preventing data loss.
- **E2E SQL Server directed OUT test:** `test/e2e/mssql_directed_out_multi_rset_test.dart`
  was using `#dummy_e2e_multi` (a connection-scoped temp table created in
  `setUpAll`) inside the stored procedure. Since the procedure executes on a
  different connection the temp table was invisible, causing the test to fail
  with an "invalid object name" error. The procedure now uses a `DECLARE @t
  TABLE` (table variable) which is fully scoped per call and requires no
  external setup.

### Added

- **DRT1 + multi-result (Dart parser):** `MultiResultParser` gains
  `parseMultiWithOutputs` which decodes a MULT v2 envelope + trailing `OUT1` in
  one call. `OdbcRepositoryImpl._parseBufferToQueryResult` now detects the MULT
  magic and routes to the new decoder branch; single-RS callers are unaffected.
- **`QueryResult.additionalResults`:** new optional field (`default []`) exposing
  tail items from a directed multi-result response as `DirectedResultItem` /
  `DirectedRowCountItem` (both extend the sealed `DirectedMultiItem`). Existing
  code that only reads `rows` / `outputParamValues` requires no changes.
- **Regression tests — D1:** `native/odbc_engine/tests/regression/d1_drt1_multi_result_wire.rs`
  (9 pure-protocol Rust unit tests) pins the on-wire contract: drain-empty path
  is byte-for-byte identical to legacy; drain-non-empty ResultSet-first and
  RowCount-first paths start with MULT and have `OUT1` after the multi frame;
  RowCount → ResultSet → RowCount → OUT1 round-trip verified.
- **Regression tests — Dart (parser):** `test/infrastructure/native/protocol/multi_result_parser_multi_out_test.dart`
  (11 tests) covers `parseMultiWithOutputs` including RowCount-first and
  RowCount → ResultSet → RowCount → OUT1 round-trips.
- **Regression tests — Dart (repository):**
  `test/infrastructure/repositories/odbc_repository_directed_rowcount_first_test.dart`
  (3 tests) validates the repository mapping for RowCount-first MULT buffers:
  primary fields empty, all items in `additionalResults`, and ResultSet-first
  backwards-compatibility unchanged.
- **E2E opt-in (SQL Server multi-result + OUT):**
  `test/e2e/mssql_directed_out_multi_rset_test.dart` — set
  `E2E_MSSQL_DIRECTED_OUT_MULTI=1` + `ODBC_TEST_DSN` (SQL Server DSN,
  ODBC Driver 17+) to run a proc that returns two `SELECT` result sets and
  an `INT OUTPUT`; validates `additionalResults` and `outputParamValues`.
- **Test suite stability:** `RUST_TEST_THREADS=1` set in
  `.cargo/config.toml` to keep `ffi::tests` stable without needing to pass
  `-- --test-threads=1` manually. `ENABLE_SLOW_E2E_TESTS=1` now gates
  long-running stress / benchmark tests (`e2e_bulk_transaction_stress_test`,
  pool stress, 50 k-row streaming, BCP 100 k, bulk compare benchmark).
- **`should_run_slow_e2e_tests()` helper** in
  `native/odbc_engine/tests/helpers/e2e.rs`.
- **Documentation (pendências / maturação):** [TYPE_MAPPING](doc/notes/TYPE_MAPPING.md)
  — tabela de certificação Oracle *ref cursor* (preencimento manual), texto
  alinhado ao *path* *omit-`?`* + `SQLMoreResults`; [columnar_protocol_sketch](doc/notes/columnar_protocol_sketch.md)
  — secção *Criterion benches* (`columnar_v1_v2_encode`, `columnar_v2_placeholder`);
  [PENDING](doc/Features/PENDING_IMPLEMENTATIONS.md) / [ROADMAP_PENDENTES](doc/notes/ROADMAP_PENDENTES.md)
  — *CI* MSDTC *live* como *ad hoc*, *checklist* *release* OCI XA, *scope* TVP /
  `SqlDataType`; [REF_CURSOR_ORACLE_ROADMAP](doc/notes/REF_CURSOR_ORACLE_ROADMAP.md)
  — *edge* *backlog*. **Columnar decode DX:** mensagens `FormatException` mais
  explícitas quando `odbc_columnar_decompress` falha (*build* `odbc_engine`,
  algoritmos, `library_loader`).
- **Oracle DRT1 + `RefCursorOut` (motor):** *strip* de `?` e `ParamValue` filtrada
  (`ref_cursor_oracle`); *prepare* + *execute* + `SQLMoreResults` → `RowBuffer` v1
  por *cursor* + `RowBufferEncoder::append_ref_cursor_footer` após `OUT1` (lógica
  *Oracle Database ODBC* — *omissão* de *ref cursor* no call). Erro
  `DIRECTED_PARAM|ref_cursor_out_oracle_only:…` fora do plugin Oracle. Teste
  *integration* *opt-in* *ignored* `e2e_oracle_ref_cursor_test` (`E2E_ORACLE_REFCURSOR=1`).
- **Roadmap / Oracle REF CURSOR (documentation):** [`doc/notes/ROADMAP_PENDENTES.md`](doc/notes/ROADMAP_PENDENTES.md) orders open *epics*; [`doc/notes/REF_CURSOR_ORACLE_ROADMAP.md`](doc/notes/REF_CURSOR_ORACLE_ROADMAP.md) is the *spike* and integration plan for `SYS_REFCURSOR` *bind*+fetch+`RC1` (motor ainda a devolver `ref_cursor_out_bind_not_enabled`); PENDING, TYPE_MAPPING §3.1.1, and `msdtc-recovery` link from the new index. Comment in `output_aware_params.rs` points to the roadmap.
- **MSDTC DX (Windows / `xa-dtc`):** *Local runbook* in
  `doc/development/msdtc-recovery.md` (env, `regression_test` + `--ignored`,
  `ENABLE_E2E_TESTS`); PENDING §1.1 and `docker-test-stack` link to it; code
  comments in `xa_dtc.rs` / `xa_dtc_test.rs` aligned. Optional workflow
  [`.github/workflows/windows_xa_dtc_build.yml`](.github/workflows/windows_xa_dtc_build.yml)
  also runs `cargo test --lib` and compiles (`--no-run`) integration tests
  (no live MSDTC).
- **MSDTC E2E (segundo *smoke*):** `regression_test` ganha
  `xa_dtc_sqlserver_prepare_commit_smoke` (*prepare* → `commit`); o existente
  mantém *rollback*. *Runbook* e PENDING alinhados; `Xid` distinto.
- **Directed / OUTPUT observability:** `output_aware_params` `ValidationError`
  strings for unsupported DRT1 shapes now use the stable `DIRECTED_PARAM|…`
  prefix and slugs (e.g. `binary_out_inout_not_implemented`);
  `doc/notes/TYPE_MAPPING.md` §3.1 documents the table by engine and §3.1.1
  the REF CURSOR *design* only.
- **Columnar A/B *bench*:** Criterion
  [columnar_v1_v2_encode](native/odbc_engine/benches/columnar_v1_v2_encode.rs)
  compares v1 `RowBufferEncoder` vs v2 `ColumnarEncoder` (nocompress + zstd).
- **Columnar decode DX:** `isColumnarNativeDecompressAvailable` and richer
  `FormatException` when decompression returns null.
- **MSDTC *scope*:** [msdtc-recovery.md](doc/development/msdtc-recovery.md) states
  explicitly that *Reenlist* is not implemented in-crate; PENDING 1.1/§2
  updated accordingly.
- **Columnar v2 *golden* (zstd):** committed
  `test/fixtures/columnar_v2_int32_zstd.golden` (Rust `ColumnarEncoder` with
  per-column *zstd*); sync test
  [columnar_v2_zstd_golden_file.rs](native/odbc_engine/tests/columnar_v2_zstd_golden_file.rs);
  Dart `columnar_v2_zstd_golden_test.dart` parses the file when
  `odbc_columnar_decompress` is loadable.
- **Directed params (Dart *slug* match):** `validateDirectedOutInOut` runs on
  `serializeDirectedParams` with the same `DIRECTED_PARAM|…` *slugs* as
  `output_aware_params` (fast fail before FFI).
- **Ref cursor *wire* (v1, Oracle prep):** `ParamValue` tag `6`
  (`ParamValue::RefCursorOut` / `ParamValueRefCursorOut` on Dart); `RC1\0`
  *trailer* (materialized v1 *blobs*) + `QueryResult.refCursorResults`
  decoded on the client; `RowBufferEncoder::append_ref_cursor_footer` on the
  native *encoder*. O *happy path* Oracle usa o *plugin* + *strip* de `?`
  + `SQLMoreResults`; uma chamada defensiva a `bound_to_slots` com
  `RefCursorOut` fora desse *path* continua a devolver
  `ref_cursor_out_bind_not_enabled`.
- **MSDTC *ops* doc:** *Application-facing* enlist/unenlist guidance in
  [msdtc-recovery.md](doc/development/msdtc-recovery.md) (log full message, do
  not reuse a failed enlisted handle without recycling).
- **E2E PostgreSQL directed `OUT`:** `test/e2e/postgres_directed_out_test.dart`
  — `CREATE PROCEDURE` with two `OUT` (integer + text), `CALL` over DRT1;
  *opt-in* with `E2E_PG_DIRECTED_OUT=1` and `ODBC_TEST_DSN` (host with Dart + PG
  ODBC; not run by `scripts/docker_e2e`). Notes in
  [docker-test-stack.md](doc/development/docker-test-stack.md).
- **E2E SQL Server directed `OUT` (DRT1):** [test/e2e/mssql_directed_out_test.dart](test/e2e/mssql_directed_out_test.dart) —
  *opt-in* with `E2E_MSSQL_DIRECTED_OUT=1`, `ODBC_TEST_DSN` to a SQL Server DSN, and
  a database login that may `CREATE`/`DROP` the proc in `dbo` (see
  [docker-test-stack](doc/development/docker-test-stack.md) §*Optional* / SQL Server
  *directed* `OUT`).

### Changed

- **odbc_engine (DRT1 + `OUT`):** the directed path uses
  *preallocate* + `SQLExecDirect` (same *shape* as `odbc_api::Connection::execute`),
  then `ExecutionEngine::drive_more_results` before reading output bind buffers, so
  **SQL Server** and similar drivers populate `OUTPUT` after `SQLMoreResults`
  (aligned with the multi-result and Oracle ref-cursor paths).

- **`SqlDataType` (30-kind roadmap):** `geometry` (SQL Server planar WKT, same
  wire as `geography`); `intervalYearToMonth` (`String`, `[years, months]`, or
  `Map` with `0..11` month field → `INTERVAL 'y-m' YEAR TO MONTH`); the third
  slot is `json` with `validate: true` (kind `json_validated`, already
  present).
- **Output / INOUT (MVP):** DRT1 request buffer (`serializeDirectedParams`,
  Rust `bound_param`); `IOdbcRepository.executeQueryParamBuffer` and
  `IOdbcService.executeQueryDirectedParams`; `OUT1` result footer; Rust engine
  output-aware binding (integer and **string** / `Decimal` `OUT` / `INOUT`
  with wide or narrow `Var*Char`); and `QueryResult.outputParamValues`. The
  legacy `paramValuesFromDirected` list remains **in-only** (throws for
  non-input). `BinaryProtocolParser.parseWithOutputs` / `QueryResult` docs in
  `doc/notes/TYPE_MAPPING.md` §3.1; `example/output_param_directions_demo.dart`
  shows DRT1 + a live directed query when `ODBC_TEST_DSN` is set.
- **Columnar v2 (Dart + native):** `BinaryProtocolParser` decodes v2; when
  a column is compressed, it calls the native FFI
  `odbc_columnar_decompress` / `odbc_columnar_decompress_free` (same
  `CompressionType` as `odbc_engine`: 1 = zstd, 2 = lz4). Uncompressed
  column blocks are unchanged. Optional Cargo `columnar-v2` *anchors* remain.
  `columnar_v2_flags.dart` and `doc/notes/columnar_protocol_sketch.md` updated
  to match.
- **MSDTC hardening (docs/CI):** `doc/development/msdtc-recovery.md` (Reenlist
  / scenarios), optional `windows_xa_dtc_build.yml` (`workflow_dispatch` for
  `xa-dtc` on Windows), and PENDING/TYPE_MAPPING follow-ups.
- **Docker test-runner:** IBM Db2 ODBC/CLI from IBM’s public DHE tarball
  (`IBM_ODBC_CLI_VERSION` in `Dockerfile.test-runner`); `IBM DB2 ODBC DRIVER`
  in `/etc/odbcinst.ini`.
- **CI (`e2e_docker_stack.yml`):** `db2` matrix (`test_multi_db_*` on `TESTDB`);
  `scripts/docker_e2e.*` support `-Engine db2` with a longer `docker_db_up`
  wait.

### Changed

- **Backlog documentation:** `doc/Features/PENDING_IMPLEMENTATIONS.md`,
  `doc/Features/PENDING_IMPLEMENTATIONS.md`, `doc/notes/TYPE_MAPPING.md`, the
  columnar sketch, `doc/CAPABILITIES_v3.md`, and `README.md` (MSDTC row)
  updated to match shipped scope.

### Fixed

- **`odbc_engine` (unit test, `--features xa-dtc`):** `prepared_xa_commit_rejects_wrong_state`
  now initialises `PreparedXa::dtc_branch` on Windows so the suite compiles.

## [3.4.3] - 2026-04-19

### Fixed

- **pub.dev publish:** removed top-level `docs/` (Pub expects singular `doc/`);
  moved `docs/Features/*` to `doc/Features/`. Updated backlog cross-links.
- **`.github/workflows/publish.yml`:** `dart pub publish` / `--dry-run` now
  pass `--ignore-warnings` so the client-side hint about skipping versions
  after the last published **1.2.1** does not fail CI (server still enforces
  its own rules).

## [3.4.2] - 2026-04-19

Dart XA helpers (`runWithStart` / `runWithStartOnePhase`), Docker E2E
hardening for multi-engine matrices, and optional `docker_e2e` `-Quick` /
`--quick` for faster local runs.

### Added

- **`scripts/docker_e2e.ps1 -Quick`** / **`scripts/docker_e2e.sh --quick`** —
  runs `cargo test` without `--include-ignored` so long `#[ignore]` cases
  (e.g. bulk transaction stress) stay skipped; default behaviour remains
  full CI parity with `--include-ignored`.
- **`XaTransactionHandle.runWithStart<T>`** — exception-safe
  helper that drives the full Two-Phase Commit lifecycle around a
  user-supplied closure. Mirrors the
  `TransactionHandle.runWithBegin` convention shipped for local
  transactions in v3.1.0:
  - On normal completion: emits `xa_end` → `xa_prepare` →
    `xa_commit_prepared`. Each step's failure is surfaced as a
    `StateError` with a diagnostic message so the caller can
    distinguish "commit failed" from "user closure failed".
  - On any thrown exception (or runtime error): inspects the
    branch state, emits `xa_end` if still `Active` (the engine
    refuses `xa_rollback` on an attached branch), then
    `xa_rollback_prepared` (Prepared) or `xa_rollback`
    (Idle/Failed) depending on where the throw landed in the
    lifecycle. The original cause is rethrown so `try / catch`
    composes naturally.
  - Engine-aware: tolerates Oracle's `XA_RDONLY=3` on
    read-only branches (the underlying Rust `apply_xa_prepare`
    already accepts it as success), so the helper completes
    normally even when the user's closure ran no DML.
- **`XaTransactionHandle.runWithStartOnePhase<T>`** — 1RM
  optimisation variant: collapses `xa_prepare` + `xa_commit` into
  `xa_commit_one_phase` for the case where this RM is the sole
  participant in the global transaction. Same exception-safety
  contract as `runWithStart`.
- **11 new Dart unit tests** in
  `test/infrastructure/native/wrappers/xa_transaction_handle_test.dart`
  cover the full state-machine matrix without touching FFI: a
  counter-based `_FakeXa` subclass overrides every state-mutating
  method so the helpers are exercised in isolation.
  - happy path of both helpers (counter assertions)
  - throw-while-Active → end + rollback path
  - throw-while-Prepared → rollback_prepared path
  - `startFn` returning `null` → `StateError` with hint
  - per-step failure (`end`, `prepare`, `commit_prepared`,
    `commit_one_phase`) → `StateError` with the failing-step name
    surfaced

### Changed

- **`example/xa_2pc_demo.dart`** gains a fifth section showing
  the helper end-to-end: commits one branch via the helper, then
  triggers an in-closure throw to demonstrate the rollback path
  catching at the surrounding `try / on Exception`. Existing four
  sections (full 2PC, 1RM, crash-recovery, DML-inside-branch)
  remain untouched.
- **`example/README.md`** entry for the demo updated to mention
  the v3.4.2 helper section.

### Migration notes

- Pure Dart-side addition — no FFI / Rust / ABI changes; the
  helpers compose existing methods (`xaStart`, `end`, `prepare`,
  `commitPrepared`, etc.) so the underlying engine surface is
  unchanged.
- Existing manual 2PC code keeps working unmodified; the helpers
  are an opt-in convenience.

### Fixed

- **Docker multi-engine E2E:** FFI tests that use T-SQL only (`WAITFOR`,
  `INSERT … OUTPUT`, `IF OBJECT_ID`) now skip unless `ODBC_TEST_DSN`
  targets SQL Server. `cell_reader_test` likewise runs only when the
  resolved E2E engine is SQL Server, so `scripts/docker_e2e.ps1` with
  PostgreSQL / MySQL / MariaDB / Oracle no longer fails on SQL
  Server–specific SQL.
- **E2E on non–SQL Server:** `test_catalog_list_columns` (dbo / `IF OBJECT_ID`),
  `test_driver_capabilities_detect` (pinned ODBC defaults), and
  `test_execution_engine_plugin_optimization` (`SELECT TOP`) skip unless
  the live DSN is SQL Server.
- **`e2e_savepoint_test`:** for `SavepointDialect::Sql92`, run
  `DROP TABLE IF EXISTS` before `CREATE` so PostgreSQL / MySQL runs do
  not fail when `sp_test` / `sp_rel_test` already exist from a prior run.

## [3.4.1] - Oracle XA / 2PC via DBMS_XA (Sprint 4.3c Phase 2)

### Added

- **Sprint 4.3c Phase 2 — Oracle XA via `DBMS_XA` PL/SQL package.**
  Production wiring for X/Open XA on Oracle 10g+ closes the last
  remaining engine in the cross-vendor `apply_xa_*` matrix from
  `engine::xa_transaction`. The path goes through ordinary callable
  SQL (`SYS.DBMS_XA.XA_START / XA_END / XA_PREPARE / XA_COMMIT /
  XA_ROLLBACK`) so it works through any Oracle ODBC driver without
  needing access to the underlying `OCIServer*` handle (which
  `odbc-api` does not expose).
  - `Xid::encode_oracle_components()` / `decode_oracle_components()`
    convert between the cross-vendor `Xid` and the
    `(formatid, RAW(64), RAW(64))` triple that `SYS.DBMS_XA_XID`
    expects. Hex is upper-case to round-trip with Oracle's
    `RAWTOHEX` output in `DBA_PENDING_TRANSACTIONS`; decode is
    case-insensitive so future driver changes don't break recovery.
  - `oracle_xa_block(call, allow_rcs)` PL/SQL helper wraps each
    `DBMS_XA.*` call in an exception-translating `BEGIN ... END;`
    that converts non-zero return codes into `ORA-20100`. Tolerates
    `XA_RDONLY` (rc=3) on `XA_PREPARE` (Oracle auto-completes
    branches that did no DML) and `XAER_NOTA` (rc=-4) on the
    follow-up `XA_COMMIT(FALSE)` so the read-only path is a no-op
    at the cross-vendor `XaTransaction` layer.
  - `apply_xa_recover` for Oracle reads `DBA_PENDING_TRANSACTIONS`
    via `RAWTOHEX(GLOBALID)` / `RAWTOHEX(BRANCHID)` so prepared
    XIDs round-trip with our `HEXTORAW` literals on `XA_START`.
- **OCI shim retained, status reframed.** `engine::xa_oci` (behind
  `--features xa-oci`) keeps the dynamic-loading scaffolding +
  `OciXaBranch` / `recover_oci_xids` API as documented OCI ABI
  bindings and a possible future option, but is no longer a "Phase
  2 wiring TODO" — the `DBMS_XA` path is the production
  integration. See module doc-header for the rationale.
- **Public re-export** of `engine::SharedHandleManager` so tests
  / downstreams that hold an `XaTransaction::start` arg across
  calls don't have to reach into the private `crate::handles`
  module.
- **4 new E2E tests** in `tests/e2e_xa_transaction_test.rs` validate
  the Oracle path against Oracle XE 21 in the docker
  `test-runner-oracle` profile:
  - `test_e2e_xa_oracle_full_2pc_commit_path` — full lifecycle
    (start → INSERT → end → prepare → recover lists xid → commit →
    recover empty → row visible).
  - `test_e2e_xa_oracle_rollback_prepared_path` — rollback after
    prepare; verifies `DBA_PENDING_TRANSACTIONS` clears and the
    INSERT was discarded.
  - `test_e2e_xa_oracle_one_phase_commit_shortcut` — `TMONEPHASE`
    fast path without `XA_PREPARE`.
  - `test_e2e_xa_oracle_resume_prepared_after_disconnect` — XID
    survives session loss; second connection recovers + commits via
    `resume_prepared`.
- **5 new unit tests** in `engine::xa_transaction::tests`:
  Oracle component round-trip (upper-case hex), case-insensitive
  decode, `oracle_xid_literal` shape pinned, `oracle_xa_block`
  rc-guard structure pinned. Total xa_transaction unit tests: 22 → 27.

### Changed

- **Engine matrix in `engine::xa_transaction` doc-header**
  reclassifies Oracle from "stub — `UnsupportedFeature` with TODO"
  to "implemented (10g+) via `DBMS_XA`". `unsupported_oracle()`
  helper removed; `unsupported_other()` lists Oracle as supported.
- **`hex_decode` / `hex_nibble`** now accept upper-case A–F so the
  same helper handles MySQL's lower-case hex and Oracle's
  upper-case `RAWTOHEX` output. `hex_encode_upper` added for the
  Oracle emit path.
- **`engine::xa_oci` doc-header** rewritten to reflect the new
  status: dynamic-loading shim retained as documented OCI ABI;
  production Oracle XA flows through `DBMS_XA`; OCI wiring
  deferred until/unless `odbc-api` exposes the underlying handle.

### Required Oracle privileges

The connection user needs `EXECUTE` on `SYS.DBMS_XA` (default for
`SYSTEM`), `FORCE [ANY] TRANSACTION` (for crash-recovery on
prepared XIDs from other sessions), and `SELECT` on
`DBA_PENDING_TRANSACTIONS`. The Oracle XE 21 image used in CI ships
with these enabled out of the box for `SYSTEM`.

### Migration notes

- Existing builds calling Oracle through `XaTransaction::start` /
  `recover_prepared_xids` no longer get `UnsupportedFeature` —
  they execute against `DBMS_XA`. No source changes required; the
  failure surface narrows.
- `--features xa-oci` no longer changes the runtime behaviour of
  Oracle XA (it kept the OCI shim built but the shim was never
  wired). The feature flag still compiles cleanly and is kept for
  future opt-in OCI integration.

## [3.4.0] - Transaction control Sprint 4

### Added

- **Sprint 4.3b / 4.3c — XA / 2PC scaffolding for SQL Server (MSDTC)
  and Oracle (OCI), Phase 1 of 2.** Two new opt-in Cargo features
  add the COM / OCI plumbing that the cross-vendor `apply_xa_*`
  matrix in [`engine::xa_transaction`] needs to integrate SQL Server
  and Oracle into the existing 2PC lifecycle.
  - **Honest status disclaimer**: Phase 1 lands the dependency
    bindings, the COM ceremony / dynamic-loading shim, and a
    self-contained handle type with state-machine guards. **Live
    runtime behaviour against MSDTC and Oracle has not been
    validated end-to-end** — the dev box that produced this commit
    did not have either dependency installed. Phase 2 wires the new
    handles into `apply_xa_*` and adds gated E2E tests against real
    MSDTC + Oracle hosts. Both phases are tracked under
    `PENDING_IMPLEMENTATIONS.md` §1.1 / §1.2.
  - **Sprint 4.3b — `engine::xa_dtc`** (Windows-only, behind
    `--features xa-dtc`):
    - Pulls the `windows` 0.59 crate (high-level COM bindings —
      `windows-sys` doesn't generate COM interface code).
    - `ensure_com_initialised()` — caches the per-thread
      `CoInitializeEx(COINIT_MULTITHREADED)` result so the cost is
      paid once.
    - `acquire_transaction_dispenser()` — calls the documented
      `DtcGetTransactionManagerExA` entry point, builds a typed
      `ITransactionDispenser` wrapper from the raw `*mut c_void` via
      `Interface::from_raw`.
    - `begin_msdtc_transaction()` — `ITransactionDispenser::BeginTransaction`
      with `ISOLATIONLEVEL_READCOMMITTED` (SQL Server's MSDTC default).
    - `DtcXaBranch` owned handle with `commit()` / `abort()` calling
      `ITransaction::Commit` / `ITransaction::Abort`. `Drop` aborts a
      still-active branch best-effort, recognising
      `XACT_E_NOTRANSACTION` (`0x8004D00B`) as "already
      finalised — silent success".
    - The `apply_xa_*` matrix now has a feature-aware
      `unsupported_sqlserver()` that distinguishes "feature missing"
      from "feature enabled, Phase 2 wiring pending" so callers can
      tell the difference.
  - **Sprint 4.3c — `engine::xa_oci`** (cross-platform, behind
    `--features xa-oci`):
    - Pulls `libloading 0.8` for runtime resolution of the OCI
      shared library (`libclntsh.so` / `libclntsh.dylib` / `oci.dll`).
      Fallback search list per platform; first-match wins.
    - `OciXid` `repr(C)` struct mirrors the X/Open `xid_t` layout
      from `oraxa.h` (`format_id` + `gtrid_length` + `bqual_length`
      + 128-byte concatenated payload). Pinned by a layout-asserting
      unit test.
    - Symbol-table struct `OciXaSymbols` resolves the eight XA
      entry points (`xaosw`, `xaocl`, `xaostart`, `xaoend`,
      `xaoprep`, `xaocommit`, `xaoroll`, `xaorecover`) via
      `Library::get`. Cached in a `OnceLock` so subsequent calls are
      O(1).
    - `OciXaBranch` owned handle: `prepare()` (`xa_end(TMSUCCESS)`
      + `xa_prepare`), `commit()` / `rollback()` (Phase 2),
      `commit_one_phase()` (`xa_end` + `xa_commit(TMONEPHASE)`).
      `Drop` rolls back + closes a still-active branch best-effort.
    - `recover_oci_xids()` — Phase-2-recovery scan via `xa_recover`,
      filters out malformed XIDs from foreign clients (length
      violations).
    - The `apply_xa_*` matrix now has a feature-aware
      `unsupported_oracle()` mirroring the SQL Server pattern.
  - **Tests**: 7 new Rust unit tests across the two modules:
    `OciXid` layout pinning + packing edge cases (empty bqual,
    max-size 64+64, gtrid-then-bqual ordering), XA flag constants
    matching `oraxa.h`, the load-error path returning
    `UnsupportedFeature` with actionable wording, and the always-on
    `DtcXaBranch` reachability probe. Live MSDTC / Oracle behaviour
    is covered by the (unwritten) Phase 2 integration tests.
  - **Build matrix**: default build is byte-identical to today.
    `--features xa-dtc` adds `windows` 0.59 (Windows targets only).
    `--features xa-oci` adds `libloading` 0.8 (every target).
    Both can be enabled simultaneously.
- **Sprint 4.3 — XA / 2PC distributed transactions.** First-class
  X/Open XA support with full Phase 1 / Phase 2 lifecycle and
  recovery, exposed end-to-end (Rust core → FFI → Dart bindings →
  high-level `XaTransactionHandle`). Closes the Sprint 4 backlog.
  - **Rust core** — new module `engine::xa_transaction`:
    - [`Xid`] value type (X/Open `format_id` + `gtrid` 1..64 bytes +
      `bqual` 0..64 bytes), with validating constructors and
      engine-specific encoders (`encode_postgres`,
      `encode_mysql_components`).
    - [`XaTransaction`] state machine: `Active` → `Idle` (via
      `xa_end`) → `Prepared` (via `xa_prepare`) → `Committed` /
      `RolledBack` (via `xa_commit_prepared` / `xa_rollback_prepared`).
    - [`PreparingXa`] / [`PreparedXa`] handles enforce the per-state
      contract at compile time — there is no way to call
      `commit_prepared` on an `Active` branch.
    - [`commit_one_phase`](XaTransaction::commit_one_phase) — 1RM
      shortcut that fuses prepare + commit when this RM is the sole
      participant.
    - [`recover_prepared_xids`] / [`resume_prepared`] — crash-recovery
      flow that rebuilds a `PreparedXa` handle from the engine's
      prepared-transaction catalog.
    - `Drop` impl auto-rolls back any `Active` / `Idle` branch that
      escapes scope without explicit commit/rollback.
  - **Engine matrix** (`apply_xa_*`):

    | Engine                | Mechanism                                       | Status |
    | --------------------- | ----------------------------------------------- | ------ |
    | PostgreSQL            | `BEGIN` + `PREPARE TRANSACTION` + `pg_prepared_xacts` | ✅ |
    | MySQL / MariaDB       | `XA START / END / PREPARE / COMMIT / ROLLBACK` + `XA RECOVER` | ✅ |
    | DB2                   | same SQL grammar as MySQL                       | ✅ |
    | SQL Server            | requires MSDTC enlistment via Windows COM (`SQL_ATTR_ENLIST_IN_DTC` + `ITransaction*`) — stub returns `UnsupportedFeature` with a TODO pointing at a follow-up sprint | ⚠️ |
    | Oracle                | requires OCI XA library (`oraxa.h`, `xaoSvcCtx`) — stub returns `UnsupportedFeature` with a TODO | ⚠️ |
    | SQLite / Snowflake / others | no 2PC support — rejected with `UnsupportedFeature` | ❌ |

  - **XID encoding** is hex-based on every engine to keep the SQL
    ASCII-clean regardless of the byte content (X/Open allows
    arbitrary binary). PostgreSQL canonicalises as
    `'<format_id>_<gtrid_hex>_<bqual_hex>'`; MySQL/MariaDB/DB2 use
    the native 3-argument grammar with hex-encoded components.
  - **FFI** — 10 new exports under the `odbc_xa_*` family:
    `odbc_xa_start`, `_end`, `_prepare`, `_commit_prepared`,
    `_rollback_prepared`, `_commit_one_phase`, `_rollback_active`,
    `_recover_count`, `_recover_get`, `_resume_prepared`. The
    recovery flow uses a thread-local cache (`XA_RECOVER_CACHE`) to
    sidestep variable-length-output marshaling at the FFI boundary.
  - **Dart**:
    - [`Xid`] value class in `lib/domain/entities/xid.dart` with the
      same validation rules as Rust.
    - [`XaTransactionHandle`] in
      `lib/infrastructure/native/wrappers/xa_transaction_handle.dart`
      mirrors the Rust state machine.
    - `OdbcBindings.odbc_xa_*` (10 wrappers + `supportsXa` getter
      with graceful fallback throwing `UnsupportedError` on
      pre-Sprint-4.3 binaries).
    - `OdbcNative.xa*` ergonomic wrappers including `xaRecoverGet`
      that handles the FFI memory ceremony.
    - `NativeOdbcConnection.xaStart` / `xaRecover` /
      `xaResumePrepared` return a typed `XaTransactionHandle`.
  - **Verification**: 19 new Rust unit tests in
    `engine::xa_transaction::tests` (XID validation + length limits,
    PostgreSQL encoding round-trip, MySQL component encoding round-
    trip, hex helper edge cases, error-message wording for the
    SQL Server / Oracle stubs, prepared-state guard checks).
    17 new Dart unit tests in `test/domain/entities/xid_test.dart`
    (validation, defensive copy, fromStrings convenience,
    equality/hashCode, toString).
    9 new gated E2E tests in
    `tests/e2e_xa_transaction_test.rs` covering the full PostgreSQL
    and MySQL 2PC lifecycle (full commit, prepared rollback, 1RM
    shortcut, resume-after-disconnect with `pg_prepared_xacts` round-
    trip). E2E tests gracefully skip via `IM002` driver-not-found
    when the matching engine isn't installed locally.
- **`SqlDataType` engine-specific kinds.** Seven additional typed kinds
  for engine-native types that don't have a portable cross-vendor
  equivalent. Brings the `SqlDataType` surface from 20/30 → **27/30**
  of the [TYPE_MAPPING.md](../doc/notes/TYPE_MAPPING.md) roadmap.
  Wire-compatible with existing `ParamValue*` primitives (the value
  is the type-discipline at the call site plus per-kind validation).
  - **PostgreSQL `range`** — accepts the standard PG range literal
    (`'[1,10)'`, `'(1,5]'`, `'[2020-01-01,2020-12-31)'`, `'empty'`).
    Concrete subtype (`int4range` / `tsrange` / `daterange`...) is
    resolved by the server from the column definition.
  - **PostgreSQL `cidr`** / `inet` — accepts IPv4 and IPv6 with
    optional `/prefix` mask. Validated structurally (not via a single
    mega-regex) so compressed IPv6 forms (`2001:db8::1`, `::1`) round
    trip correctly while triple-colon typos (`fe80:::1`) are rejected
    early. Mask range (`/0..32` for IPv4, `/0..128` for IPv6) is
    enforced.
  - **PostgreSQL `tsvector`** — accepts the standard tsvector literal
    (`'fat:1A cat:2B sat:3'`). No client-side validation; PostgreSQL's
    `to_tsvector` / cast is the real validator.
  - **SQL Server `hierarchyId`** — accepts the canonical `'/'`-rooted,
    `'/'`-terminated path (`'/'`, `'/1/'`, `'/1/2/3.5/'`) with
    `/`-separated decimal segments, each optionally with a
    `.fraction` (used to insert nodes between siblings without
    renumbering). **Caller wraps in `CAST(? AS hierarchyid)` in the
    SQL** — the type is not directly bindable as a parameter.
  - **SQL Server `geography`** — accepts WKT (`'POINT(-122.349 47.651)'`,
    `'POLYGON((...))'`, `'LINESTRING(...)'`, etc.). **Caller wraps in
    `geography::STGeomFromText(?, 4326)`** in the SQL (replace the
    SRID with whatever's appropriate). For binary WKB use
    [`SqlDataType.varBinary`] with `geography::STGeomFromWKB`.
    The `List<int>` path is rejected with an actionable error
    pointing at varBinary instead.
  - **Oracle `raw`** — accepts `List<int>`. Idiomatic alias for
    [`SqlDataType.varBinary`]; wire-equality pinned by an explicit
    `serialize()` test.
  - **Oracle `bfile`** — accepts a `String` containing a fully-formed
    `BFILENAME(...)` invocation. BFILE is unusual: it's a pointer to
    an external file, not the content. The more common pattern is
    two `varChar` parameters fed into `BFILENAME(?, ?)` in SQL; this
    kind is for the rarer case of binding a complete textual
    snippet.
  - **Tests**: 20 new Dart unit tests covering accepted shapes,
    rejected typos (with structural IPv6 edge cases), wire-equality
    (`raw` vs `varBinary`), and the cross-kind rejection messages
    (`geography` rejecting `List<int>` with a hint at `varBinary`).
- **`SqlDataType` extras (final batch): `tinyInt`, `bit`, `text`, `xml`,
  `interval`.** Five additional typed kinds in
  `lib/infrastructure/native/protocol/param_value.dart`. Together with
  the previous batch this brings the `SqlDataType` surface from
  10/30 → **20/30** of the
  [TYPE_MAPPING.md](../doc/notes/TYPE_MAPPING.md) roadmap. Same
  contract as before: non-breaking, no FFI changes, no wire changes,
  no existing call site has to be touched.
  - **`SqlDataType.tinyInt`** — accepts `int`, validates against
    `[0, 255]` (SQL Server / Sybase ASE / Sybase ASA convention; the
    broadest interoperable contract). Serialises as `ParamValueInt32`.
    For MySQL/MariaDB *signed* `TINYINT` use [`SqlDataType.smallInt`]
    instead — its range comfortably covers the signed-tinyint domain.
  - **`SqlDataType.bit`** — accepts `bool` (mapped to 1/0) **or** `int`
    (must be exactly 0 or 1). Serialises as `ParamValueInt32`.
    Idiomatic for columns whose *type name* is `BIT`; semantically
    distinct from [`SqlDataType.boolAsInt32`] (which rejects `int`).
  - **`SqlDataType.text`** — long-form character data (`TEXT` / `NTEXT`
    / `CLOB`). Accepts `String` only; no length cap. Wire-compatible
    with [`SqlDataType.varChar`] / [`SqlDataType.nVarChar`] — the
    distinction is purely semantic.
  - **`SqlDataType.xml({validate})`** — accepts `String`. Default is
    pass-through (engine validates at execute-time). `validate: true`
    runs a *cheap structural sanity check* (must start with `<` and
    contain a closing `>` after trimming) — catches obvious mistakes
    without paying the cost of a real XML parser.
  - **`SqlDataType.interval`** — accepts `Duration` (formatted as
    `'<n> seconds'`, the broadest portable spelling: PostgreSQL
    `INTERVAL`, MySQL `INTERVAL`, Oracle `NUMTODSINTERVAL(n,
    'SECOND')`, Db2 `<n> SECONDS` all accept it directly) **or**
    `String` (passed through verbatim, for engines whose preferred
    syntax differs — e.g. Oracle `INTERVAL '1' DAY`). Sub-second
    precision is preserved by emitting a 3-digit decimal so values
    round-trip back to the same `Duration`.
  - **Tests**: 22 new Dart unit tests in
    `test/infrastructure/native/protocol/param_value_test.dart`
    covering the full unsigned-tinyint range, the `bit` int/bool
    duality with strict 0/1 enforcement, multi-line/Unicode TEXT
    payloads, the XML validate-flag opt-in, and the `Duration` →
    "seconds" formatter (whole, sub-second, zero, negative,
    pre-formatted String passthrough).
- **`SqlDataType` extras: `smallInt`, `bigInt`, `json`, `uuid`, `money`.**
  Five new typed kinds in `lib/infrastructure/native/protocol/param_value.dart`,
  bringing the total to 15/30 from the
  [`TYPE_MAPPING.md`](../doc/notes/TYPE_MAPPING.md) roadmap. Every
  kind is **non-breaking** — no existing call site changes, no FFI
  changes, no wire-format changes. They run on top of the existing
  `ParamValue*` primitives.
  - **`SqlDataType.smallInt`** — accepts `int`, validates against
    `[-32768, 32767]`, serialises as `ParamValueInt32` (the int16
    distinction lives in the validation; the wire is shared).
  - **`SqlDataType.bigInt`** — idiomatic alias for
    [`SqlDataType.int64`]. Accepts `int`, serialises as
    `ParamValueInt64`. Wire-compatible with `int64` (pinned by an
    explicit equality test).
  - **`SqlDataType.json({validate})`** — accepts `String` (passed
    through verbatim), `Map<String, dynamic>` or `List<dynamic>`
    (encoded via `dart:convert::jsonEncode`). `validate: true`
    round-trips the payload through `jsonDecode` to catch syntactic
    mistakes early. Default `false` to avoid paying parse cost on
    multi-KB payloads in production.
  - **`SqlDataType.uuid`** — accepts the canonical 8-4-4-4-12 form,
    the bare 32-hex form, and either wrapped in `{...}` (for .NET-
    flavoured tooling). Folds to lowercase canonical so the engine
    sees a normalised value regardless of the caller's formatting.
    Rejects malformed input with an actionable error.
  - **`SqlDataType.money`** — fixed monetary scale of 4 fractional
    digits (`SQL Server MONEY` / `PostgreSQL money` / `DECIMAL(15,4)`
    convention). Accepts `num` (formatted with `toStringAsFixed(4)`)
    or `String` (passed through verbatim). `NaN` / `Infinity`
    rejected with the same wording as the implicit `double → decimal`
    path so error messages stay consistent.
  - **Tests**: 24 new Dart unit tests in
    `test/infrastructure/native/protocol/param_value_test.dart`
    covering valid inputs, range validation, format validation,
    canonicalisation, NaN/Infinity rejection, and the `bigint`/`int64`
    wire-compatibility contract.
- **Sprint 4.2 — Per-transaction `LockTimeout`.** Transactions can now
  cap how long a statement waits for a lock without the caller having
  to emit raw `SET` themselves.
  - **Rust core**: new `engine::LockTimeout` typed wrapper (`u32` ms,
    with `0` = engine default). `Transaction::begin_with_lock_timeout`
    is the new full-control entry point;
    `begin_with_access_mode` / `begin_with_dialect` / `begin` keep
    their signatures and forward to it with `LockTimeout::engine_default()`.
    `Transaction::lock_timeout()` getter exposes the resolved value.
    `OdbcConnection::begin_transaction_with_lock_timeout(...)`.
    `Transaction::execute_with_lock_timeout(...)` mirror.
    `Transaction::for_test_with_lock_timeout(...)` test-only constructor.
  - **Engine matrix** (`apply_lock_timeout`):
    SQL Server emits `SET LOCK_TIMEOUT <ms>`;
    PostgreSQL uses `SET LOCAL lock_timeout = '<ms>ms'` (auto-resets
    on commit/rollback);
    MySQL/MariaDB use `SET SESSION innodb_lock_wait_timeout = <s>` with
    sub-second values rounded UP to 1 second so we never silently
    relax the caller's bound;
    DB2 uses `SET CURRENT LOCK TIMEOUT <s>` with the same rounding;
    SQLite uses `PRAGMA busy_timeout = <ms>`;
    Oracle / Snowflake / Sybase / Redshift / BigQuery / unknown silently
    no-op (logged at debug). `LockTimeout::engine_default()` is the
    universal default and emits **no** `SET` so the connection's
    session log stays clean.
  - **FFI**: new export `odbc_transaction_begin_v3(conn_id, isolation,
    savepoint_dialect, access_mode, lock_timeout_ms)`. v2 delegates to
    v3 with `lock_timeout_ms = 0`; v1 still delegates to v2. All three
    ABIs are preserved byte-for-byte.
  - **Dart**: `Duration? lockTimeout` threaded through `OdbcBindings`
    (new `odbc_transaction_begin_v3` + typedef +
    `supportsTransactionLockTimeout` getter), `OdbcNative.transactionBegin`
    (new `lockTimeoutMs` named arg, smart routing v1/v2/v3 to minimise
    binary surface area when the caller is on defaults),
    `NativeOdbcConnection.beginTransaction`,
    `AsyncNativeOdbcConnection.beginTransaction`,
    `BeginTransactionRequest` (new field, default `0`),
    `IOdbcRepository.beginTransaction` (new optional named arg —
    converts `Duration` → ms at the FFI boundary, with sub-ms positive
    durations rounding UP to 1 ms to mirror Rust-side semantics),
    `IOdbcService.beginTransaction`, `OdbcService.runInTransaction`,
    and `TelemetryOdbcServiceDecorator`. Existing call sites keep
    working unchanged because every new parameter defaults to `null`
    (engine default) / wire `0`.
  - **Graceful fallback**: when an older native library predates
    Sprint 4.2, `OdbcBindings.odbc_transaction_begin_v3` silently
    delegates to v2 (or v1 if v2 is also missing) and `lockTimeoutMs`
    is ignored — the transaction uses the engine default.
- **Sprint 4.4 — `IOdbcService.runInTransaction<T>(...)` helper.**
  Captures the `begin → action → commit/rollback` dance behind a
  single Service-layer call so application code never has to manage
  the `txnId` lifecycle by hand.
  - Returns `Failure` on any combination of `beginTransaction`
    failure, `action` returning `Failure`, `action` throwing (which
    is caught and converted to a `QueryError` with the original
    type/message preserved), or `commit` failure.
  - Rollback runs automatically on any non-happy path; rollback
    failure is swallowed so a noisy rollback never overwrites the
    original error the caller is debugging.
  - Threads through every `beginTransaction` knob (isolation,
    savepoint dialect, access mode, lock timeout) with the same
    defaults as `IOdbcService.beginTransaction`.
  - Implementation in `OdbcService` plus a tracing wrapper in
    `TelemetryOdbcServiceDecorator` that emits a single
    `ODBC.runInTransaction` span around the whole unit of work.
- **Sprint 4.1 — `TransactionAccessMode` (`READ ONLY` / `READ WRITE`).**
  Transactions can now opt into the SQL-92 access-mode hint without
  having to emit raw `SET TRANSACTION` themselves.
  - **Rust core**: new `engine::TransactionAccessMode { ReadWrite,
    ReadOnly }`. `Transaction::begin_with_access_mode(handles, conn_id,
    isolation, savepoint_dialect, access_mode)` is the new full-control
    entry point; `begin_with_dialect` and `begin` keep their existing
    signatures and default to `ReadWrite`. `Transaction::access_mode()`
    getter exposes the resolved value. `OdbcConnection` gains
    `begin_transaction_with_access_mode(...)`. The
    `Transaction::execute*` family gains `execute_with_access_mode`.
  - **Engine matrix** (`apply_access_mode`):
    PostgreSQL / MySQL / MariaDB / DB2 / Oracle emit
    `SET TRANSACTION READ ONLY` after isolation. SQL Server / SQLite /
    Snowflake / Sybase / Redshift / BigQuery / unknown silently treat
    `ReadOnly` as a no-op (logged at debug) so callers can program
    against the abstraction unconditionally. `ReadWrite` is the engine
    default everywhere, so we do **not** emit a redundant `SET` for it
    on any engine — the connection's session log stays clean.
  - **FFI**: new export `odbc_transaction_begin_v2(conn_id, isolation,
    savepoint_dialect, access_mode)`. The legacy
    `odbc_transaction_begin` delegates to v2 with `access_mode = 0`
    (ReadWrite) so the v1 ABI is preserved byte-for-byte.
  - **Dart**: new `TransactionAccessMode { readWrite, readOnly }` enum
    in `lib/domain/entities/transaction_access_mode.dart`. Threaded
    through `OdbcBindings` (new `odbc_transaction_begin_v2` + typedef +
    `supportsTransactionAccessMode` getter that reflects whether the
    loaded native library exports v2), `OdbcNative.transactionBegin`,
    `NativeOdbcConnection.beginTransaction`,
    `AsyncNativeOdbcConnection.beginTransaction`,
    `BeginTransactionRequest` (new `accessMode` field, default `0`),
    `IOdbcRepository.beginTransaction` (new optional named arg),
    `IOdbcService.beginTransaction` (new optional named arg),
    `TelemetryOdbcServiceDecorator`. Existing call sites keep working
    unchanged because every new parameter defaults to the
    `ReadWrite` / wire `0` value.
  - **Graceful fallback**: when an older native library predates
    Sprint 4.1, `OdbcBindings.odbc_transaction_begin_v2` silently
    delegates to v1 and the `accessMode` argument is ignored — the
    transaction is always `READ WRITE`. Callers that need the
    distinction gate on `supportsTransactionAccessMode`.

### Fixed

- **`test_ffi_get_structured_error` flaky in parallel runs**
  (see `TYPE_MAPPING` §3.1 and backlog). The previous
  implementation triggered the structured error via
  `trigger_structured_cancel_unsupported_error()`, released the global
  state lock, and only then called the public
  `odbc_get_structured_error` FFI. Any parallel test that touched a
  function calling `set_error()` (which clears
  `state.last_structured_error` as a side-effect) could clobber the
  injected value in that window — surfacing as the recurring
  `assertion 'left == right' failed: Should succeed left:1 right:0`.
  `#[serial]` alone wasn't enough because it only serialises against
  *other* `#[serial]` tests, not the broader set of FFI tests that
  call `set_error` indirectly. The fix collapses inject + read into a
  single critical section by holding the lock across both operations
  and inlining the same algorithm `odbc_get_structured_error` uses.
  Verified by 5 consecutive `cargo test --lib` runs with 0 failures.

### Tests

- **Sprint 4.1**: 8 new lib unit tests under
  `engine::transaction::tests::*` (`TransactionAccessMode` from-`u32`
  mapping, SQL keyword formatting, `is_read_only` predicate, default
  value attached to the `Transaction` struct,
  `for_test_with_access_mode` constructor).
  `tests/e2e_transaction_access_mode_test.rs` — 4 new E2E tests gated
  by `should_run_e2e_tests()`, verified against a live SQL Server
  (default `ReadWrite` preserves v1 behaviour, `ReadOnly` is a silent
  no-op on SQL Server, v1 path defaults to `ReadWrite`,
  Postgres/MySQL/Oracle native-hint placeholder).
- **Sprint 4.2**: 12 new lib unit tests under
  `engine::transaction::tests::lock_timeout_*`
  (`from_millis(0)` collapses to engine-default; sub-ms positive
  durations round up to 1 ms; `from_duration` clamps at `u32::MAX` ms;
  `millis_as_seconds_rounded_up` policy for MySQL/DB2; SQL formatting
  per engine; default attached to `Transaction`;
  `for_test_with_lock_timeout` constructor).
  `tests/e2e_transaction_lock_timeout_test.rs` — 4 new E2E tests
  verified against SQL Server (engine_default is a pure no-op,
  `SET LOCK_TIMEOUT 2500` is accepted, sub-ms round-up survives the
  driver, the Sprint 4.1 entry point still defaults to engine-default).
- **Sprint 4.4**: 9 new Dart unit tests in
  `test/application/services/odbc_service_run_in_transaction_test.dart`
  covering the full state machine (happy path, action `Failure`,
  action throw, `begin` failure, `commit` failure, rollback failure
  swallowing, parameter threading, defaults, async-await ordering).

### Migration

- 100% backwards compatible across all three sub-features.
  - Every new parameter is optional with a sensible default
    (`ReadWrite` / `engine_default` / `null lockTimeout` / etc.).
  - Wire-level: `odbc_transaction_begin` (v1) still ships and now
    delegates to `_v2` with `access_mode = 0`; `_v2` delegates to
    `_v3` with `lock_timeout_ms = 0`. All three ABIs are preserved.
  - When an older native library is loaded, the higher-level Dart
    layer detects the missing FFI symbols (via the `supports*`
    getters on `OdbcBindings`) and silently falls back to the closest
    older entry point. The new parameters become no-ops in that case
    rather than producing errors.

### Notes

- **GitHub issues #1 and #2 are resolved by v3.3.0** (released as part of
  the streaming multi-result + UTF-16 wide-text decoding work):
  - [#1 — Chinese Character Encoding Issue with SQL Server NVARCHAR Fields](
    https://github.com/cesar-carlos/dart_odbc_fast/issues/1) is closed by
    the switch from `SQLGetData(SQL_C_CHAR)` to
    `SQLGetData(SQL_C_WCHAR)` in `engine/cell_reader.rs` plus the Dart
    `_decodeText` hardening (U+FFFD substitution instead of silent
    Latin-1 fallback). Verified by
    `tests/e2e_sqlserver_test.rs::test_e2e_sqlserver_unicode_chinese_round_trip`
    against a real SQL Server (CJK + emoji + RTL all round-trip).
  - [#2 — JSON Truncation in odbc_fast with SQL Server FOR JSON Queries](
    https://github.com/cesar-carlos/dart_odbc_fast/issues/2) is closed by
    `engine::sqlserver_json::coalesce_for_json_rows`, which detects the
    reserved `JSON_F52E2B61-…` column name SQL Server emits for FOR JSON
    payloads and concatenates the per-row chunks into a single logical
    cell before encoding. Verified by
    `tests/e2e_sqlserver_test.rs::test_e2e_sqlserver_for_json_path_returns_complete_payload`
    (200 rows ≈ 19 KB reassembled across ~10 chunk boundaries).
  Both issues should be closed on GitHub with a reference to v3.3.0.

## [3.3.0] - Streaming multi-result (M8)

### Added

- **M8 — Streaming multi-result.** New end-to-end stack that surfaces every
  multi-result item incrementally instead of materialising the whole batch
  in memory. Closes the only multi-result item that was deferred from
  v3.2.0.
- **Engine** (`native/odbc_engine/src/engine/streaming.rs`):
  - `start_multi_batched_stream(handles, conn_id, sql, chunk_size)` —
    spawns a worker that drives `Statement::more_results` raw + uses
    `cursor.into_stmt()` to consume cursors **without** triggering
    `SQLCloseCursor` (which would discard pending result sets, same trick
    used for the M1 fix in v3.2.0).
  - `start_multi_async_stream(...)` — async variant returning
    `AsyncStreamingState` (poll + fetch).
  - Each worker batch carries one frame-encoded multi-result item:
    `[tag: u8][len: u32 LE][payload]`. `tag = 0` payload is a
    `binary_protocol` row-buffer; `tag = 1` payload is `i64 LE` row count.
  - Constants `MULTI_STREAM_ITEM_TAG_RESULT_SET = 0` and
    `MULTI_STREAM_ITEM_TAG_ROW_COUNT = 1`.
- **FFI** — 2 new exports:
  - `odbc_stream_multi_start_batched(conn_id, sql, chunk_size)`
  - `odbc_stream_multi_start_async(conn_id, sql, chunk_size)`
  - Both return `stream_id` and reuse the existing `odbc_stream_fetch`,
    `odbc_stream_cancel`, `odbc_stream_close` and `odbc_stream_poll_async`
    FFIs, so no other surface has to change.
- **Dart** — `MultiResultStreamDecoder` (lib/infrastructure/native/protocol)
  reassembles partial frames into `MultiResultItem`s as bytes accumulate.
  Bindings: `OdbcBindings.odbc_stream_multi_start_batched / _async`,
  `OdbcNative.streamMultiStartBatched / _Async`,
  `NativeOdbcConnection.streamMultiStartBatched / _Async`,
  `AsyncNativeOdbcConnection.streamMultiStartBatched / _Async` (also
  exposes `streamFetch` / `streamClose` so the high-level API can drive
  the stream lifecycle), worker isolate handlers
  (`StreamMultiStartBatchedRequest`, `StreamMultiStartAsyncRequest`).
- **High-level Dart API** — `IOdbcService.streamQueryMulti(connId, sql)`
  returns `Stream<Result<QueryResultMultiItem>>`. Each item is emitted as
  soon as the Rust worker produces it.
  `OdbcRepositoryImpl.streamQueryMulti` gracefully falls back to
  `executeQueryMultiFull` when the loaded native library predates v3.3.0.
- **`supportsStreamQueryMulti`** getters on `OdbcBindings`, `OdbcNative`
  and `NativeOdbcConnection` so callers can detect the capability without
  catching exceptions.

### Tests

- `tests/regression/m8_streaming_multi_result.rs` — 3 E2E tests (`#[ignore]`,
  gated by `ENABLE_E2E_TESTS=1` + `ODBC_TEST_DSN`) covering the 3 batch
  shapes that M1 already covered for the materialising path. All 3 pass
  against a real SQL Server target.
- `test/infrastructure/native/protocol/multi_result_stream_decoder_test.dart`
  — 8 unit tests for the Dart frame decoder (full chunk, split-across,
  multi-frame chunk, malformed tag/len, exhaustion checks).

### Internal

- `streaming.rs` exposes a small helper (`drive_multi_result_stream`) that
  shares the cursor / row-count traversal logic with
  `ExecutionEngine::collect_multi_results`. Both call paths use the same
  no-`SQLCloseCursor` discipline.
- `MockOdbcRepository` (test helper) now implements `streamQueryMulti`
  via `executeQueryMultiFull` so existing tests keep compiling.

### Migration

- 100% backwards compatible. `executeQueryMulti / executeQueryMultiFull /
  executeQueryMultiParams` continue to work unchanged. Use
  `streamQueryMulti` whenever the batch result sets are large enough that
  3× memory cost is meaningful (e.g. wide analytics joins).
- Loading an older native library only loses the `streamQueryMulti` fast
  path; `OdbcRepositoryImpl` automatically falls back to
  `executeQueryMultiFull` and replays the items as a stream so the API
  contract is preserved.

### Validation

- `cargo test --lib --include-ignored`: 857 passed / 0 failed (was 846).
- `cargo test --test regression_test`: 78 passed / 0 failed / 7 ignored
  (3 new M8 streaming + 4 M1 batch shapes — all 7 pass with
  `ENABLE_E2E_TESTS=1`).
- `cargo clippy --all-targets --all-features -- -D warnings`: 0 warnings.
- `dart analyze lib test example`: No issues found.
- `dart test test/{application,domain,infrastructure,core,helpers}`:
  430 passed / 0 failed / 3 skipped (was 418, +12 from the new decoder
  unit tests + mock helpers).

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

[Unreleased]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v3.10.0...HEAD
[3.10.0]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v3.9.0...v3.10.0
[3.9.0]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v3.8.1...v3.9.0
[3.8.1]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v3.8.0...v3.8.1
[3.8.0]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v3.7.0...v3.8.0
[3.7.0]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v3.6.1...v3.7.0
[3.6.1]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v3.6.0...v3.6.1
[3.6.0]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v3.5.4...v3.6.0
[3.5.4]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v3.5.3...v3.5.4
[3.5.3]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v3.5.2...v3.5.3
[3.5.2]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v3.5.1...v3.5.2
[3.5.1]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v3.5.0...v3.5.1
[3.5.0]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v3.4.3...v3.5.0
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
