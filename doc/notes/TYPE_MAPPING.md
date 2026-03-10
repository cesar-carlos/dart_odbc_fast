# Type Mapping Strategy

**Canonical reference** for data type mapping in `odbc_fast`.

> **Note**: This is a working document in `doc/notes/`. Some sections describe planned
> work that is not implemented yet. Implementation status is clearly marked below.

**Last verified**: 2026-03-10

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
- `double` -> `ParamValueDecimal(value.toStringAsFixed(6))` (canonical mapping)
  - `NaN` and `Infinity`/`-Infinity` are rejected with `ArgumentError`
- `DateTime` -> `ParamValueString(value.toUtc().toIso8601String())`
  (canonical mapping)
  - `DateTime.year` must be in `[1, 9999]`, otherwise `ArgumentError`
- `ParamValue` -> returned as-is (fast path)

**Important:** Unsupported types throw `ArgumentError` with actionable message.
No silent `toString()` fallback for unsupported types.

### Result decoding (native -> Dart)

**Current implementation** uses binary protocol (version 1):

Dart parser reference:
- `lib/infrastructure/native/protocol/binary_protocol.dart`

Supported ODBC type codes in binary protocol:
- Type 1: String (UTF-8)
- Type 2: Int32 (little-endian)
- Type 3: Int64 (little-endian)
- Default: String (fallback)

Rust internal mapping:
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

**Future protocol** (not implemented):
- `lib/infrastructure/native/protocol/columnar_protocol.dart` exists but is not
  used by the engine. This is prepared for a future columnar format (version 2)
  with optional compression, but the Rust side does not emit this format yet.

## Bulk insert nullability

Non-nullable columns now validate null values at add time (fail-fast):
- Throws `StateError` when `nullable: false` column contains `null` in `addRow()`
- Error message includes column name and row number for easy debugging
- Suggests using `nullable: true` for columns that should accept null
- Nullable columns continue to use null bitmap correctly

`build()` keeps a final nullability guard because `addRow()` stores row list
references for performance and caller code may still mutate rows before build.

## Bulk insert type and text validation

`BulkInsertBuilder.addRow()` validates value types per column before storing rows:
- `i32`: requires `int` in 32-bit range
- `i64`: requires `int`
- `text`: requires `String` with `maxLen` validation by:
  - character count
  - UTF-8 byte length
- `decimal`: requires `String` or `num`
- `binary`: requires `List<int>` / `Uint8List`
- `timestamp`: requires `DateTime` or `BulkTimestamp`

Unicode edge cases are covered by tests (emoji and combining characters).

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

### Phase 2: Add optional explicit SQL typing (Prototype started)

1. Introduce a public `SqlDataType` model (or equivalent) without breaking `ParamValue`.
2. Allow explicit parameter typing in high-level APIs where useful.
3. Keep backward compatibility for existing `executeQueryParams` and prepared APIs.
4. Enable driver-aware support matrix via configuration.

Prototype status:
- `SqlDataType`, `SqlTypedValue`, and `typedParam(...)` are available in
  `lib/infrastructure/native/protocol/param_value.dart`.
- Existing APIs remain unchanged; typed parameters are opt-in through
  `List<dynamic>`/named parameter values.

### `SqlDataType` proposal (planned)

Status: **planned/experimental**, not implemented in public API yet.

Design goals:
- Keep `ParamValue` as the stable default contract.
- Introduce explicit SQL typing as an opt-in path only.
- Preserve backward compatibility for existing parameter APIs.

Proposed shape (illustrative only):
- `SqlDataType.int32`
- `SqlDataType.int64`
- `SqlDataType.decimal(precision, scale)`
- `SqlDataType.varChar(length)`
- `SqlDataType.nVarChar(length)`
- `SqlDataType.varBinary(length)`
- `SqlDataType.dateTime`
- `SqlDataType.date`
- `SqlDataType.time`

Proposed typed wrapper (illustrative):
- `TypedParam(name: 'amount', type: SqlDataType.decimal(18, 4), value: '123.4500')`

### Migration sketch (planned)

Current (implemented today):
- `executeQueryParams(sql, [ParamValueDecimal('123.45')])`
- `executeQueryNamed(sql, {'amount': 123.45})` (auto-conversion path)

Planned side-by-side (future, non-breaking):
- Keep all current calls valid.
- Add optional typed entry points (or optional typed variants) that accept
  explicit SQL type metadata.
- Keep feature clearly labeled as experimental until cross-driver behavior is
  validated.

### Phase 3: Evaluate output parameters (Not Started)

1. Define driver-aware support matrix (`SQL Server`, `Oracle`, etc.).
2. Add stable Dart contract only after cross-driver behavior is validated.
3. Document unsupported paths clearly when applicable.

## Output parameters roadmap (planned)

Current status:
- Output parameters are **not supported** in the stable public Dart API.
- No `request.output`-style contract is currently implemented.

Driver support matrix (planning baseline):

| Driver | Typical capability | Current package status |
| --- | --- | --- |
| SQL Server | `OUTPUT` params and return values | Planned (not implemented) |
| Oracle | OUT params / REF CURSOR patterns | Planned (not implemented) |
| PostgreSQL | Function returns / OUT-like patterns differ from ODBC OUTPUT style | Planned (not implemented) |
| Sybase | OUTPUT-like support depends on driver behavior | Planned (not implemented) |

Decision criteria before implementation:
1. Stable cross-driver behavioral contract defined.
2. Error semantics standardized (nulls, missing params, unsupported types).
3. Integration coverage for each claimed driver capability.
4. Non-breaking API surface with explicit feature flag/label while experimental.
5. Documentation and examples updated before feature is promoted.

### Non-goals (current release line)

- Do not claim `SqlType` 30+ support in public API until implemented.
- Do not claim `request.output` support in public API until implemented.
- Do not use `doc/api/` generated artifacts as source of truth for roadmap commitments.

## References

- `doc/notes/TYPE_MAPPING_IMPLEMENTATION_CHECKLIST.md`
- `doc/notes/FUTURE_IMPLEMENTATIONS.md`
- https://www.npmjs.com/package/mssql
- https://github.com/tediousjs/node-mssql

