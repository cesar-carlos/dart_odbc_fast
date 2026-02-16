# GAPS_IMPLEMENTATION_MASTER_PLAN.md

Detailed master plan to close all implementation gaps between Rust and Dart layers.

## Objective

Eliminate inconsistencies between Rust backend (FFI/exports) and Dart layer (bindings, sync/async wrappers, repository, and services), with test coverage and updated documentation.

## Current status (2026-02-15)

1. GAP 1 (real telemetry FFI): implemented.
2. GAP 3 (`clearAllStatements` real behavior): implemented (Rust + Dart sync/async).
3. GAP 2 (real async streaming via isolate): implemented.
4. GAP 4 (`bulk_insert_parallel` end to end): implemented (Rust + Dart sync/async + service/repository).
5. Tests executed after implementation:
   - Rust: `cargo test --workspace --all-targets --all-features` (green)
   - Dart: `dart test` (green)
6. Comparative benchmark published:
   - `native/odbc_engine/tests/e2e_bulk_compare_benchmark_test.rs`
   - run command: `cargo test --test e2e_bulk_compare_benchmark_test -- --ignored --nocapture`
7. New identified gap (2026-02-16):
   - Public Data Type mapping contract is not explicit in canonical Dart docs/API.
   - Rust has internal type mapping, but Dart public layer does not expose an equivalent map/contract.
8. Remaining open gaps (implementation pending):
   - GAP 5 (statement cancellation contract)
   - GAP 6 (data type mapping parity and canonical contract)

## Gap scope

1. Telemetry: Rust exports `otel_*`, but Dart used a stub without real FFI.
2. Async streaming: async layer did not use real streaming FFI (full fetch fallback).
3. `clearAllStatements`: Dart API existed but was stubbed/no-op.
4. `bulk_insert_parallel`: symbol existed in bindings but was not fully exposed at high-level Dart and Rust path was incomplete.
5. Cancellation: `cancelStatement` exposed in Dart while Rust marked as unsupported.
6. Data type mapping parity and documentation: Rust internal `DataType -> SQL code -> OdbcType` exists, but Dart/public docs do not provide a canonical mapping contract.

## Priority and sequence

Recommended implementation order:

1. GAP 1 (real telemetry)
2. GAP 3 (`clearAllStatements`)
3. GAP 2 (real async streaming)
4. GAP 4 (`bulk_insert_parallel`)
5. GAP 5 (statement cancellation)
6. GAP 6 (data type mapping parity and canonical contract)

Rationale:

- Items 1 and 3 remove obvious divergence with controlled risk.
- Items 2 and 4 are structural and should follow after initial stabilization.
- Item 5 depends on product contract decision (supported capability vs explicit unsupported behavior).
- Item 6 closes a documentation/API clarity gap and prevents drift between Rust and Dart behavior.

## Detailed plan by gap

## GAP 1 - Real telemetry FFI in Dart

### Previous state

- Rust implemented and exported: `otel_init`, `otel_export_trace`, `otel_export_trace_to_string`, `otel_get_last_error`, `otel_cleanup_strings`, `otel_shutdown`.
- Dart `OpenTelemetryFFI` was a stub and did not use `DynamicLibrary`.

### Implementation

1. Create real FFI bindings in `lib/infrastructure/native/bindings/opentelemetry_ffi.dart`.
2. Reuse `library_loader.dart` to load the same binary (`odbc_engine.dll` / `libodbc_engine.so`).
3. Map contracts using correct types.
4. Update `TelemetryRepositoryImpl` for real return codes and error handling.
5. Keep safe fallback behavior for older DLLs without `otel_*` symbols.

### Tests

1. Update `test/infrastructure/native/telemetry/opentelemetry_ffi_test.dart` to validate real FFI path.
2. Add compatibility tests for missing symbols and controlled failure behavior.
3. Add regression tests for `otel_get_last_error` message flow.

### Documentation

1. Update `doc/OBSERVABILITY.md` with real contract and error codes.
2. Update `README.md` telemetry status.
3. Record changes in `CHANGELOG.md`.

### Acceptance criteria

- `OpenTelemetryFFI` is no longer a stub.
- Telemetry tests pass against real library.
- Telemetry failures are traceable via Dart API.

## GAP 2 - Real async streaming over worker isolate

### Previous state

- Async layer used one-shot query style instead of native streaming protocol for large results.

### Implementation

1. Ensure async protocol includes `stream_start`, `stream_fetch`, and `stream_close` messages.
2. Implement isolate-side dispatch to native streaming functions.
3. Expose batched stream consumption at repository/service layer.
4. Keep compatibility fallback behavior when streaming is unavailable.

### Tests

1. Worker protocol tests for start/fetch/close lifecycle.
2. Mid-stream failure propagation tests.
3. Concurrency tests for independent stream sessions.

### Acceptance criteria

- Async streaming uses incremental native protocol.
- No silent stream failures.
- Repository/service streaming APIs operate without full-materialization requirement.

