# Test Policy and Coverage Guide

> **Last updated for:** v4.5.x (`4.5.1` — Dart FFI dispatch cache and
> protocol parse allocation; prior `4.5.0` binary scalars, stream/pool hot
> paths, additive stream/buffer knobs; prior 4.4.0 async XA, dialect service,
> multi-stream knobs, dual barrels, segregated repositories,
> event bus, columnar service surface, FFI `GlobalState` sharding, CI unit +
> docs/example smoke scopes). Canonical opt-in flags and suite ownership live
> below; build/prereq details live in [`BUILD.md`](BUILD.md).

This document describes the test strategy, how to run each scope, and CI boundaries. Coverage snapshots are marked with their measurement date and are not authoritative for the current release — re-run `cargo tarpaulin` to get current numbers.

---

## Test scopes

### Dart

| Scope                 | Path                                        | Notes                                                                                                           |
| --------------------- | ------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Unit — domain         | `test/domain/`                              | Pure business rules; no native library required.                                                                |
| Unit — application    | `test/application/`                         | Use-case orchestration; mocked boundaries.                                                                      |
| Unit — infrastructure | `test/infrastructure/`                      | Protocol codecs, binary parsers, Dart-layer only.                                                               |
| Documentation         | `test/documentation/`                       | DSN-free drift checks for docs, feature flags and stale wording.                                                |
| Examples              | `test/example/`                             | DSN-free smoke tests for opt-in examples.                                                                       |
| Helpers               | `test/helpers/database_detection_test.dart` | Driver detection heuristics.                                                                                    |
| Integration           | `test/integration/`                         | Requires a live DSN (`ODBC_TEST_DSN`). T-SQL pool tests expect SQL Server.                                      |
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

| Scope                                               | Command                                         | Notes                                                         |
| --------------------------------------------------- | ----------------------------------------------- | ------------------------------------------------------------- |
| Lib unit tests                                      | `cargo test --lib`                              | No live DB required.                                          |
| All tests (lib + integration, skipping `#[ignore]`) | `cargo test --workspace`                        | Uses `.cargo/config.toml` `RUST_TEST_THREADS=1`.              |
| Integration (requires `ODBC_TEST_DSN`)              | `cargo test --include-ignored`                  | Gates on `ENABLE_E2E_TESTS=1`.                                |
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

**Why coverage was low:** The FFI surface, catalog adapters, streaming worker and BCP shim require a live ODBC driver. With a configured `ODBC_TEST_DSN` the 16 ignored integration tests push coverage above 60%.

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

Run `dart run benchmarks/dart_hot_paths.dart` for cursor consumption and indexed
column access and complete fragmented framing; `--linear` retains the old
column helper for comparison. Output
contains 15 measured samples after six warmups, in microseconds. Each sample
uses eight rounds, except the single full frame which uses 64 rounds to reduce
timer noise. Complete framing uses one round per sample. Compare the same SDK,
machine and workload. Frames cover small
coalesced inputs, large/full-capacity inputs, fragmentation and retained lazy
text. When comparing revisions, copy the original accumulator into an ignored
working directory for accumulator-only comparisons. For end-to-end framing,
archive the baseline `lib/` tree and use a separate package configuration that
maps `package:odbc_fast` to that tree, keeping dependency and SDK paths fixed.
Copy the same benchmark to that directory; instrument only backing allocation
and pending-byte copy counters, without changing baseline algorithms. No DSN
or native ABI change is involved. Check distributions and repeat in reverse
execution order to assess noisy cases.

### Measured comparison (2026-09-30)

Windows x64, Dart 3.13.4 stable, one process at a time without concurrent test
suites. Baseline accumulator:
`7fe2b37f91d1338d19753c44d567387ead5bda80`; column baseline uses the retained
`result.cell` helper. Numbers below are medians per sample, not per operation.
The ratio interval resamples baseline and revised samples independently 10,000
times with seed 7, comparing their medians. A ratio below 1 favors the revision.

| Scenario | Baseline (ms) | Revised (ms) | Speedup | Revised/baseline 95% bootstrap interval |
| --- | ---: | ---: | ---: | --- |
| 500 frames, 32 bytes | 16.040 | 0.072 | 222.78x | 0.004–0.009 |
| 2,000 frames, 32 bytes | 84.362 | 0.222 | 380.01x | 0.002–0.003 |
| 8,000 frames, 32 bytes | 482.535 | 3.161 | 152.65x | 0.006–0.007 |
| 16 frames, 65,536 bytes | 26.831 | 3.152 | 8.51x | 0.109–0.120 |
| Single frame, 65,536 bytes (64 rounds) | 0.992 | 0.664 | 1.49x | 0.107–1.116 |
| 13-byte input fragments | 42.103 | 38.419 | 1.10x | 0.863–0.963 |
| Retained lazy text | 778.188 | 1.077 | 722.55x | 0.001–0.001 |
| Repeated column lookup | 598.942 | 5.972 | 100.29x | 0.010–0.010 |

Consumption no longer copies the remainder after each frame. For one pass over
8,000 32-byte frames, this removes 1,023,872,000 bytes of remainder copying;
cursor advancement copies none. Adding new bytes after delivering shared views
still detaches the backing and copies pending bytes once to preserve ownership.
The full-frame interval includes 1: this run establishes no significant change
in that noisy scenario. All other intervals favor the revision. These are local
JIT measurements, not a cross-platform performance guarantee.

