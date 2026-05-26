# Native (Rust) Documentation

Curated docs for the Rust native layer under `native/`, focused on current
behavior and operational guidance.

## Index

### Core references

- [ffi_api.md](./ffi_api.md): C ABI/FFI reference for `odbc_*`.
- [ffi_conventions.md](./ffi_conventions.md): return codes, IDs, pointer
  contracts.
- [odbc_engine_overview.md](./odbc_engine_overview.md): architecture and module
  map.
- [data_paths.md](./data_paths.md): execution/streaming/bulk/pool flow and
  limits.

### Usage and operations

- [async_api_guide.md](./async_api_guide.md): async usage from Dart
  (execute/stream/recovery).
- [profile_selection_guide.md](./profile_selection_guide.md): decision tree
  for picking `OdbcUsageProfile` (Flutter, CLI, server, batch).
- [cross_database.md](./cross_database.md): multi-db support, DSNs, quirks, CI
  matrix.
- [performance_comparison.md](./performance_comparison.md): benchmark snapshots
  and recommendations.
- [bcp_dll_compatibility.md](./bcp_dll_compatibility.md): SQL Server BCP
  compatibility and constraints.
- [getting_started_with_implementation.md](./getting_started_with_implementation.md):
  implementation playbook.

### Planning and process

- [plan_checklist_template.md](./plan_checklist_template.md): reusable
  completion checklist for future plans.
- [zero_copy_ffi_evaluation.md](./zero_copy_ffi_evaluation.md): viability
  analysis and prerequisites for zero-copy FFI result buffers (deferred
  to a future release).

## Documentation policy

- Keep only active docs with implementation or operational value.
- Remove stale status sections tied to one-off runs.
- Update cross-links in this README whenever files are renamed or removed.

## Source of truth

Primary source is code:

- `native/odbc_engine/src`
- `native/odbc_engine/tests`

Companion crate docs:

- `native/odbc_engine/ARCHITECTURE.md` — internal architecture and module map.
- `native/odbc_engine/tests/README.md` — test catalog and run instructions.

Multi-database, DSN, and `.env` configuration is consolidated in
[cross_database.md](./cross_database.md) (formerly split across
`MULTI_DATABASE_TESTING.md` / `E2E_TESTS_ENV_CONFIG.md`, both removed).

Docker test environment:

- `docker/README.md`
- `docker-compose.yml`


