# Test Policy and Coverage Guide

Build prerequisites live in [BUILD.md](BUILD.md); executable CI commands live
in [ci.yml](../.github/workflows/ci.yml).

This document describes the test strategy, how to run each scope, CI boundaries, and the regression contract for a confirmed bug. Coverage snapshots are marked with their measurement date and are not authoritative for the current release — re-run `cargo tarpaulin` to get current numbers.

## Bug fixes

Follow the [regression policy](../.cursor/rules/testing.mdc) for confirmed bugs.

Dart tests live under `test/` and mirror the production path. Native tests follow [`.cursor/rules/rust_testing.mdc`](../.cursor/rules/rust_testing.mdc).

---

## Test scopes

### Dart

| Scope                 | Path                                        | Notes                                                                                                           |
| --------------------- | ------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Unit — domain         | `test/domain/`                              | Pure business rules; no native library required.                                                                |
| Unit — application    | `test/application/`                         | Use-case orchestration; mocked boundaries.                                                                      |
| Unit — infrastructure | `test/infrastructure/`                      | Protocol codecs, parsers and native wrappers; some cases need a built library.                                                               |
| Documentation         | `test/documentation/`                       | DSN-free drift checks for docs, feature flags and stale wording.                                                |
| Examples              | `test/example/`                             | DSN-free smoke tests for opt-in examples.                                                                       |
| Helpers               | `test/helpers/database_detection_test.dart` | Driver detection heuristics.                                                                                    |
| Integration           | `test/integration/`                         | Mixed local/native and live-DSN tests. T-SQL pool tests expect SQL Server.                                      |
| E2E — directed OUT    | `test/e2e/`                                 | Host with real ODBC driver required; use the canonical opt-in flags below.                                     |
| Slow / stress         | `test/stress/`                              | Run with `RUN_SKIPPED_TESTS=1`.                                                                                 |

Run unit scopes:

```powershell
dart test test/application test/domain test/infrastructure test/helpers/database_detection_test.dart
```

Run the DSN-free documentation/example contract checks:

```powershell
python scripts/validate_all.py --docs-examples-only
```

Discover all Dart tests (includes integration and E2E files; individual tests
use their own prerequisites and opt-in gates). Use the explicit unit scopes
above for a predictable non-live run:

```bash
dart test
```

Run with slow / stress tests included:

```powershell
$env:RUN_SKIPPED_TESTS = '1'; dart test
```

Accepted values: `1`, `true`, `yes`.

### Rust

| Scope                                               | Command                                         | Notes                                                         |
| --------------------------------------------------- | ----------------------------------------------- | ------------------------------------------------------------- |
| Lib unit tests                                      | `cargo test --lib`                              | No live DB required.                                          |
| All tests (lib + integration, skipping `#[ignore]`) | `cargo test --workspace`                        | Uses `.cargo/config.toml` `RUST_TEST_THREADS=1`.              |
| Integration (requires `ODBC_TEST_DSN`)              | `cargo test -p odbc_engine --features test-helpers,ffi-tests -- --include-ignored --test-threads=1`                  | Gates on `ENABLE_E2E_TESTS=1`.                                |
| Slow E2E stress                                     | Same as above + `ENABLE_SLOW_E2E_TESTS=1`       | Pool stress, 50 k-row streaming, BCP 100 k.                   |
| XA / MSDTC smoke                                    | `cargo test ... --features xa-dtc -- --ignored` | Requires Windows + `ENABLE_MSDTC_XA_TESTS=1` + MSDTC running. |

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

| Step                   | Command                                                                                                |
| ---------------------- | ------------------------------------------------------------------------------------------------------ |
| Rust format            | `cargo fmt --all -- --check`                                                                           |
| Rust lint              | `cargo clippy --workspace --all-targets -- -D warnings`                                                |
| Rust build             | `cargo build --release`                                                                                |
| Rust tests             | `cargo test --workspace -- --test-threads=1`                                                           |
| Dart analyze           | `dart analyze`                                                                                         |
| Dart tests (unit only) | `dart test test/application test/domain test/infrastructure test/helpers/database_detection_test.dart` |
| Docs/example smoke     | `dart test test/documentation test/example`                                                            |

Variables set in CI: `ENABLE_E2E_TESTS=0`, `RUN_SKIPPED_TESTS=0`,
`ODBC_TEST_DSN=""`, `ODBC_EXAMPLE_DISABLE_DSN=1`.

