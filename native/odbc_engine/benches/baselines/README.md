# Criterion baselines

This directory holds opt-in snapshot baselines for the four synthetic
benches under `native/odbc_engine/benches/`. They are used to detect
performance regressions between PRs without depending on a live ODBC
driver.

## Files

When populated, each Criterion bench produces one or more
`<bench_id>/base.json` files under
`native/odbc_engine/target/criterion/<group>/<id>/new/`. The relevant
baselines for cross-PR diff are committed here.

## Refresh procedure

Run from `native/odbc_engine/`:

```bash
# 1. Generate fresh measurements on the reference machine.
cargo bench --bench cell_reader_bench -- --save-baseline default
cargo bench --bench encoder_bench -- --save-baseline default
cargo bench --bench ffi_contention_bench -- --save-baseline default
cargo bench --bench prepared_cache_bench -- --save-baseline default

# 2. Copy the resulting JSON snapshots here. Criterion writes them to
#    target/criterion/<group>/<id>/new/{estimates.json, raw.csv, ...}.
#    Only `estimates.json` and `benchmark.json` are needed for diff.
```

PRs that change perf-sensitive code can compare against the snapshot:

```bash
cargo bench --bench encoder_bench -- --baseline default
```

Criterion prints a `change` line per bench (`improved`, `regressed`,
`no change`) using the committed baseline.

## What lives here

This directory intentionally starts **empty** apart from this README:
the first baseline snapshot is captured as part of PR3.1 (C9) by the
person merging it on the reference Linux runner that owns the
`native_bench_baseline.yml` workflow added in PR3.1 (C10). Capturing
on a heterogeneous mix of developer machines would produce noisy
baselines that mask real regressions; rely on the workflow output
instead.

Future baseline refreshes are expected when:

- Hardware of the reference runner changes meaningfully.
- A perf PR intentionally changes the baseline (record the new
  reference in the same PR that introduces the change, with the
  before/after delta documented in the PR body).