## GAP 3 - Real `clearAllStatements` implementation

### Previous state

- Dart API returned fixed success without native operation.

### Implementation

1. Define Rust contract: `odbc_clear_all_statements() -> c_int`.
2. Implement global statement cleanup in Rust with structured errors.
3. Export through `.def` and header generation.
4. Wire Dart bindings and sync/async layers to native implementation.

### Tests

1. Rust tests: no statements, active statements, invalid states.
2. Dart tests: sync call path, async call path, error mapping.

### Acceptance criteria

- API triggers real cleanup in native layer.
- Metrics/cache behavior reflects cleanup.
- No stub behavior remains.

## GAP 4 - End-to-end `bulk_insert_parallel`

### Previous state

- Partial exposure existed but high-level end-to-end behavior was incomplete.

### Implementation

1. Complete Rust parallel path and error propagation.
2. Expose repository/service methods with consistent contract.
3. Preserve fallback when `parallelism <= 1`.
4. Validate memory and throughput behavior under load.

### Tests

1. Unit coverage for parameter validation and fallback behavior.
2. Integration with real pool path.
3. Comparative benchmark coverage (`array` vs `parallel`).

### Acceptance criteria

- Full sync/async/service path available.
- Stable benchmark gains in expected environments.

## GAP 5 - Statement cancellation contract

### Current state

- Dart exposes cancellation entry points; Rust side marks unsupported path.

### Decision options

1. Implement true cancellation end to end.
2. Keep unsupported but make capability explicit and documented.

### Required actions

1. Align Dart API contract with Rust capability.
2. Add explicit error classification for unsupported mode.
3. Document behavior in README and troubleshooting.
4. Track execution tasks in `doc/notes/STATEMENT_CANCELLATION_IMPLEMENTATION_CHECKLIST.md`.

### Acceptance criteria

- No ambiguity in cancellation support.
- Consistent behavior across sync/async paths.

## GAP 6 - Data type mapping parity and canonical contract

### Current state

- Rust has internal mapping:
  - `odbc_api::DataType -> SQL type code` and `SQL type code -> OdbcType` in `native/odbc_engine/src/protocol/types.rs`.
  - Driver-specific remapping via plugins (`sqlserver`, `postgres`, `oracle`, `sybase`).
- Dart has parameter typing via `ParamValue` (6 types), but no canonical public `SqlType` map/API.
- Dart main parser in use (`binary_protocol.dart`) converts only a subset directly (string/int32/int64), while richer parser artifact exists separately, creating ambiguity.
- Legacy generated docs in `doc/api/` mention `SqlType`/`request.output` concepts inspired by npm `mssql`, but these are not current implemented public contracts.

### Implementation

1. Define a canonical public mapping contract for Dart (document-first, then code exposure if needed):
   - `ParamValue` types and intended SQL category mapping.
   - Result decoding behavior by ODBC type code.
2. Align parser strategy:
   - Choose one canonical parser implementation.
   - Remove or deprecate orphan parser path to avoid behavior drift.
3. Add explicit non-goals in canonical docs:
   - No public `SqlType` (30+ types) contract yet.
   - No `request.output` API yet (tracked in backlog).
4. Add optional forward-compatible API plan (if approved):
   - Introduce `SqlDataType` enum/table in Dart without breaking existing `ParamValue` APIs.

### Tests

1. Add/expand Dart protocol tests for all currently supported result type families:
   - varchar/text, int32, int64, decimal/text-decimal, date/timestamp representation, binary.
2. Add compatibility tests ensuring parser behavior is stable across sync/async/repository paths.
3. Add regression test that verifies documented map and runtime decode behavior remain consistent.

### Documentation

1. Update `README.md` with explicit "implemented today vs planned" type mapping scope.
2. Add/update canonical doc `doc/TYPE_MAPPING.md` and link it from `doc/README.md`.
3. Keep `doc/api/` treated as generated only; avoid using it as source of truth for roadmap commitments.
4. Track execution tasks in `doc/notes/TYPE_MAPPING_IMPLEMENTATION_CHECKLIST.md`.

### Acceptance criteria

- One canonical and explicit type mapping contract exists in code/docs.
- No conflicting parser behavior or orphan parser path remains.
- No ambiguity between implemented `ParamValue` scope and legacy `SqlType` ideas.
- Tests validate decoding/mapping behavior for supported types.

## Validation matrix

After each gap implementation:

1. `dart analyze`
2. `dart test`
3. `cargo test -p odbc_engine --lib`
4. Targeted integration/benchmark run when applicable

## Documentation update policy

After each closed gap:

1. Update canonical docs in `doc/`.
2. Update `CHANGELOG.md` with user-visible impact.
3. Keep `doc/notes/` as supporting evidence, not canonical source.

## Completion criteria for this master plan

- All implemented gaps verified by tests
- No remaining stubs for targeted APIs
- Rust/Dart contracts aligned and documented
- Release workflow verifies supported behavior without manual patching
