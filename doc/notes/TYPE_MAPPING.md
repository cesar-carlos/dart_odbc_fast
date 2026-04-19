# Type Mapping Strategy

**Canonical reference** for data type mapping in `odbc_fast`.

> Working document under `doc/notes/`. Implementation status is marked
> next to each section. When in doubt, the source of truth is the code
> referenced inline.

**Last verified against code:** 2026-04-18 (v3.1.0)

---

## 1. Implemented today

### 1.1 Input parameters (Dart → native)

Six concrete `ParamValue` subclasses with a stable wire tag:

| Class               | Wire tag | Payload                                |
| ------------------- | -------- | -------------------------------------- |
| `ParamValueNull`    | `0`      | empty                                  |
| `ParamValueString`  | `1`      | UTF-8 bytes                            |
| `ParamValueInt32`   | `2`      | 4 bytes little-endian signed           |
| `ParamValueInt64`   | `3`      | 8 bytes little-endian signed           |
| `ParamValueDecimal` | `4`      | UTF-8 string payload (e.g. `"123.45"`) |
| `ParamValueBinary`  | `5`      | raw bytes                              |

Code: `lib/infrastructure/native/protocol/param_value.dart`,
`native/odbc_engine/src/protocol/param_value.rs`.

#### Auto-conversion (`paramValuesFromObjects` / `toParamValue`)

| Dart input              | Result                                                        |
| ----------------------- | ------------------------------------------------------------- |
| `null`                  | `ParamValueNull`                                              |
| `int` ∈ 32-bit range    | `ParamValueInt32`                                             |
| `int` outside 32-bit    | `ParamValueInt64`                                             |
| `String`                | `ParamValueString`                                            |
| `List<int>` / `Uint8List` | `ParamValueBinary`                                          |
| `bool`                  | `ParamValueInt32(1\|0)`                                       |
| `double`                | `ParamValueDecimal(value.toStringAsFixed(6))`                 |
| `DateTime`              | `ParamValueString(value.toUtc().toIso8601String())`           |
| `ParamValue`            | returned as-is (fast path)                                    |
| `SqlTypedValue`         | dispatched to typed conversion (see §1.3)                     |

Validation:

- `double.NaN` and `double.infinity` are rejected with `ArgumentError`.
- `DateTime.year` must be in `[1, 9999]` — otherwise `ArgumentError`.
- Anything else throws `ArgumentError` with an actionable message
  (no silent `toString()` fallback).

### 1.2 Result decoding (native → Dart)

Binary protocol **version 1**, magic `"ODBC"` (`0x4F444243`). Header is
16 bytes; payload follows.

Code: `lib/infrastructure/native/protocol/binary_protocol.dart`,
`native/odbc_engine/src/protocol/types.rs`,
`lib/infrastructure/native/protocol/odbc_type.dart`.

`OdbcType` enum (Rust + Dart, kept in lockstep) has **19 variants**
with stable discriminants 1..19:

| #  | Variant            | Decoder return         | Notes                                  |
| -- | ------------------ | ---------------------- | -------------------------------------- |
| 1  | `varchar`          | `String` (UTF-8)       | default text path                      |
| 2  | `integer`          | `int`                  | 4 bytes little-endian                  |
| 3  | `bigInt`           | `int`                  | 8 bytes little-endian                  |
| 4  | `decimal`          | `String`               | preserves precision                    |
| 5  | `date`             | `String` (ISO-8601)    | `YYYY-MM-DD`                           |
| 6  | `timestamp`        | `String` (ISO-8601)    | `YYYY-MM-DD HH:MM:SS[.fff]`            |
| 7  | `binary`           | `Uint8List`            | raw bytes                              |
| 8  | `nVarchar`         | `String` (UTF-8)       | wide-char source                       |
| 9  | `timestampWithTz`  | `String` (ISO-8601)    | with offset                            |
| 10 | `datetimeOffset`   | `String` (ISO-8601)    | SQL Server `datetimeoffset`            |
| 11 | `time`             | `String`               | `HH:MM:SS[.fff]`                       |
| 12 | `smallInt`         | `String`               | encoded as text on the wire            |
| 13 | `boolean`          | `String`               | `"true"` / `"false"`                   |
| 14 | `float`            | `String`               | text-formatted                         |
| 15 | `doublePrecision`  | `String`               | text-formatted                         |
| 16 | `json`             | `String`               | raw JSON text                          |
| 17 | `uuid`             | `String`               | RFC 4122 hyphenated                    |
| 18 | `money`            | `String`               | preserves precision                    |
| 19 | `interval`         | `String`               | engine-specific format                 |

