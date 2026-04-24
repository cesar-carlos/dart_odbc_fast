# MSDTC recovery and `Reenlist` (SQL Server / `xa-dtc`)

> **Status (engineering):** *Reenlist* and full transaction-manager recovery
> are **not implemented inside `odbc_engine`**. The crate implements the
> standard enlist / unenlist / 2PC *happy path* when MSDTC and SQL Server
> are healthy. Deeper recovery (COM `IResourceManager` lifetime, in-doubt
> state after KILL, cross-host DTC) remains **out of the library**; operators
> rely on **MSDTC** + **SQL Server** documentation and, where applicable,
> manual intervention or a dedicated Windows *job* to drive `Reenlist` outside
> the ODBC client process. This document records scenarios and *observability*
> expectations, not a future PR commitment unless product reopens 1.1 in
> [PENDING_IMPLEMENTATIONS.md](../Features/PENDING_IMPLEMENTATIONS.md).

`native/odbc_engine/src/engine/xa_dtc.rs` implements the normal MSDTC path:
COM init, `ITransactionDispenser::BeginTransaction`, and
`SQLSetConnectAttr(SQL_ATTR_ENLIST_IN_DTC, …)`.

**Phase 1 / 2** in that module describes what is in code today versus what
still needs a _live_ Windows host with `sc query MSDTC` === `RUNNING` and
connectivity to SQL Server.

## Application-facing errors (enlist, no *Reenlist*)

The *crate* cannot finish in-doubt 2PC after MSDTC or the process fails;
operators use **MSDTC** / SQL Server tools. The application **does** receive
**actionable** `OdbcError::InternalError` text from
`native/odbc_engine/src/engine/xa_dtc.rs` when **enlist** or **unenlist**
`SQLSetConnectAttr` fails, including the `SqlReturn` *Debug* (e.g. `sql_error` /
`error`) for log correlation. Recommended guidance:

- **Log the full message** in your telemetry (do not match only a substring;
  the ODBC *return* changes with driver/MSDTC state).
- **Before retrying** a new branch, **close** the connection (or return it to
  a pool that discards tainted connections) and obtain a new physical ODBC
  handle — an enlisted `HDbc` is not guaranteed reusable after a failed DTC
  call.
- **If `SqlReturn` is not `SUCCESS` or `SUCCESS_WITH_INFO` after enlist,** treat
  the XA session as *not* enlisted; do not proceed to `xa_prepare` on that
  connection.

This section **closes the “mystery 500 / silent DTC” gap** in §1.1 of
`PENDING_IMPLEMENTATIONS.md` from a *documentation* perspective; it does *not*
add in-process *Reenlist*.

## What is not in-tree yet (hardening)

1. **MS DTC / XA resource manager recovery** — when the process, network, or
   MSDTC service fails mid-2PC, the Microsoft stack may require
   `IResourceManager::Reenlist` (or equivalent DTC / ODBC recovery flows) to
   finish in-doubt work. The current engine focuses on the **happy path** for
   enlist / prepare / commit. Adding Reenlist-based recovery is **operational
   work** (design per deployment + tests on real MSDTC), not a small patch.

2. **Scenario matrix (documentation-level)**
   - **A.** MSDTC process restart while connections are enlisted — expect
     explicit, actionable errors; document whether the app can retry.
   - **B.** Network partition after `xa_prepare` — recovery via `xa_recover` /
     resume on other engines; for MSDTC, behaviour depends on DTC and driver
     (document “verify with your DBA / MS doc”, not a promise in the driver).
   - **C.** `SQLSetConnectAttr(..., NULL)` unenlist before branch complete —
     should surface ODBC/DTC errors without corrupting the pool; covered by
     “fail closed” in transaction state machine, not a second COM layer in-tree.

3. **CI** — a **paid** or self-hosted **Windows** runner (with MSDTC
   service + optional SQL Server) is the only way to automate full E2E. The
   repository ships `#[ignore]` and env-gated tests; see
   [PENDING §1.1](../Features/PENDING_IMPLEMENTATIONS.md) and, if present,
   `.github/workflows` jobs with `workflow_dispatch` for `xa-dtc` builds.

## Where to look in code

- `engine/xa_dtc.rs` — enlist / unenlist, COM, error strings.
- `engine/xa_transaction.rs` — cross-vendor `apply_xa_*` matrix.
- `PENDING_IMPLEMENTATIONS.md` §1.1 — backlog for tuning + CI when product
  asks for it.
