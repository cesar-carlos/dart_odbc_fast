# NULL_HANDLING_RELIABILITY_PERFORMANCE_PLAN.md

Detailed implementation plan to improve NULL handling correctness and hot-path performance.

## Objective

Ensure `null` values are persisted as SQL `NULL` when intended, prevent accidental `"null"` string writes caused by implicit fallback conversion, and improve parameter mapping performance.

## Reference date

- 2026-02-16

## Problem statement (current behavior)

1. Parameter conversion currently falls back to `toString()` for unsupported types:
   - `lib/infrastructure/native/protocol/param_value.dart`
   - `lib/infrastructure/repositories/odbc_repository_impl.dart`
2. This fallback can silently convert unexpected objects into text, increasing risk of persisting `"null"` as text in real workloads.
3. Bulk insert currently accepts `null` for non-nullable columns and serializes default placeholder values instead of failing fast:
   - `lib/infrastructure/native/protocol/bulk_insert_builder.dart`
4. Parameter mapping logic is duplicated in multiple places and can be optimized.

## Scope

- Dart-side parameter conversion hardening.
- Bulk insert nullability validation hardening.
- Non-breaking performance improvements in parameter mapping.
- Tests and documentation updates.

## Non-goals

- No change to Rust binary protocol format.
- No introduction of output parameter support in this plan.
- No broad API redesign unrelated to null/type conversion.

## Target outcomes

1. Unexpected parameter types no longer silently become strings.
2. Real `null` consistently maps to SQL `NULL`.
3. Bulk insert with `nullable: false` + `null` fails early with clear error.
4. Parameter mapping has lower allocation overhead in common paths.

## Phase 0 - Baseline and safety net

### Tasks

- [ ] P0.1 Capture baseline behavior with focused tests for:
  - `null` insert via `executeQueryParams`
  - `"null"` string insert via `executeQueryParams`
  - non-nullable bulk column receiving `null`
- [ ] P0.2 Record current behavior in a short test note.

### Validation

1. `dart analyze`
2. `dart test`

## Phase 1 - Parameter conversion hardening

### Design

Replace silent fallback conversion with explicit behavior:

- Supported implicit input types:
  - `null`, `ParamValue`, `int`, `String`, `List<int>`/`Uint8List`, `bool`, `double`, `DateTime`
- Unsupported types:
  - return explicit `ValidationError` (no implicit `toString()` fallback)

Recommended canonical mappings:

- `bool` -> `ParamValueInt32(1|0)` (stable SQL compatibility)
- `double` -> `ParamValueDecimal(value.toString())`
- `DateTime` -> `ParamValueString(value.toUtc().toIso8601String())`

### Tasks

- [ ] P1.1 Create a single shared parameter mapping utility used by both:
  - `param_value.dart` conversion helper
  - `odbc_repository_impl.dart` conversion path
- [ ] P1.2 Remove implicit unknown-type `toString()` fallback.
- [ ] P1.3 Add explicit error path with actionable message:
  - includes received runtime type
  - suggests explicit `ParamValue*` wrapper when needed
- [ ] P1.4 Add fast path for pre-typed `List<ParamValue>`.

### Validation

1. `dart analyze`
2. `dart test`

## Phase 2 - Bulk insert nullability correctness

### Tasks

- [ ] P2.1 In `BulkInsertBuilder.build()`, validate all rows:
  - if `spec.nullable == false` and row value is `null`, throw `StateError` with column name and row index
- [ ] P2.2 Keep current nullable bitmap behavior for `nullable: true`.
- [ ] P2.3 Add clear error messages for invalid nullability input.

### Validation

1. `dart analyze`
2. `dart test`

## Phase 3 - Performance improvements (non-breaking)

### Tasks

- [ ] P3.1 Eliminate duplicated mapping loops where possible.
- [ ] P3.2 Pre-size output lists in mapping helpers.
- [ ] P3.3 Avoid extra intermediate allocations in parameter conversion.
- [ ] P3.4 Add micro-benchmark or lightweight perf assertion for mapping throughput.

### Validation

1. `dart analyze`
2. `dart test`
3. Optional local benchmark script (if available)

## Phase 4 - Test matrix expansion

### Unit tests

- [ ] P4.1 `null` -> `ParamValueNull`
- [ ] P4.2 `"null"` string remains string (intentional text, not coerced)
- [ ] P4.3 Unsupported type raises explicit error
- [ ] P4.4 `bool`, `double`, `DateTime` mappings
- [ ] P4.5 bulk insert non-nullable null rejection

### Integration tests

- [ ] P4.6 Insert/select roundtrip for SQL `NULL` via sync service
- [ ] P4.7 Insert/select roundtrip for SQL `NULL` via async service
- [ ] P4.8 Ensure prepared statements preserve null semantics

### Validation

1. `dart analyze`
2. `dart test`
3. `cd native && cargo test -p odbc_engine --lib` (regression confidence)

## Documentation updates

- [ ] D1 Update `doc/TYPE_MAPPING.md`:
  - explicit unsupported-type policy (no silent `toString()`)
  - explicit null semantics
- [ ] D2 Update `README.md`:
  - practical guidance for passing `null` and avoiding SQL string interpolation
- [ ] D3 Update `doc/TROUBLESHOOTING.md`:
  - section: “Why was `"null"` saved as text?”

## Acceptance criteria (DoD)

1. No silent unknown-type fallback to text in parameter mapping.
2. `null` is persisted as SQL `NULL` in parameterized paths.
3. Non-nullable bulk columns reject `null` at build time.
4. All new/updated tests pass.
5. Canonical docs reflect implemented behavior.

## Affected files (expected)

- `lib/infrastructure/native/protocol/param_value.dart`
- `lib/infrastructure/repositories/odbc_repository_impl.dart`
- `lib/infrastructure/native/protocol/bulk_insert_builder.dart`
- `test/infrastructure/native/protocol/param_value_test.dart`
- `test/infrastructure/native/protocol/bulk_insert_builder_test.dart`
- `doc/TYPE_MAPPING.md`
- `doc/TROUBLESHOOTING.md`
- `README.md`

## Risks and mitigations

1. Behavior change for callers relying on implicit `toString()`:
   - Mitigation: explicit error message + migration note + clear changelog entry.
2. Cross-driver differences for `DateTime` textual representation:
   - Mitigation: keep explicit wrapper escape hatch via `ParamValueString` or dedicated type in future phase.
3. Bulk insert users depending on current silent defaults:
   - Mitigation: fail-fast with precise diagnostics to prevent data corruption.