Unknown discriminants degrade to `OdbcType.varchar` (forward compatible).

Decoder rules in `binary_protocol.dart::_convertData`:

- `binary` → `Uint8List`
- `integer`, `bigInt` → `int` (LE) with text fallback for short payloads
- everything else → `String` (UTF-8 with `String.fromCharCodes` fallback
  for invalid UTF-8, mirroring the loose pre-v3.0 behaviour for compat).

### 1.3 Optional explicit SQL typing (`SqlDataType`)

Opt-in typed parameters layered on top of `ParamValue`. Existing untyped
calls continue to work unchanged.

Code: `lib/infrastructure/native/protocol/param_value.dart` (lines 61-113
for definitions, 297-379 for the `_toTypedParamValue` dispatcher).

Available kinds (10):

- `SqlDataType.int32`
- `SqlDataType.int64`
- `SqlDataType.decimal({precision, scale})`
- `SqlDataType.varChar({length})`
- `SqlDataType.nVarChar({length})`
- `SqlDataType.varBinary({length})`
- `SqlDataType.dateTime`
- `SqlDataType.date`
- `SqlDataType.time`
- `SqlDataType.boolAsInt32`

Wrapper: `SqlTypedValue({required type, required value})`. Convenience
factory: `typedParam(type, value)`.

Example:

```dart
final params = [
  typedParam(SqlDataType.decimal(precision: 18, scale: 4), '123.4500'),
  typedParam(SqlDataType.nVarChar(length: 64), 'hello'),
  typedParam(SqlDataType.boolAsInt32, true),
];
await service.executeQueryParams(connId, sql, params);
```

The dispatcher validates the runtime type against the requested kind
and rejects mismatches with `ArgumentError` (e.g. `SqlDataType.int32`
with a `String` value).

### 1.4 Driver plugins (9 total)

Each plugin opts into capability traits (`BulkLoader`, `Upsertable`,
`Returnable`, `TypeCatalog`, `IdentifierQuoter`, `CatalogProvider`,
`SessionInitializer`) — see `doc/CAPABILITIES_v3.md` for the matrix.

| Plugin                                            | Engine id    | Notes                                     |
| ------------------------------------------------- | ------------ | ----------------------------------------- |
| `native/odbc_engine/src/plugins/sqlserver.rs`     | `sqlserver`  | MERGE, OUTPUT, brackets quoting           |
| `native/odbc_engine/src/plugins/postgres.rs`      | `postgres`   | ON CONFLICT, RETURNING, COPY              |
| `native/odbc_engine/src/plugins/mysql.rs`         | `mysql`      | ON DUPLICATE KEY UPDATE, LOAD DATA, backtick |
| `native/odbc_engine/src/plugins/mariadb.rs`       | `mariadb`    | RETURNING (MariaDB-only), backtick, UUID  |
| `native/odbc_engine/src/plugins/oracle.rs`        | `oracle`     | MERGE, RETURNING INTO, FETCH FIRST        |
| `native/odbc_engine/src/plugins/sybase.rs`        | `sybase_*`   | sysobjects catalog, ASA/ASE detection     |
| `native/odbc_engine/src/plugins/sqlite.rs`        | `sqlite`     | ON CONFLICT, RETURNING, sqlite_master     |
| `native/odbc_engine/src/plugins/db2.rs`           | `db2`        | MERGE, FROM FINAL TABLE, SYSCAT           |
| `native/odbc_engine/src/plugins/snowflake.rs`     | `snowflake`  | MERGE, RETURNING, VARIANT/OBJECT/ARRAY    |

