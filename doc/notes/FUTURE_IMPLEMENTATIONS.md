# FUTURE_IMPLEMENTATIONS.md - Technical Backlog

Consolidated backlog of items not yet included in implemented scope.

**Last verified against code:** 2026-04-19 (v3.3.0)

> Note: this file is in `doc/notes/` and intentionally documents pending
> implementation work.

## Summary

| Item                                                       | Status                                          | Priority    |
| ---------------------------------------------------------- | ----------------------------------------------- | ----------- |
| ~~Schema reflection (PK/FK/Indexes)~~                      | ✅ **Implemented (2026-03-10)**                 | ~~High~~    |
| ~~Explicit SQL typing API (`SqlDataType`)~~                | ✅ **Implemented (v3.0.0)**                     | ~~Medium~~  |
| ~~SavepointDialect autodetect (B2/B4)~~                    | ✅ **Implemented (v3.1.0)**                     | ~~High~~    |
| ~~FFI savepoint identifier injection (B1)~~                | ✅ **Implemented (v3.1.0)**                     | ~~Critical~~|
| ~~Multi-result hardening (M1, M2, M7)~~                    | ✅ **Implemented (v3.2.0)**                     | ~~High~~    |
| ~~Multi-result sealed class + magic/version (M3, M4)~~     | ✅ **Implemented (v3.2.0)**                     | ~~Medium~~  |
| ~~Multi-result with parameters (M5)~~                      | ✅ **Implemented (v3.2.0)**                     | ~~Medium~~  |
| ~~Streaming multi-result (M8)~~                            | ✅ **Implemented (v3.3.0)**                     | ~~Medium~~  |
| ~~UTF-16 wide-text column decoding~~                       | ✅ **Implemented (v3.3.0)**                     | ~~High~~    |
| ~~Transaction Sprint 4.1 — `READ ONLY`~~                   | ✅ **Implemented (Unreleased)**                 | ~~Medium~~  |
| ~~Transaction Sprint 4.2 — lock_timeout~~                  | ✅ **Implemented (Unreleased)**                 | ~~Medium~~  |
| ~~Transaction Sprint 4.4 — `runInTransaction<T>` helper~~  | ✅ **Implemented (Unreleased)**                 | ~~Low~~     |
| Transaction Sprint 4.3 — XA / 2PC / distributed            | Planned (large scope; needs odbc-api escape hatch) | Medium  |
| ~~`test_ffi_get_structured_error` flakiness~~              | ✅ **Fixed (Unreleased)** — atomic inject+read   | ~~Low~~     |
| `IOdbcService.runInTransaction` helper                     | Planned (not started)                           | Low         |
| Output parameters by driver/plugin                         | Out of current scope                            | Medium      |
| `SqlDataType` extended kinds (smallInt, json, uuid, …)     | Incremental (10/30 kinds shipped in v3.0.0)     | Low         |
| Columnar protocol v2 (sketch)                              | Orphaned — see `doc/notes/columnar_protocol_sketch.md` | Low   |
| `test_ffi_get_structured_error` flakiness on parallel runs | Known issue — passes serially                   | Low         |
| `e2e_pool_test`, `e2e_savepoint_test` hang on slow DSN     | Known infra — gated by `ENABLE_E2E_TESTS=1`     | Low         |

## 0. Transaction control — Sprint 4 (Planned)

The v3.1.0 release closed the four critical bugs (B1, B2, B4, B7) and
shipped the Dart safety helpers (`runWithBegin`, `withSavepoint`,
`Finalizable`). Sprint 4 covers the optional / advanced surface that did
**not** make it into v3.1 because none of it is required for correctness.

### ~~4.1 `SET TRANSACTION READ ONLY`~~ — ✅ IMPLEMENTED (Unreleased)

Sibling enum `TransactionAccessMode { readWrite, readOnly }` exposed
end-to-end (Rust core → FFI v2 → Dart bindings → Service). PostgreSQL /
MySQL / MariaDB / DB2 / Oracle emit `SET TRANSACTION READ ONLY`; SQL
Server / SQLite / Snowflake silently no-op. v1 FFI ABI preserved.
Verified by 8 unit tests + 4 E2E tests (`tests/e2e_transaction_access_mode_test.rs`).
See CHANGELOG `[Unreleased] / Added` for the full surface.

