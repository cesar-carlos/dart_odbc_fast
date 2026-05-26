# ODBC Engine

Rust-native ODBC engine consumed by `dart_odbc_fast` over a stable C ABI.

## Overview

- C ABI surface: `src/ffi/mod.rs` (88 `odbc_*` exports).
- Engine internals: `src/engine`, `src/protocol`, `src/pool`, `src/handles`,
  `src/observability`, `src/security`.

## Documentation

User-facing curated docs live in [`../doc/`](../doc/) — start at
[`../doc/README.md`](../doc/README.md). The most relevant pages:

- [`../doc/ffi_api.md`](../doc/ffi_api.md) — C ABI reference.
- [`../doc/ffi_conventions.md`](../doc/ffi_conventions.md) — return codes,
  pointer/out contracts, ID rules.
- [`../doc/odbc_engine_overview.md`](../doc/odbc_engine_overview.md) —
  architecture and module map.
- [`../doc/data_paths.md`](../doc/data_paths.md) — execution, streaming,
  batching, pool, and bulk paths.
- [`../doc/cross_database.md`](../doc/cross_database.md) — multi-database
  support, DSNs, env vars, Docker, CI matrix.
- [`../doc/performance_comparison.md`](../doc/performance_comparison.md) —
  benchmark snapshots.

Crate-local docs:

- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — internal architecture decisions.
- [`tests/README.md`](./tests/README.md) — test catalog and run
  instructions.

## Build / test

```bash
cd native
cargo fmt --all
cargo clippy --all-targets --all-features -D warnings
cargo test
```

E2E tests against a live database require `ENABLE_E2E_TESTS=1` and a
configured DSN — see `../doc/cross_database.md`.
