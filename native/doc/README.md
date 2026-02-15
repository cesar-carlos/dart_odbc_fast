# Native (Rust) documentation

This folder contains curated documentation for the Rust native layer in `native/`,
focused on **what is implemented today** (and how to use it).

## Index

- [ODBC Engine overview](./odbc_engine_overview.md)
- [FFI API (C ABI) + examples](./ffi_api.md)
- [High‑throughput data paths](./data_paths.md)
  - streaming (FFI chunked copy-out + true cursor batching)
  - batch execution
  - array binding + parallel bulk insert
  - pooling
  - transactions (isolation + savepoints + RAII)
  - spill-to-disk, caches, protocol negotiation
  - observability + security helpers

## Source of truth

The source of truth is always the Rust code under:

- `native/odbc_engine/src`
- `native/odbc_engine/tests`

Some additional docs live next to the crate:

- `native/odbc_engine/ARCHITECTURE.md`
- `native/odbc_engine/E2E_TESTS_ENV_CONFIG.md`
- `native/odbc_engine/MULTI_DATABASE_TESTING.md`
- `native/odbc_engine/TARPAULIN_COVERAGE_REPORT.md`