### ~~4.2 Lock / statement timeouts per transaction~~ — ✅ IMPLEMENTED (Unreleased)

`engine::LockTimeout` typed wrapper exposed end-to-end (Rust core →
FFI v3 → Dart `Duration?` → Service). Engine matrix: SQL Server emits
`SET LOCK_TIMEOUT <ms>`; PostgreSQL `SET LOCAL lock_timeout = '<n>ms'`
(auto-resets on commit/rollback); MySQL/MariaDB and DB2 use the
session-wide seconds-granular variants with sub-second values rounding
UP to 1s; SQLite uses `PRAGMA busy_timeout = <ms>`; Oracle/Snowflake
silently no-op. v1/v2 ABIs preserved via v3 delegation. Verified by
12 unit tests + 4 E2E tests
(`tests/e2e_transaction_lock_timeout_test.rs`).

### 4.3 XA / two-phase commit / distributed transactions

- **Why**: cross-resource coordination (TCC, MS-DTC). Out of scope for
  most apps but a recurring request in the fintech space.
- **Sketch**: new `engine::xa` module with `XaTransaction::{prepare,
  commit, rollback}` calling `SQLSetConnectAttr(SQL_ATTR_ENLIST_IN_DTC)`
  via `odbc-api`'s raw escape hatch. Likely a paid-tier feature.

### ~~4.4 `runInTransaction` exposed natively in the Service layer~~ — ✅ IMPLEMENTED (Unreleased)

