# FFI_BACKWARD_COMPATIBILITY_CHECKLIST.md

ABI/API compatibility checklist between Rust FFI and Dart bindings.

## Date

- 2026-02-15

## Verified scope

1. `native/odbc_engine/odbc_exports.def`
2. `native/odbc_engine/include/odbc_engine.h`
3. `lib/infrastructure/native/bindings/odbc_bindings.dart`
4. `native/odbc_engine/cbindgen.toml`

## Verification result

- ODBC symbols used by Dart are exported in `odbc_exports.def`.
- C header (`odbc_engine.h`) contains primary ODBC symbols plus OpenTelemetry symbols.
- `odbc_bindings.dart` resolves all expected ODBC symbols.
- `cbindgen.toml` include list was aligned to explicitly include previously-missing entries:
  - `odbc_connect_with_timeout`
  - `odbc_savepoint_create`, `odbc_savepoint_rollback`, `odbc_savepoint_release`
  - `odbc_get_cache_metrics`, `odbc_clear_statement_cache`
  - `odbc_clear_all_statements`
  - `odbc_detect_driver`
  - `otel_*` (`otel_init`, `otel_export_trace`, `otel_export_trace_to_string`, `otel_get_last_error`, `otel_cleanup_strings`, `otel_shutdown`)

## Residual risks

1. Future C-signature changes without regenerating/validating Dart bindings.
2. Divergence between `.def`, header, and bindings in manual release flows.

## Recommended guardrails

1. For each release, run:
   - `dart analyze`
   - `dart test`
   - `cargo test -p odbc_engine --lib`
2. If FFI surface changes:
   - regenerate header (`cbindgen`)
   - validate `odbc_exports.def`
   - validate `odbc_bindings.dart` (lookup + typedefs)
3. Record symbol additions/removals/changes in changelog.