- *Ordering* of MSDTC / Oracle / *misc* *epics* (non-MSDTC): see
  [`ROADMAP_PENDENTES.md`](../notes/ROADMAP_PENDENTES.md) (Fase 2 in that index).

## Local runbook: MSDTC + SQL Server XA smoke test (Rust)

Use this on a **Windows** machine where the Distributed Transaction
Coordinator is running and SQL Server is reachable over ODBC.

**Prerequisites**

- `sc query MSDTC` reports `STATE: 4 RUNNING` (or equivalent *running* state).
- Microsoft ODBC driver for SQL Server 17/18 (or a driver that supports
  `SQL_ATTR_ENLIST_IN_DTC` with your build).
- Network path to a SQL Server instance the account can use for a short
  `xa_*` round-trip. One integration test **rolls back** after *prepare*;
  another **commits** after *prepare* (see table below). Both are safe for a
  throwaway *database*; use a non-prod DSN.

**Environment**

| Variable | Role |
| -------- | ---- |
| `ENABLE_MSDTC_XA_TESTS` | Must be `1` / `true` / `yes` in addition to E2E so the MSDTC smokes run. Without it, the tests return early (pass) even with `--include-ignored`, e.g. when a DSN is present but MSDTC enlist is not available. |
| `ENABLE_E2E_TESTS` | Must be `1` / `true` / `yes` so the smoke body runs (in addition to `#[ignore]`, which you remove with `--ignored`). The helper `should_run_e2e_tests()` in `tests/helpers/e2e.rs` also requires a **successful** ODBC probe to SQL Server when this is set. |
| `ODBC_TEST_DSN` | Preferred: full DSN string pointing at **SQL Server**. |
| `SQLSERVER_TEST_SERVER`, `SQLSERVER_TEST_DATABASE`, `SQLSERVER_TEST_USER`, `SQLSERVER_TEST_PASSWORD`, `SQLSERVER_TEST_PORT` | Used to build a DSN when `ODBC_TEST_DSN` is unset; see `tests/helpers/env.rs` (`get_sqlserver_test_dsn`). |

**PowerShell (from the repository root, adjust the DSN to your site)**

| Test name (substring filter) | Path after *prepare* |
| ---------------------------- | -------------------- |
| `xa_dtc_sqlserver_lifecycle_smoke` | `rollback` (default *cleanup* smoke) |
| `xa_dtc_sqlserver_prepare_commit_smoke` | `commit` (Phase 2 *commit*) |

Run **both** (prefix match `xa_dtc_sqlserver_`):

```powershell
$env:ENABLE_MSDTC_XA_TESTS = "1"
$env:ENABLE_E2E_TESTS = "1"
# Either set a full DSN, or rely on SQLSERVER_TEST_* in env / .env:
# $env:ODBC_TEST_DSN = "Driver={ODBC Driver 18 for SQL Server};Server=...;..."

Set-Location native
cargo test -p odbc_engine --features xa-dtc --test regression_test `
  xa_dtc_sqlserver_ -- --ignored --test-threads=1
```

Run a **single** test by passing the full name instead of the prefix, e.g.
`xa_dtc_sqlserver_lifecycle_smoke`.

Both live in
`native/odbc_engine/tests/regression/xa_dtc_test.rs` (the `regression_test`
integration binary, `tests/regression_test.rs`).

**CI (compile-only, no MSDTC in the default runner)**

- Manual workflow: [`.github/workflows/windows_xa_dtc_build.yml`](../../.github/workflows/windows_xa_dtc_build.yml) (`workflow_dispatch`).
- It runs `clippy` + `release` build + `cargo test -p odbc_engine --lib --features
  xa-dtc` and compiles (but does not *execute* ignored) integration tests. **It
  is not** a substitute for the live smoke test above.

**Troubleshooting**

- The test **returns early** (prints to stderr) if `ENABLE_MSDTC_XA_TESTS` is
  not set, if `ENABLE_E2E_TESTS` is not *true*, or the SQL Server connectivity
  probe in `should_run_e2e_tests()` fails — the run still *passes* because of
  those early `return`s.
- You must pass **`-- --ignored --test-threads=1`** so Cargo actually runs the
  test marked `#[ignore]`.
- If the binary fails to compile, run from `native` with
  `cargo test -p odbc_engine --no-run --features xa-dtc --tests` to see Rust
  errors without a live DSN.