Engines without a dedicated plugin (Redshift, BigQuery, MongoDB) fall
back to the generic SQL-92 path. The canonical ids are listed in
`engine::core::ENGINE_*`.

### 1.5 Bulk insert nullability

`BulkInsertBuilder.addRow()` validates non-nullable columns up front:

- Throws `StateError` when a column declared `nullable: false` receives
  a `null` value.
- Error message includes column name and row number.
- Suggests using `nullable: true` for columns that should accept null.
- Nullable columns continue to use the null bitmap correctly.

`build()` keeps a final nullability guard because `addRow()` stores row
list references for performance; caller code may still mutate rows
before `build()`.

### 1.6 Bulk insert type and text validation

Per-column validation in `BulkInsertBuilder.addRow()`:

- `i32`: requires `int` in 32-bit range
- `i64`: requires `int`
- `text`: requires `String`, with `maxLen` validated by **both** char
  count and UTF-8 byte length
- `decimal`: requires `String` or `num`
- `binary`: requires `List<int>` / `Uint8List`
- `timestamp`: requires `DateTime` or `BulkTimestamp`

Unicode edge cases (emoji and combining characters) are covered by
tests under `test/infrastructure/native/protocol/`.

---

## 2. Inspirations (not claimed as implementation)

### `node-mssql`

`node-mssql` provides:

- `request.input(name, [type], value)`
- `request.output(name, type[, value])`
- automatic JS-to-SQL mapping when type is omitted
- common mapping `String → NVarChar`, `Number → Int`, `Boolean → Bit`,
  `Date → DateTime`, `Buffer → VarBinary`, `Table → TVP`

We borrowed the auto-conversion idea (§1.1) and the typed-parameter
pattern (§1.3). We **do not** claim parity with the full `node-mssql`
surface — TVP and `request.output` are explicitly out of scope today
(see §3.1).

---

## 3. Roadmap (not implemented)

### 3.1 Output parameters

Not supported in the public Dart API. No `request.output`-style
contract currently exists.

Planning baseline:

| Driver     | Typical capability                           | Status                      |
| ---------- | -------------------------------------------- | --------------------------- |
| SQL Server | `OUTPUT` parameters and return values        | Planned (not implemented)   |
| Oracle     | OUT params / REF CURSOR patterns             | Planned (not implemented)   |
| PostgreSQL | Function returns / OUT-like patterns         | Planned (not implemented)   |
| Sybase     | OUTPUT-like support varies by driver         | Planned (not implemented)   |

Decision criteria before promoting to public API:

1. Stable cross-driver behavioural contract defined.
2. Error semantics standardised (nulls, missing params, unsupported types).
3. Integration coverage for each claimed driver capability.
4. Non-breaking API surface with explicit feature flag/label while
   experimental.
5. Documentation and examples updated before promotion.

### 3.2 Columnar protocol v2

The original sketch lived in `lib/infrastructure/native/protocol/columnar_protocol.dart`
and was orphan code (no callers in `lib/` or `test/`). Moved to
`doc/notes/columnar_protocol_sketch.md` in v3.1.0 to preserve the design
without keeping dead code in the production tree. Revive only if there
is a concrete throughput requirement that the row-major v1 protocol
cannot meet.

---

## Non-goals (current release line)

- Do not claim `request.output`-style support in the public API until §3.1
  ships.
- Do not claim `TVP` (table-valued parameters) support.
- Do not use `doc/api/` generated artifacts as source of truth for
  roadmap commitments.

---

## References

- `doc/notes/FUTURE_IMPLEMENTATIONS.md` — open backlog items.
- `doc/CAPABILITIES_v3.md` — capability × engine matrix.
- `doc/notes/columnar_protocol_sketch.md` — orphaned v2 design (§3.2).
- <https://www.npmjs.com/package/mssql>
- <https://github.com/tediousjs/node-mssql>
