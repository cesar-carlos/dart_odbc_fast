# Type Mapping Strategy

**Canonical reference** for data type mapping in `odbc_fast`.

> Working document under `doc/notes/`. Implementation status is marked
> next to each section. When in doubt, the source of truth is the code
> referenced inline.

**Last verified against code:** 2026-04-24 (Unreleased; DRT1 RowCount-first fix, Oracle *ref cursor* docs, DRT1 + `MULT` + `OUT1`, columnar v2 decode *hints*, certification table)

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

Code: `lib/infrastructure/native/protocol/param_value.dart` (the
`SqlDataType` class for definitions, `_toTypedParamValue` for the
dispatcher).

**30 kinds shipped** in `SqlDataType` (roadmap complete for the
explicit-typing layer):

#### Cross-engine kinds (20)

| Kind                                  | Accepts                            | Wire                  | Notes                                              |
| ------------------------------------- | ---------------------------------- | --------------------- | -------------------------------------------------- |
| `SqlDataType.int32`                   | `int` (32-bit range)               | `ParamValueInt32`     | Range-validated.                                   |
| `SqlDataType.int64`                   | `int`                              | `ParamValueInt64`     | Always 64-bit.                                     |
| `SqlDataType.smallInt` *(new)*        | `int` ∈ `[-32768, 32767]`          | `ParamValueInt32`     | Range-validated; wire shared with int32.            |
| `SqlDataType.bigInt` *(new)*          | `int`                              | `ParamValueInt64`     | Idiomatic alias for `int64` — wire-equality pinned by test. |
| `SqlDataType.tinyInt` *(new)*         | `int` ∈ `[0, 255]`                 | `ParamValueInt32`     | Unsigned, SQL Server / Sybase convention.          |
| `SqlDataType.bit` *(new)*             | `bool` OR `int` ∈ `{0, 1}`         | `ParamValueInt32`     | Idiomatic for `BIT` columns; rejects `int` outside `{0, 1}`. |
| `SqlDataType.boolAsInt32`             | `bool`                             | `ParamValueInt32`     | Same wire as `bit`, but rejects `int` for type discipline. |
| `SqlDataType.decimal({precision, scale})` | `num` or `String`              | `ParamValueDecimal`   | Optional precision/scale metadata.                 |
| `SqlDataType.money` *(new)*           | `num` or `String`                  | `ParamValueDecimal`   | Fixed 4-fractional-digit convention (SQL Server `MONEY`); rejects NaN/Infinity. |
| `SqlDataType.varChar({length})`       | `String`                           | `ParamValueString`    | Optional length metadata.                          |
| `SqlDataType.nVarChar({length})`      | `String`                           | `ParamValueString`    | UTF-16 conceptually; same wire (UTF-8).            |
| `SqlDataType.text` *(new)*            | `String`                           | `ParamValueString`    | No length cap (`TEXT` / `NTEXT` / `CLOB` convention). |
| `SqlDataType.json({validate})`        | `String`, `Map<String,dynamic>`, `List<dynamic>` | `ParamValueString` | `validate: true` uses kind `json_validated` and round-trips through `jsonDecode`. |
| `SqlDataType.xml({validate})` *(new)* | `String`                           | `ParamValueString`    | `validate: true` runs a cheap structural shape check (`<...>`). |
| `SqlDataType.uuid` *(new)*            | `String` (canonical / bare-hex / `{...}`) | `ParamValueString` | Folds to lowercase canonical 8-4-4-4-12.   |
| `SqlDataType.varBinary({length})`     | `List<int>`                        | `ParamValueBinary`    | Optional length metadata.                          |
| `SqlDataType.dateTime`                | `DateTime` or `String`             | `ParamValueString`    | `DateTime` validated for year ∈ `[1, 9999]`.       |
| `SqlDataType.date`                    | `String`                           | `ParamValueString`    | Caller formats as the engine expects.              |
| `SqlDataType.time`                    | `String`                           | `ParamValueString`    | Caller formats as the engine expects.              |
| `SqlDataType.interval`                | `Duration` or `String`              | `ParamValueString`    | `Duration` → `'<n> seconds'` (broadly portable). |
| `SqlDataType.intervalYearToMonth`     | `String`, `List<int>` length 2 `[y,m]`, or `Map` with `years` / `months` | `ParamValueString` | `INTERVAL 'y-m' YEAR TO MONTH`; months in list/map form are validated `0..11`. |

#### Engine-specific kinds (8)