The `coverage` job runs on push to `main` only (after the `test` job,
~20 minutes into the full CI run). It uploads Dart (`lib/`) and Rust
(`native/`, flag-only) LCOV reports to Codecov. GitHub Actions must
define a repository secret `CODECOV_TOKEN` (from
[app.codecov.io](https://app.codecov.io) after installing the Codecov
GitHub App). Without the token, uploads to protected branches are
rejected and the badge stays at 0%.

**Known gap — Codecov ignores `native/**`:** `.codecov.yml` sets
`coverage.ignore` to `native/**` (along with `example/**` and `test/**`),
so the Codecov project/patch gates apply to the Dart package surface
(`lib/`) only. Rust coverage is measured locally with `cargo tarpaulin`
(see [Reproducing coverage locally](#reproducing-coverage-locally)); it
is not folded into the Codecov badge or the 80% gate. The combined
badge therefore understates native engine coverage — treat it as a
Dart-layer regression guard, not whole-repo coverage.

Other workflows:

| Workflow                   | Trigger                                | Scope                                           |
| -------------------------- | -------------------------------------- | ----------------------------------------------- |
| `release.yml`              | `push v*` / `workflow_dispatch`        | Same quality gate + cross-platform binary build |
| `e2e_docker_stack.yml`     | `push main` / PR / `workflow_dispatch` | Docker-based PG, MySQL, MariaDB, MSSQL          |
| `e2e_multidb.yml`          | `workflow_dispatch`                    | Multi-DB Rust E2E including BCP                 |
| `windows_xa_dtc_build.yml` | `workflow_dispatch`                    | `xa-dtc` compile + lib tests (no live MSDTC)    |

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

Equivalent wrapper (from repo root, writes under `native/coverage/`): `python native/odbc_engine/scripts/run_coverage.py` (use `--lib-only` for a faster run that omits integration tests and matches the historical lib-only metric).

---

## Coverage snapshot (v2.0.0 baseline — historical)

> **Note:** This snapshot was measured at v2.0.0 with no live ODBC database. Numbers have changed since then as new modules were added (XA, multi-stream, directed params, Oracle ref cursor, etc.). Re-run `cargo tarpaulin` to get current figures.

| Metric (v2.0.0)          | Value                                            |
| ------------------------ | ------------------------------------------------ |
| Overall line coverage    | 41.64% (2 201 / 5 286 lines)                     |
| Unit tests passed        | 766 / 766                                        |
| Integration tests passed | 314 / 314 (16 ignored — require `ODBC_TEST_DSN`) |
| Regression tests passed  | 23 / 23                                          |
| Clippy strict            | 0 warnings                                       |

**Why coverage was low:** Several FFI, catalog, streaming and BCP paths need a
live ODBC driver. Measure coverage with the intended driver matrix rather than
inferring a current percentage from this historical run.

---

## Canonical opt-in environment variables

| Variable                       | Scope       | Purpose                                                      |
| ------------------------------ | ----------- | ------------------------------------------------------------ |
| `ENABLE_E2E_TESTS`             | Rust        | Enables integration tests that hit a real ODBC DSN.          |
| `ODBC_TEST_DSN`                | Rust + Dart | Full DSN string for the primary test database.               |
| `ODBC_DSN`                     | Dart        | Alternative env var for pool integration tests.              |
| `RUN_SKIPPED_TESTS`            | Dart        | `1`/`true`/`yes` — include slow/stress tests.                |
| `RUN_PERF_TESTS`               | Dart        | `1`/`true`/`yes` — benchmark-style tests with runtime-sensitive expectations (`test/performance/`). |
| `ENABLE_SLOW_E2E_TESTS`        | Rust        | `1` — include stress/benchmark E2E tests.                    |
| `ENABLE_MSDTC_XA_TESTS`        | Rust        | `1` — include MSDTC XA smoke tests (Windows, MSDTC running). |
| `E2E_PG_DIRECTED_OUT`          | Dart        | `1` — PostgreSQL directed `OUT` E2E test.                    |
| `E2E_MSSQL_DIRECTED_OUT`       | Dart        | `1` — SQL Server scalar directed `OUT` E2E test.              |
| `E2E_MSSQL_DIRECTED_OUT_MULTI` | Dart        | `1` — SQL Server DRT1 + multi-result E2E test.               |
| `E2E_ORACLE_REFCURSOR`         | Rust        | `1` — Oracle ref cursor E2E test.                            |
| `ODBC_EXAMPLE_DISABLE_DSN`     | Examples    | `1` — force examples to skip DB work for DSN-free smoke runs. |

Other docs and runbooks may link to this table, but this section owns the
canonical spelling and opt-in meaning for live-driver flags.

---

## Related documentation

- Build instructions: [`BUILD.md`](BUILD.md)
- Docker test stack: [`development/docker-test-stack.md`](development/docker-test-stack.md)
- MSDTC runbook: [`development/msdtc-recovery.md`](development/msdtc-recovery.md)
- Pending test work: [`Features/PENDING_IMPLEMENTATIONS.md`](Features/PENDING_IMPLEMENTATIONS.md)

## Dart hot-path comparison

Historical benchmark methodology and results are maintained in
[Performance: Dart hot-path comparison](PERFORMANCE.md#dart-hot-path-comparison).
These snapshots do not establish the current test count or live-driver coverage.
