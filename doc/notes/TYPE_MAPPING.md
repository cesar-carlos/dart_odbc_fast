# Type Mapping Strategy

Canonical reference for data type mapping in `odbc_fast`.

> Note: `doc/notes/` contains working documents. Some sections describe planned
> work that is not implemented yet.

This document separates:
1. What is implemented today
2. What is planned
3. What is inspired by `node-mssql` but not yet part of public contract.

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
- `bool` -> `ParamValueInt32(1|0)` (canonical mapping)
- `double` -> `ParamValueDecimal(value.toString())` (canonical mapping)
- `DateTime` -> `ParamValueString(value.toUtc().toIso8601String())` (canonical mapping)
- `ParamValue` -> returned as-is (fast path)

**Important:** Unsupported types throw `ArgumentError` with actionable message.
No silent `toString()` fallback for unsupported types.

### Result decoding (native -> Dart)

Rust internal mapping exists:
- `odbc_api::DataType -> SQL type code`
- `SQL type code -> OdbcType`
- `OdbcType -> Dart type conversion`

Primary reference:
- `native/odbc_engine/src/protocol/types.rs`

Driver-specific type mapping exists via plugins:
- `native/odbc_engine/src/plugins/sqlserver.rs`
- `native/odbc_engine/src/plugins/postgres.rs`
- `native/odbc_engine/src/plugins/oracle.rs`
- `native/odbc_engine/src/plugins/sybase.rs`

Driver detection also recognizes `mysql`, `mongodb`, and `sqlite`, but these
currently use the generic mapping path (no dedicated plugin file yet).

## Bulk insert nullability

Non-nullable columns now validate null values at build time:
- Throws `StateError` when `nullable: false` column contains `null`
- Error message includes column name and row number for easy debugging
- Suggests using `nullable: true` for columns that should accept null
- Nullable columns continue to use null bitmap correctly

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

### Phase 1: Make current behavior explicit (Completed)

1. Keep `ParamValue` as stable contract.
2. Document exact auto-conversion and limitations.
3. Add test coverage to ensure behavior does not drift.
4. **DONE:** Explicit type conversion with canonical mappings for `bool`, `double`, `DateTime`.

### Phase 2: Add optional explicit SQL typing (Not Started)

1. Introduce a public `SqlDataType` model (or equivalent) without breaking `ParamValue`.
2. Allow explicit parameter typing in high-level APIs where useful.
3. Keep backward compatibility for existing `executeQueryParams` and prepared APIs.
4. Enable driver-aware support matrix via configuration.

### Phase 3: Evaluate output parameters (Not Started)

1. Define driver-aware support matrix (`SQL Server`, `Oracle`, etc.).
2. Add stable Dart contract only after cross-driver behavior is validated.
3. Document unsupported paths clearly when applicable.

### Non-goals (current release line)

- Do not claim `SqlType` 30+ support in public API until implemented.
- Do not claim `request.output` support in public API until implemented.
- Do not use `doc/api/` generated artifacts as source of truth for roadmap commitments.

## References

- `doc/notes/TYPE_MAPPING_IMPLEMENTATION_CHECKLIST.md`
- `doc/notes/FUTURE_IMPLEMENTATIONS.md`
- https://www.npmjs.com/package/mssql
- https://github.com/tediousjs/node-mssql