These wrap the same wire primitives as the cross-engine kinds; the
value lives in the per-kind validation and the type-discipline at the
call site. **Several require the caller to wrap the parameter in a
CAST or constructor function inside the SQL itself** — see each kind's
doc comment in `param_value.dart` for the convention.

| Kind                            | Engine        | Accepts                                   | Caveat                                                           |
| ------------------------------- | ------------- | ----------------------------------------- | ---------------------------------------------------------------- |
| `SqlDataType.range`             | PostgreSQL    | `String` (`'[1,10)'`, `'empty'`, etc.)    | Concrete range subtype resolved by the server.                   |
| `SqlDataType.cidr`              | PostgreSQL    | `String` (IPv4/IPv6, optional `/prefix`)  | Validated structurally (compressed `::` form OK; `:::` rejected); mask range enforced (`/0..32` IPv4, `/0..128` IPv6). |
| `SqlDataType.tsvector`          | PostgreSQL    | `String` (`'fat:1A cat:2B sat:3'`)        | No client-side validation; `to_tsvector` is the real validator.  |
| `SqlDataType.hierarchyId`       | SQL Server    | `String` (`'/1/2/3.5/'`)                  | Path validated; **caller wraps in `CAST(? AS hierarchyid)`** in the SQL. |
| `SqlDataType.geography`         | SQL Server    | `String` (WKT)                            | **Caller wraps in `geography::STGeomFromText(?, srid)`**. `List<int>` rejected with hint pointing at `varBinary` + `STGeomFromWKB`. |
| `SqlDataType.geometry`          | SQL Server    | `String` (WKT)                            | **Caller wraps in `geometry::STGeomFromText(?, srid)`** (planar). Same WKT wire rules as `geography`. |
| `SqlDataType.raw`                | Oracle        | `List<int>`                               | Wire-equality pinned with `varBinary`; idiomatic alias for `RAW(N)` columns. |
| `SqlDataType.bfile`             | Oracle        | `String` (`BFILENAME(...)` snippet)       | BFILE is a pointer to an external file; the more common pattern is two `varChar` parameters fed into `BFILENAME(?, ?)` in SQL. |

Wrapper: `SqlTypedValue({required type, required value})`. Convenience
factory: `typedParam(type, value)`.

Example:

```dart
final params = [
  typedParam(SqlDataType.decimal(precision: 18, scale: 4), '123.4500'),
  typedParam(SqlDataType.nVarChar(length: 64), 'hello'),
  typedParam(SqlDataType.bit, true),
  typedParam(SqlDataType.uuid, '550E8400-E29B-41D4-A716-446655440000'),
  typedParam(SqlDataType.json(validate: true),
      <String, dynamic>{'name': 'Alice', 'roles': ['admin']}),
  typedParam(SqlDataType.interval, const Duration(hours: 1, minutes: 30)),
];
await service.executeQueryParams(connId, sql, params);
```

The dispatcher validates the runtime type against the requested kind
and rejects mismatches with `ArgumentError` (e.g. `SqlDataType.int32`
with a `String` value, or `SqlDataType.uuid` with a malformed string).

**Directional binding:** `ParamDirection`, `DirectedParam`, `serializeDirectedParams`
(DRT1), and `paramValuesFromDirected` (`lib/.../directed_param.dart`). The
v0/legacy `paramValuesFromDirected` list is **IN-only** (throws for `output` /
`inOut`); `OUT` / `INOUT` use DRT1 and
`IOdbcService.executeQueryDirectedParams` (see §3.1).

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

## 3. Result parameters & columnar (MVP in progress)

### 3.1 Output parameters (MVP)

**Wire — DRT1:** [native `bound_param`][bound_param] / Dart
`serializeDirectedParams` / `drt1MagicBytes`: `DRT1` + u32 count + repeated
`(u8 direction)(ParamValue)`.

**Execution:** the Rust engine can decode DRT1 and, when a slot is not
`input`, use `odbc_api` with `In` / `Out` / `InOut` style binding (integer,
text, and `NULL` as integer-output shell; see
`output_aware_params.rs`). Unsupported combinations return `ValidationError`
messages that start with the stable prefix `DIRECTED_PARAM|` and a
machine-readable *slug* (e.g. `binary_out_inout_not_implemented: …`
for `ParamValue::Binary` in `Out` / `InOut`). Legacy v0 (concatenated
`ParamValue` only) is unchanged for existing callers.

**Dart API:** `IOdbcService.executeQueryDirectedParams` and
`IOdbcRepository.executeQueryParamBuffer` (raw buffer). The binary result is
decoded according to which magic appears first:

- **Single result set** (common case — `SQLMoreResults` yielded no extra items):
  buffer starts with the **ODBC magic** (`0x4F444243`), optional `OUT1` footer;
  `QueryResult.outputParamValues` is populated when `OUT1` is present.
- **Multiple result sets / row-counts** (`SQLMoreResults` produced additional
  items after the first): buffer starts with the **MULT magic** (`0x544C554D`)
  followed by `OUT1`. The Dart repository distinguishes two sub-cases:
  - **ResultSet-first** (procedure starts with a `SELECT`): item[0] is
    a `ResultSet`; it maps to `QueryResult.columns` / `rows` / `rowCount`,
    and remaining items appear in `QueryResult.additionalResults`.
  - **RowCount-first** (DML-first procedure, no initial cursor): item[0] is
    a `RowCount`; the primary `QueryResult` fields are left empty (`columns =
    []`, `rows = []`, `rowCount = 0`) and **all** logical items (including
    item[0]) are surfaced in `QueryResult.additionalResults` so no information
    is lost. Callers should inspect `additionalResults` when
    `QueryResult.columns` is empty after a directed call.

  All additional items surface as `DirectedResultItem` or `DirectedRowCountItem`.
  See `test/e2e/mssql_directed_out_multi_rset_test.dart`
  (`E2E_MSSQL_DIRECTED_OUT_MULTI=1`) for the SQL Server opt-in E2E and
  `test/infrastructure/repositories/odbc_repository_directed_rowcount_first_test.dart`
  for the unit-level contract.

`paramValuesFromDirected` remains **v0, input only** (throws for `output` /
`inOut` so callers that want mixed directions use DRT1).

[bound_param]: ../../native/odbc_engine/src/protocol/bound_param.rs

| Engine / host | `OUT` / `INOUT` (DRT1) — current expectation |
| ------------- | --------------------------------------------- |
| **SQL Server** (Windows) | `Integer`, `BigInt`, `String`, non-empty `Decimal` text; `Out`+`Null` still maps to the integer *shell*; wide `VarWChar` for text. **Best-validated** in CI/E2E when DSN is set. |
| **SQL Server** (non-Windows) | Same wire / bind shape with narrow `VarChar` for text; same limits as the engine. |
| **PostgreSQL, MySQL/MariaDB, DB2, Oracle, …** | **Best-effort:** ODBC *may* support the same C-bind shapes for scalars and text; E2E is env-gated. Failures are usually driver-specific (`ValidationError` from bind or from the DSN path). **Do not** assume parity with SQL Server without testing your driver. **PostgreSQL *runtime* check** (DRT1 + `OUT1`): `test/e2e/postgres_directed_out_test.dart` with `E2E_PG_DIRECTED_OUT=1` and `ODBC_TEST_DSN` (PG 11+; host + local ODBC, not the Rust-only Docker `test-runner`). |
| **All** | `Binary` in `Out` / `InOut` is **rejected in-engine** (clear `DIRECTED_PARAM|binary_out_inout_not_implemented:…`). `ParamValue::RefCursorOut` on **non-Oracle** DSNs: `DIRECTED_PARAM|ref_cursor_out_oracle_only:…` (§3.1.1). |

**Dart** pre-validates the same *slugs* as the engine for impossible shapes
(see [directed_param.dart](../../lib/infrastructure/native/protocol/directed_param.dart)
`validateDirectedOutInOut`) before the DRT1 buffer is sent.

**Wire (§3.1.1a):** `ParamValue` tag `6` = `RefCursorOut` (zero-length payload).
Materialized ref-cursor row sets are in a native `RC1\0` trailer (repeated full
v1 row-major messages, one *blob* per `RefCursorOut` in bound order). The Dart
[BinaryProtocolParser](../../lib/infrastructure/native/protocol/binary_protocol.dart)
fills [QueryResult.refCursorResults](../../lib/domain/entities/query_result.dart) when
an `RC1\0` block is present. **Engine — `OUT1` (escalares):** the trailer lists
`OUT` / `INOUT` *scalar* (and text) parameters **only** — no entry for
`ParamValue::RefCursorOut` (cursors are only in `RC1\0`). **Engine — Oracle:** when
the active driver plugin is **Oracle** and the request includes
`ParamValue::RefCursorOut`, the engine strips the corresponding `?` from the
call text (Oracle ODBC: ref-cursor parameters are not bound; result sets are read
from the same statement with `SQLMoreResults`). Non-Oracle DSNs return
`DIRECTED_PARAM|ref_cursor_out_oracle_only:…`. A *defensive* call to
`bound_to_slots` *with* `RefCursorOut` (without the Oracle *path* filter) still
fails with `DIRECTED_PARAM|ref_cursor_out_bind_not_enabled:…` (not the *happy* path).

