# TYPE_MAPPING_IMPLEMENTATION_CHECKLIST.md

Execution checklist for GAP 6 (Data type mapping parity and canonical contract).

**Last verified against code:** 2026-03-10

> Note: this file is in `doc/notes/` and tracks planned work. Checklist items
> can remain open while implementation is in progress.

## Objective

Ship a clear, testable, and maintainable type mapping contract across Dart and Rust without breaking current public APIs.

## Scope

- Canonicalize current implemented mapping (`ParamValue` + decode behavior).
- Eliminate parser ambiguity (`binary_protocol.dart` vs orphan alternatives).
- Add test coverage that locks documented behavior.
- Define forward-compatible path for richer SQL typing.

## Non-goals (current cycle)

- Do not introduce breaking API changes.
- Do not claim `request.output` support.
- Do not claim full `SqlType` (30+) support until implemented.

## Phase 1 - Canonical contract in docs

- [x] P1.1 Confirm `doc/notes/TYPE_MAPPING.md` reflects real code behavior.
- [x] P1.2 Add explicit link to type mapping in root `README.md` (documentation section).
- [x] P1.3 Add explicit "implemented vs planned" notes in `README.md` type-related sections.
- [x] P1.4 Verify no canonical document references unimplemented `SqlType`/`request.output`.

Acceptance gate:

- `README.md` and `doc/notes/TYPE_MAPPING.md` are consistent.

## Phase 2 - Parser strategy alignment

- [x] P2.1 Decide canonical parser implementation for runtime usage.
- [x] P2.2 If needed, migrate missing conversions into canonical parser:
  - varchar/text
  - int32
  - int64
  - decimal representation
  - date/timestamp representation
  - binary
- [x] P2.3 Deprecate/remove orphan parser path to prevent drift.
- [x] P2.4 Ensure sync, async, repository, wrappers, examples, and tests use the same parser path.

Acceptance gate:

- One parser path is canonical and used everywhere.

## Phase 3 - Test hardening for mapping behavior

- [x] P3.1 Expand Dart tests for `ParamValue` serialization/deserialization invariants.
- [x] P3.2 Add parser tests for all supported type families and null handling.
- [x] P3.3 Add repository-level tests verifying conversion stability from raw protocol to `QueryResult`.
- [x] P3.4 Add regression test asserting documented mapping table matches runtime behavior.

Acceptance gate:

- Mapping behavior is covered by automated tests and matches documentation.

## Phase 4 - Optional API evolution (non-breaking)

- [ ] P4.1 Draft `SqlDataType` proposal (API design note).
- [ ] P4.2 Prototype explicit typed parameter API without breaking `ParamValue`.
- [ ] P4.3 Add migration notes showing old and new usage side by side.
- [ ] P4.4 Keep feature behind clear "experimental/planned" label until stable.

Acceptance gate:

- Optional richer typing can be introduced without breaking current consumers.

## Phase 5 - Output parameter roadmap

- [ ] P5.1 Define driver support matrix (SQL Server/Oracle/Postgres/Sybase).
- [ ] P5.2 Document current unsupported status in canonical docs.
- [ ] P5.3 Define contract decision criteria before implementation.

Acceptance gate:

- No ambiguity about output parameter support status.

## Verification evidence (2026-03-10)

- Canonical docs are aligned:
  - `doc/notes/TYPE_MAPPING.md`
  - `README.md` (section `Type Mapping`)
- Canonical runtime parser path:
  - `lib/infrastructure/native/protocol/binary_protocol.dart`
  - `lib/infrastructure/repositories/odbc_repository_impl.dart`
- Orphan/future parser explicitly marked as non-runtime:
  - `lib/infrastructure/native/protocol/columnar_protocol.dart`
- Automated coverage:
  - `test/infrastructure/native/protocol/param_value_test.dart`
  - `test/infrastructure/native/protocol/binary_protocol_test.dart`

## Validation commands (run after each completed phase)

1. `dart analyze`
2. `dart test`
3. `cd native && cargo test -p odbc_engine --lib`

## Inspiration reference (for API ergonomics only)

- `node-mssql` topic: JS Data Type To SQL Data Type Map
- `input(name, [type], value)` / `output(name, type[, value])`

Reference links:

- https://www.npmjs.com/package/mssql
- https://github.com/tediousjs/node-mssql

