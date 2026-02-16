# Type Mapping Strategy

Canonical reference for data type mapping in `odbc_fast`.

This document separates:

1. what is implemented today,
2. what is planned,
3. and what is inspired by `node-mssql` but not yet part of the public contract.

## Current implemented contract

### Input parameters (Dart -> native)

Implemented parameter types in Dart:

- `ParamValueNull`
- `ParamValueString`
- `ParamValueInt32`
- `ParamValueInt64`
- `ParamValueDecimal` (string payload)
- `ParamValueBinary`

Primary code references:

- `lib/infrastructure/native/protocol/param_value.dart`
- `native/odbc_engine/src/protocol/param_value.rs`

Current object-to-parameter auto-conversion (`paramValuesFromObjects`):

- `null` -> `ParamValueNull`
- `int` in 32-bit range -> `ParamValueInt32`
- `int` outside 32-bit range -> `ParamValueInt64`
- `String` -> `ParamValueString`
- `List<int>` -> `ParamValueBinary`
- any other type -> `ParamValueString(value.toString())`

Important: this means values such as `bool`, `double`, and `DateTime` are currently stringified unless explicitly wrapped.

### Result decoding (native -> Dart)

Rust internal mapping exists:

- `odbc_api::DataType -> SQL type code`
- `SQL type code -> OdbcType`

Primary reference:

- `native/odbc_engine/src/protocol/types.rs`

Driver-specific type remapping exists via plugins:

- `native/odbc_engine/src/plugins/sqlserver.rs`
- `native/odbc_engine/src/plugins/postgres.rs`
- `native/odbc_engine/src/plugins/oracle.rs`
- `native/odbc_engine/src/plugins/sybase.rs`

## Inspiration from node-mssql

`node-mssql` provides a convenient API around:

- `input(name, [type], value)`
- `output(name, type[, value])`
- automatic JS-to-SQL mapping when type is omitted

The common mapping in that ecosystem is:

- `String` -> `NVarChar`
- `Number` -> `Int`
- `Boolean` -> `Bit`
- `Date` -> `DateTime`
- `Buffer` -> `VarBinary`
- `Table` -> `TVP`

This model is a valid inspiration for `odbc_fast`, but it is not yet the current Dart public contract.

## Planned implementation direction

### Phase 1: make the current behavior explicit

1. Keep `ParamValue` as the stable contract.
2. Document exact auto-conversion and limitations.
3. Add test coverage to ensure behavior does not drift.

### Phase 2: add optional explicit SQL typing

1. Introduce a public `SqlDataType` model (or equivalent) without breaking `ParamValue`.
2. Allow explicit parameter typing in high-level APIs where useful.
3. Keep backward compatibility for existing `executeQueryParams` and prepared APIs.

### Phase 3: evaluate output parameters

1. Define driver-aware support matrix (`SQL Server`, `Oracle`, etc.).
2. Add stable Dart contract only after cross-driver behavior is validated.
3. Document unsupported paths clearly when applicable.

## Non-goals (current release line)

- Do not claim `SqlType` 30+ support in public API until implemented.
- Do not claim `request.output` support in public API until implemented.
- Do not use `doc/api/` generated artifacts as source of truth for roadmap commitments.

## References

- `doc/notes/GAPS_IMPLEMENTATION_MASTER_PLAN.md` (GAP 6)
- `doc/notes/TYPE_MAPPING_IMPLEMENTATION_CHECKLIST.md`
- https://www.npmjs.com/package/mssql
- https://github.com/tediousjs/node-mssql
