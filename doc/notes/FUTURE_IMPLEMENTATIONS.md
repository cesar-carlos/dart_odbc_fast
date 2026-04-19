# FUTURE_IMPLEMENTATIONS.md - Technical Backlog

Consolidated backlog of items not yet included in implemented scope.

**Last verified against code:** 2026-04-18

> Note: this file is in `doc/notes/` and intentionally documents pending
> implementation work.

## Summary

| Item                               | Status               | Priority |
| ---------------------------------- | -------------------- | -------- |
| ~~Schema reflection (PK/FK/Indexes)~~ | ✅ **Implemented (2026-03-10)** | ~~High~~ |
| ~~Explicit SQL typing API (`SqlDataType`)~~ | ✅ **Implemented (v3.0.0)** — see `doc/notes/TYPE_MAPPING.md` §1.3 | ~~Medium~~ |
| ~~SavepointDialect autodetect (B2/B4)~~ | ✅ **Implemented (v3.1.0)**     | ~~High~~ |
| ~~FFI savepoint identifier injection (B1)~~ | ✅ **Implemented (v3.1.0)** | ~~Critical~~ |
| Transaction Sprint 4 — `READ ONLY`, lock_timeout, XA / 2PC | Planned (not started) | Medium |
| Output parameters by driver/plugin | Out of current scope | Medium   |
| Columnar protocol v2 (sketch) | Orphaned design — see `doc/notes/columnar_protocol_sketch.md` | Low |

## 0. Transaction control — Sprint 4 (Planned)

The v3.1.0 release closed the four critical bugs (B1, B2, B4, B7) and shipped
the Dart safety helpers (`runWithBegin`, `withSavepoint`, `Finalizable`).
Sprint 4 covers the optional / advanced surface that did **not** make it into
v3.1 because none of it is required for correctness.

### 4.1 `SET TRANSACTION READ ONLY`

- **Why**: PostgreSQL and MySQL skip locking and use REPEATABLE READ snapshot
  semantics for read-only transactions. Significant perf win for reporting.
- **Sketch**: `IsolationLevel.asReadOnly()` modifier + extra strategy in
  `IsolationStrategy::Sql92` to append ` READ ONLY`. New `bool readOnly` flag
  on `SavepointDialect` -- prefer dropping it on a sibling enum.
- **Engines**: PostgreSQL, MySQL/MariaDB, Db2 (`READ ONLY`), Oracle
  (`READ ONLY` after isolation). SQL Server has no equivalent → no-op.

### 4.2 Lock / statement timeouts per transaction

- **Why**: today the only knob is the per-statement timeout. There is no
  `lock_timeout` (`SET LOCK_TIMEOUT` on SQL Server, `SET lock_timeout` on
  Postgres, `WAIT n` clause on Oracle).
- **Sketch**: `Transaction::with_timeout(Duration)` helper that emits the
  right `SET` for each engine *before* `set_autocommit(false)`.

### 4.3 XA / two-phase commit / distributed transactions

- **Why**: cross-resource coordination (TCC, MS-DTC). Out of scope for most
  apps but a recurring request in the fintech space.
- **Sketch**: new `engine::xa` module with `XaTransaction::{prepare, commit,
  rollback}` calling `SQLSetConnectAttr(SQL_ATTR_ENLIST_IN_DTC)` via
  `odbc-api`'s raw escape hatch. Likely a paid-tier feature.

### 4.4 `with_transaction` exposed natively in the Service layer

- **Why**: today users get the `runWithBegin` helper at the
  `TransactionHandle` level, but the `OdbcService` API still requires manual
  begin/commit/rollback in language-server discoverable surfaces.
- **Sketch**: `IOdbcService.runInTransaction<T>(connId, action,
  {isolation, dialect})` wrapping the same try/commit/rollback discipline.

## ~~1. Schema reflection (PK/FK/Indexes)~~ — ✅ IMPLEMENTED

**Implemented on**: 2026-03-10

### Implementation summary

- ✅ Rust: `list_primary_keys`, `list_foreign_keys`, `list_indexes` in `catalog.rs`
- ✅ FFI: `odbc_catalog_primary_keys`, `odbc_catalog_foreign_keys`, `odbc_catalog_indexes`
- ✅ Dart: Full binding → Repository → Service chain
- ✅ Example: `example/catalog_reflection_demo.dart`

## 1. Output parameters by driver/plugin

### Current state

- No public API for output parameters
- Engine/plugin extension points exist, but no stable Dart contract yet
- Driver roadmap matrix and decision criteria are documented in
  `doc/notes/TYPE_MAPPING.md` (section `Output parameters roadmap (planned)`).

### Current decision

- Out of immediate scope
- Revisit when there is a concrete driver-specific requirement (for example: SQL Server OUTPUT, Oracle REF CURSOR)

## 2. ~~Explicit SQL typing API (`SqlDataType`)~~ — ✅ IMPLEMENTED

**Implemented on**: v3.0.0 (`SqlDataType` + `SqlTypedValue` + `typedParam`).

### Implementation summary

- ✅ `SqlDataType` with 10 kinds: `int32`, `int64`, `decimal(precision, scale)`,
  `varChar(length)`, `nVarChar(length)`, `varBinary(length)`, `dateTime`,
  `date`, `time`, `boolAsInt32`.
- ✅ `SqlTypedValue({required type, required value})` wrapper.
- ✅ `typedParam(type, value)` factory.
- ✅ Integrated into `toParamValue` / `paramValuesFromObjects` so typed
  values mix freely with the existing untyped `List<dynamic>` API
  (non-breaking).
- ✅ Per-kind validation (e.g. `int32` rejects out-of-range, `varChar`
  rejects non-`String`) with actionable `ArgumentError` messages.
- ✅ Reference: `doc/notes/TYPE_MAPPING.md` §1.3.

### Not yet covered

The original sketch listed ~30 SQL types. Only the 10 kinds above are
shipped. Additional kinds (`smallInt`, `bigInt`, `tinyInt`, `bit`, `text`,
`xml`, `json`, `uuid`, `money`, etc.) can be added incrementally without
breaking existing callers.

## Criteria to move from open to implemented

1. Public API defined and documented
2. Unit and integration tests covering main flow
3. Working example in `example/` (when applicable)
4. Entry in `CHANGELOG.md`