The implementation regression run uses the canonical CI flags (`CI=true`,
`ENABLE_E2E_TESTS=0`, `RUN_SKIPPED_TESTS=0`, `RUN_LIVE_TESTS=0`). Additional checks
cover public exports, documentation, examples, and the CI protocol performance
tests. Local integration cases run without a DSN; live-driver cases explicitly
skip when their prerequisites are unavailable. No live database result is
claimed by this comparison.

Validation recorded for the earlier cursor/reader revision: `dart analyze`
reports no issues; the CI unit
command passes 1,607 tests with three explicit skips. The complementary core,
exports, documentation and examples suite passes 85 tests, and the CI protocol
performance suite passes 10. Local integration passes 16 cases with 25 explicit
live-driver skips. The CI slow-test check also passes its 1,500 ms threshold.

### Buffer and lifecycle safety comparison (2026-10-03)

Baseline `522dc45`, Windows x64, Dart 3.13.4 stable, sequential JIT processes
with no concurrent test suites. Each process uses six warmups and 15 measured
samples. The repeated run reverses process order. The following medians are
from that repeated run; bootstrap intervals resample the two median
distributions independently 2,000 times with seed 42. Ratios above 1 favor
the revision. They describe this machine, rather than a portable guarantee.

| Scenario | Baseline (microseconds) | Revised (microseconds) | Baseline/revised 95% interval |
| --- | ---: | ---: | --- |
| 500 frames, 32 bytes | 105 | 95 | 0.46–1.96 |
| 2,000 frames, 32 bytes | 236 | 239 | 0.71–1.23 |
| 8,000 frames, 32 bytes | 3,094 | 2,887 | 0.81–1.17 |
| 16 frames, 65,536 bytes | 3,251 | 3,277 | 0.86–1.15 |
| Single 65,536-byte frame, 64 rounds | 682 | 450 | 1.15–3.45 |
| 13-byte fragments | 35,645 | 18,060 | 1.91–2.03 |
| Complete 128 KiB frame, 1 KiB fragments | 6,104 | 200 | 15.12–43.25 |
| Complete 256 KiB frame, 1 KiB fragments | 19,283 | 193 | 56.80–110.98 |
| Complete 512 KiB frame, 1 KiB fragments | 58,963 | 222 | 110.28–363.22 |
| Complete 1 MiB frame, 1 KiB fragments | 191,704 | 366 | 400.32–626.79 |
| Retained lazy text | 1,095 | 882 | 1.18–1.37 |
| Indexed column lookup | 6,074 | 5,616 | 1.04–1.19 |

The small-frame/full-frame intervals include 1 for four retained scenarios;
the repeated run provides no statistically significant regression there.
The initial 500-frame sample looked slower, but that change did not persist
when execution order was reversed. Complete 1 MiB framing improved about
524 times in this local run.

| Complete framing size | Baseline pending bytes copied | Revised pending bytes copied |
| --- | ---: | ---: |
| 128 KiB | 8,323,072 | 65,536 |
| 256 KiB | 33,423,360 | 65,536 |
| 512 KiB | 133,955,584 | 65,536 |
| 1 MiB | 536,346,624 | 65,536 |

Owned header prefixes no longer expose backing on every fragment, and the
validated length is cached until completion. Pending bytes are copied once
when capacity grows from 64 KiB to 1 MiB in these cases. Further growth doubles
capacity, so assembly copies grow linearly rather than quadratically.
Backing allocation counters include all warmup and measured rounds, not live
heap size or every Dart object. For complete 1 MiB framing they fell from
21,227,372,544 to 22,020,096 bytes across 21 rounds.

The safety policy also has a measurable cost: after forced GC with only a
derived byte view, `ByteData` or lazy string retained, the old finalizer could
reuse the backing and corrupt the consumer's data. The separate allocation
probe reported zero new backing bytes and invalid retained data for `522dc45`;
the revision allocated 65,536 new backing bytes and preserved every view.
Automatic recycling of exposed backing is therefore removed. Only unexposed
abandoned buffers and explicit exclusive-ownership offers may enter the pool.

Run the ownership check separately from the fast unit budget:

```sh
dart test test/integration/protocol_frame_ownership_gc_test.dart
```

It launches a child Dart VM with a local service, requests GC through the VM
service, checks independent derived views after their original frames become
unreachable, and always kills the child on exit or its 30-second deadline.
The CI runs this as a separate step. It requires no DSN or native library.

Deterministic fakes cover concurrent initialization, interrupted spawn/handshake,
worker exit, partial failure, generation changes, completion evidence and late
resources. Native evidence is per invocation: missing status does not imply
consumption. A timeout completes the caller once while unresolved work retains
capacity; maintenance runs on its owning worker and checks every cleanup result.
Prepared XA resumption is adopted explicitly by immutable XID key. Unknown
transaction outcomes prohibit conflicting work and automatic transaction
decisions, including phases attempted inside a helper's callback. Dispose or
worker death reports unconfirmed cleanup, because a blocked FFI call cannot be
guaranteed to cancel from Dart. UTF-8 XID tests cover byte limits and invalid
surrogates; recovery of old non-ASCII branches requires their original bytes.

Validation of this safety revision: `dart analyze` reports no issues. The CI
unit command passes 1,668 tests with three explicit skips; core, public exports,
documentation and examples pass 85. FFI export verification confirms 111 symbols.
The protocol performance guard passes 10 tests and the standalone GC process
passes its ownership check. Local integration passes 17 cases with 25 explicit
live-driver skips. The slow-test budget passes its 1,500 ms threshold (the
slowest reported case was 1,023 ms); GC runs outside that unit budget. No live
database result is claimed. Late successful pool release/close and async free
also remove repository metadata, while the previously returned timeout remains
a failure with its original operation and request identifiers.