**Not in scope (unless product priorities change):** TVP, exhaustive
`SqlDataType`-driven *capability* errors for every output SQL type, and
**field certification** of every ODBC stack (Instant Client *x.y*, thick *vs.*
thin, etc.) — the engine already implements the Oracle ODBC **omit-`?` +
`SQLMoreResults`** *pattern* (not a *scalar* `SQLBindParameter` for
`REF CURSOR`); validate your driver against the table below and
[REF_CURSOR_ORACLE_ROADMAP.md](REF_CURSOR_ORACLE_ROADMAP.md) *Tarefas em aberto*.

| Certification (fill in for your org) | Driver / version | DSN / host | `CALL` + `OUT SYS_REFCURSOR` smoke | Notes |
| ------------------------------------ | ---------------- | ---------- | ----------------------------------- | ----- |
| *Example row* | Oracle Instant Client ODBC 19+ | *local* | `e2e_oracle_ref_cursor_test` + `E2E_ORACLE_REFCURSOR=1` | See crate *test*; not default CI. |
| | | | | Add rows after you validate. |

### 3.1.1 Oracle `REF CURSOR` and cursor-like `OUT` (engine + wire + client)

[REF_CURSOR_ORACLE_ROADMAP.md](REF_CURSOR_ORACLE_ROADMAP.md) documents the
**Oracle Database ODBC** behaviour: *omit* the `?` for each `ParamValue::RefCursorOut`
in the `{ CALL … }` text, *bind* only the remaining parameters, *execute*, then
read **one result set per ref cursor** from the first `execute` *cursor* (if
any) and from `SQLMoreResults`, in *procedure* order, materializing into v1
*blobs* for `RC1\0` after `OUT1`. **This is not** a *scalar* `SQLBindParameter`
*REF CURSOR* bind as on SQL Server.

**Remaining gaps (maturity, not the core *happy path*):** *driver* certification
(add rows in the table above), *edge* PL/SQL (*procedures* with intermediate row
counts / *No_Data* *result sets* — see *Tarefas em aberto* in the roadmap), and
broadening the opt-in *integration* `e2e_oracle_ref_cursor_test` if regressions
appear (the test exists; CI *ubuntu* does not run it by default).

### 3.2 Columnar protocol v2 (decode path)

- **Emitter:** `ColumnarEncoder` in the Rust engine (opt-in
  `with_columnar` on the query pipeline) — v2 header in
  [columnar_encoder.rs][colenc].
- **Dart:** `BinaryProtocolParser.parse` / `parseWithOutputs` accept **v2**
  (row-major and columnar) and optional `OUT1` after the main message.
  **Compressed** column blocks call the same decompressors as the engine via
  the native FFI `odbc_columnar_decompress` (see
  `lib/.../columnar_decompress_ffi.dart`); if the library is missing *or* the
  payload is invalid, parsing fails with a [FormatException] whose message
  includes **hints** (algorithm ids, *build* *path* for `odbc_engine`, pointer
  to [columnar_protocol_sketch](columnar_protocol_sketch.md)). Uncompressed
  columnar and v1 are unchanged.

- **Sketch:** [columnar_protocol_sketch.md](columnar_protocol_sketch.md).
- **Heuristic:** `lib/infrastructure/native/protocol/columnar_v2_flags.dart` —
  `columnarV2Magic`, `isLikelyColumnarV2Header`.

[colenc]: ../../native/odbc_engine/src/protocol/columnar_encoder.rs

---

## Non-goals (current release line)

- No parity with the full `node-mssql` `request.output` surface — only the
  DRT1 + `OUT1` + repository/service flow above; not every ODBC output type.
- Do not claim `TVP` (table-valued parameters) support.
- Do not use `doc/api/` generated artifacts as source of truth for
  roadmap commitments.

---

## References

- `doc/Features/PENDING_IMPLEMENTATIONS.md` — backlog mínimo (PT).
- `doc/CAPABILITIES_v3.md` — capability × engine matrix.
- `doc/notes/columnar_protocol_sketch.md` — v2 wire layout and history (§3.2).
- <https://www.npmjs.com/package/mssql>
- <https://github.com/tediousjs/node-mssql>
