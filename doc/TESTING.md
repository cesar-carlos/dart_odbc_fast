# Test Policy and Coverage Guide

> **Last updated for:** v3.5.3

This document describes the test strategy, how to run each scope, and CI boundaries. Coverage snapshots are marked with their measurement date and are not authoritative for the current release — re-run `cargo tarpaulin` to get current numbers.

---

## Test scopes

### Dart

| Scope | Path | Notes |
|---|---|---|
| Unit — domain | `test/domain/` | Pure business rules; no native library required. |
| Unit — application | `test/application/` | Use-case orchestration; mocked boundaries. |
| Unit — infrastructure | `test/infrastructure/` | Protocol codecs, binary parsers, Dart-layer only. |
| Helpers | `test/helpers/database_detection_test.dart` | Driver detection heuristics. |
| Integration | `test/integration/` | Requires a live DSN (`ODBC_TEST_DSN`). T-SQL pool tests expect SQL Server. |
| E2E — directed OUT | `test/e2e/` | Opt-in via `E2E_PG_DIRECTED_OUT=1`, `E2E_MSSQL_DIRECTED_OUT_MULTI=1`, etc. Host with real ODBC driver required. |
| Slow / stress | `test/stress/` | Run with `RUN_SKIPPED_TESTS=1`. |

Run unit scopes:

```powershell
dart test test/application test/domain test/infrastructure test/helpers/database_detection_test.dart
```

Run all non-integration tests:

```bash
dart test
```

Run with slow / stress tests included:

```powershell
$env:RUN_SKIPPED_TESTS = '1'; dart test
```

Accepted values: `1`, `true`, `yes`.

### Rust

| Scope | Command | Notes |
|---|---|---|
| Lib unit tests | `cargo test --lib` | No live DB required. |
| All tests (lib + integration, skipping `#[ignore]`) | `cargo test --workspace` | Uses `.cargo/config.toml` `RUST_TEST_THREADS=1`. |
| Integration (requires `ODBC_TEST_DSN`) | `cargo test --include-ignored` | Gates on `ENABLE_E2E_TESTS=1`. |
| Slow E2E stress | Same as above + `ENABLE_SLOW_E2E_TESTS=1` | Pool stress, 50 k-row streaming, BCP 100 k. |
| XA / MSDTC smoke | `cargo test ... --features xa-dtc -- --ignored` | Requires Windows + `ENABLE_MSDTC_XA_TESTS=1` + MSDTC running. |

From `native/`:

```bash
cargo test --workspace -- --test-threads=1
```

### Docker E2E (no host drivers required)

See [`doc/development/docker-test-stack.md`](development/docker-test-stack.md) for the full Docker-based workflow.

Quick start (PostgreSQL):

```powershell
pwsh scripts/docker_e2e.ps1
```

---

## CI scope

The standard CI (`.github/workflows/ci.yml`) does **not** require a live database.

| Step | Command |
|---|---|
| Rust format | `cargo fmt --all -- --check` |
| Rust lint | `cargo clippy --workspace --all-targets -- -D warnings` |
| Rust build | `cargo build --release` |
| Rust tests | `cargo test --workspace -- --test-threads=1` |
| Dart analyze | `dart analyze` |
| Dart tests (unit only) | `dart test test/application test/domain test/infrastructure test/helpers/database_detection_test.dart` |

Variables set in CI: `ENABLE_E2E_TESTS=0`, `RUN_SKIPPED_TESTS=0`, `ODBC_TEST_DSN=""`.

Other workflows:

| Workflow | Trigger | Scope |
|---|---|---|
| `release.yml` | `push v*` / `workflow_dispatch` | Same quality gate + cross-platform binary build |
| `e2e_docker_stack.yml` | `push main` / PR / `workflow_dispatch` | Docker-based PG, MySQL, MariaDB, MSSQL |
| `e2e_multidb.yml` | `workflow_dispatch` | Multi-DB Rust E2E including BCP |
| `windows_xa_dtc_build.yml` | `workflow_dispatch` | `xa-dtc` compile + lib tests (no live MSDTC) |

---

## Reproducing coverage locally

```powershell
# from repo root
cd native\odbc_engine
cargo test --lib --tests --no-fail-fast --all-features -- --test-threads=1
cargo clippy --all-targets --all-features -- -D warnings
cargo tarpaulin --tests --lib `
  --out Stdout --out Html `
  --output-dir ..\..\coverage `
  --skip-clean --timeout 600 -- --test-threads=1
```

Open `coverage/tarpaulin-report.html` for the file-level drill-down.

---

## Coverage snapshot (v2.0.0 baseline — historical)

> **Note:** This snapshot was measured at v2.0.0 with no live ODBC database. Numbers have changed since then as new modules were added (XA, multi-stream, directed params, Oracle ref cursor, etc.). Re-run `cargo tarpaulin` to get current figures.

| Metric (v2.0.0) | Value |
|---|---|
| Overall line coverage | 41.64% (2 201 / 5 286 lines) |
| Unit tests passed | 766 / 766 |
| Integration tests passed | 314 / 314 (16 ignored — require `ODBC_TEST_DSN`) |
| Regression tests passed | 23 / 23 |
| Clippy strict | 0 warnings |

**Why coverage was low:** The FFI surface, catalog adapters, streaming worker and BCP shim require a live ODBC driver. With a configured `ODBC_TEST_DSN` the 16 ignored integration tests push coverage above 60%.

---

## Environment variables reference

| Variable | Scope | Purpose |
|---|---|---|
| `ENABLE_E2E_TESTS` | Rust | Enables integration tests that hit a real ODBC DSN. |
| `ODBC_TEST_DSN` | Rust + Dart | Full DSN string for the primary test database. |
| `ODBC_DSN` | Dart | Alternative env var for pool integration tests. |
| `RUN_SKIPPED_TESTS` | Dart | `1`/`true`/`yes` — include slow/stress tests. |
| `ENABLE_SLOW_E2E_TESTS` | Rust | `1` — include stress/benchmark E2E tests. |
| `ENABLE_MSDTC_XA_TESTS` | Rust | `1` — include MSDTC XA smoke tests (Windows, MSDTC running). |
| `E2E_PG_DIRECTED_OUT` | Dart | `1` — PostgreSQL directed `OUT` E2E test. |
| `E2E_MSSQL_DIRECTED_OUT_MULTI` | Dart | `1` — SQL Server DRT1 + multi-result E2E test. |
| `E2E_ORACLE_REFCURSOR` | Rust | `1` — Oracle ref cursor E2E test. |

---

## Related documentation

- Build instructions: [`BUILD.md`](BUILD.md)
- Docker test stack: [`development/docker-test-stack.md`](development/docker-test-stack.md)
- MSDTC runbook: [`development/msdtc-recovery.md`](development/msdtc-recovery.md)
- Pending test work: [`Features/PENDING_IMPLEMENTATIONS.md`](Features/PENDING_IMPLEMENTATIONS.md)
