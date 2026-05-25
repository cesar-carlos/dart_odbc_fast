# TVP design gate

This note records the decisions that must be made before adding SQL Server
table-valued parameters (TVP) to the public API. It is intentionally a gate, not
an implementation promise.

## Current status

- TVP is not part of the stable Dart API.
- `SqlDataType` covers typed scalar/binary/text values only; it does not carry
  table schemas or row sets.
- Directed parameters support DRT1 `IN`, scalar/text `OUT` and `INOUT`, plus the
  Oracle-only `ParamValueRefCursorOut` marker.
- `node-mssql` style `request.output` / `request.input` parity is explicitly
  out of scope for the current release line.

## Required decisions before implementation

1. **Scope:** SQL Server-only MVP, or a cross-driver table parameter abstraction
   with non-SQL Server rejection.
2. **Wire format:** extend DRT1 with a TVP `ParamValue` tag, or introduce a new
   frame that can carry table name, user-defined type name, columns and rows.
3. **Schema contract:** decide whether callers pass SQL Server user-defined type
   names, column metadata, or both.
4. **Ownership and memory:** define maximum row/byte sizes, chunking behavior
   and whether the native engine materializes the full TVP before binding.
5. **Driver support:** validate at least Microsoft ODBC Driver 17/18 on Windows
   and Linux before documenting support.
6. **Fallback:** decide whether unsupported drivers fail at serialization,
   bind time, or repository execution with a stable `DIRECTED_PARAM|...` slug.

## Minimum acceptance criteria for a future MVP

- Additive Dart API with no change to existing `ParamValue` wire behavior.
- Native tests for malformed schemas, empty row sets, type mismatch and driver
  rejection.
- At least one opt-in SQL Server E2E that creates a user-defined table type,
  calls a procedure with a TVP and verifies rows received by the procedure.
- Documentation in `TYPE_MAPPING.md`, `CAPABILITIES_v3.md`, examples and
  `CHANGELOG.md`.

Until these decisions are closed, keep TVP listed as product-gated work in
`doc/Features/PENDING_IMPLEMENTATIONS.md`.