`IOdbcService.runInTransaction<T>(connId, action, {isolationLevel,
savepointDialect, accessMode, lockTimeout})` ships in
`OdbcService` with a tracing wrapper in
`TelemetryOdbcServiceDecorator`. Honours the
`begin → action → commit/rollback` contract atomically: action throws
become `QueryError` (typed catch in the action's stack), action
`Failure` rolls back and propagates verbatim, `commit` failure surfaces
as the unit-of-work failure, and rollback failures during cleanup are
swallowed so they never overwrite the original cause. Verified by
9 Dart unit tests in
`test/application/services/odbc_service_run_in_transaction_test.dart`.

## 1. Output parameters by driver/plugin

### Current state

- No public API for output parameters.
- Engine/plugin extension points exist, but no stable Dart contract yet.
- Driver roadmap matrix and decision criteria are documented in
  `doc/notes/TYPE_MAPPING.md` (section `Output parameters roadmap`).

### Current decision

- Out of immediate scope.
- Revisit when there is a concrete driver-specific requirement (for
  example: SQL Server OUTPUT, Oracle REF CURSOR).

## 2. `SqlDataType` extended kinds (incremental)

v3.0.0 shipped 10 kinds (`int32`, `int64`, `decimal`, `varChar`,
`nVarChar`, `varBinary`, `dateTime`, `date`, `time`, `boolAsInt32`).
Additional kinds can land incrementally without breaking existing
callers:

- `smallInt`, `bigInt`, `tinyInt`, `bit`
- `text`, `xml`, `json`
- `uuid`, `money`, `interval`

Each extra kind is a non-breaking change; ship as v3.x.0 minor bumps when
there is a concrete consumer asking for it.

## 3. Known test infrastructure issues (low priority)

These are **not** product bugs — they affect test runs against specific
local infrastructures. Documented here so they don't get re-discovered
each release cycle.

### ~~3.1 `test_ffi_get_structured_error` is flaky in parallel~~ — ✅ FIXED (Unreleased)

The previous implementation triggered the structured error via
`trigger_structured_cancel_unsupported_error()`, released the global
state lock, and only then called the public `odbc_get_structured_error`
FFI to read it back. Any parallel test calling a function that invokes
`set_error()` (which clears `state.last_structured_error` as a
side-effect, see `set_error` at `ffi/mod.rs:570`) could clobber the
injected value in that window. `#[serial]` only serialised against
other `#[serial]` tests, not the broader set of FFI tests that touch
`set_error` indirectly.

The fix collapses inject + read into a single critical section by
holding the global state lock across both operations and inlining the
same algorithm `odbc_get_structured_error` uses. Verified by 5
consecutive `cargo test --lib` runs with 0 failures (was an
intermittent failure documented since v3.0).

### 3.2 `e2e_pool_test` / `e2e_savepoint_test` hang on slow DSN

- **Why**: those tests acquire pool connections with the default 30 s
  timeout; when the local SQL Server is slow to respond (login throttling,
  cold start) the test driver waits the full timeout for every individual
  test. Surfaces as the run "hanging" until cargo test eventually times
  out.
- **Workaround**: gate-controlled by `ENABLE_E2E_TESTS=1`; not part of
  the default `cargo test --lib` flow.
- **Fix sketch**: lower the per-test pool `connection_timeout` to 5 s and
  fail fast with a clear error.

## ~~4. Schema reflection (PK/FK/Indexes)~~ — ✅ IMPLEMENTED

**Implemented on**: 2026-03-10.

- ✅ Rust: `list_primary_keys`, `list_foreign_keys`, `list_indexes` in
  `catalog.rs`.
- ✅ FFI: `odbc_catalog_primary_keys`, `odbc_catalog_foreign_keys`,
  `odbc_catalog_indexes`.
- ✅ Dart: full binding → repository → service chain.
- ✅ Example: `example/catalog_reflection_demo.dart`.

## ~~5. Explicit SQL typing API (`SqlDataType`)~~ — ✅ IMPLEMENTED

**Implemented on**: v3.0.0 (`SqlDataType` + `SqlTypedValue` +
`typedParam`).

- ✅ 10 kinds shipped, validation per kind, integrated into
  `toParamValue` / `paramValuesFromObjects` (non-breaking).
- ✅ Reference: `doc/notes/TYPE_MAPPING.md` §1.3.
- See section 2 above for the incremental backlog of additional kinds.

## ~~6. Multi-result hardening (M1, M2, M3, M4, M5, M6, M7)~~ — ✅ IMPLEMENTED (v3.2.0)

| Tag | Description                                             | Status     |
| --- | ------------------------------------------------------- | ---------- |
| M1  | `collect_multi_results` walks all 4 batch shapes        | ✅ v3.2.0 |
| M2  | `odbc_exec_query_multi` accepts pooled IDs              | ✅ v3.2.0 |
| M3  | `MultiResultItem` (Dart) sealed class                   | ✅ v3.2.0 |
| M4  | Wire format magic + version v2 (decoder accepts v1 too) | ✅ v3.2.0 |
| M5  | `executeQueryMultiParams` (FFI + Dart cadeia)           | ✅ v3.2.0 |
| M6  | `executeQueryMulti` single via `firstResultSetOrNull`   | ✅ v3.2.0 |
| M7  | `getFirstResultSet` returns `ParsedRowBuffer?`          | ✅ v3.2.0 |
| M8  | Streaming multi-result (frame-based wire)               | ✅ v3.3.0 |
| M9  | E2E coverage for batch-shape regressions                | ✅ v3.2.0 |

See `CHANGELOG.md` entries for v3.2.0 and v3.3.0 for the full surface.

## ~~7. UTF-16 wide-text column decoding~~ — ✅ IMPLEMENTED (v3.3.0)

`engine/cell_reader.rs` reads text columns through
`SQLGetData(SQL_C_WCHAR)` (UTF-16 LE) and transcodes to UTF-8 via
`String::from_utf16_lossy`. Resolves the `"¹ÜÀíÔ±"` mojibake bug for
non-ASCII text outside the client's ANSI code page (issue #1). 4 new
E2E tests in `tests/e2e_sqlserver_test.rs` (FOR JSON PATH + Chinese
unicode round-trip).

## Criteria to move from open to implemented

1. Public API defined and documented.
2. Unit and integration tests covering main flow.
3. Working example in `example/` (when applicable).
4. Entry in `CHANGELOG.md`.
