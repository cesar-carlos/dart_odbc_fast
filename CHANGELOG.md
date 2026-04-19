# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
    `FUTURE_IMPLEMENTATIONS.md` §4.3b / §4.3c.
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
  (long-standing `FUTURE_IMPLEMENTATIONS.md` §3.1). The previous
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
