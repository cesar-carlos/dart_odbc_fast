# Driver Capabilities Matrix

> **Last updated for:** v3.5.3 — `doc/CAPABILITIES_v3.md` is the canonical reference for engine capabilities, plugin traits and the capability × engine matrix. For the FFI surface see [API_SURFACE.md](API_SURFACE.md); for type mapping see [notes/TYPE_MAPPING.md](notes/TYPE_MAPPING.md).

Driver-specific behaviour is grouped into seven opt-in
**capability traits** (introduced in v3.0.0, extended through v3.5.x). Each plugin implements only what makes sense for its
engine; the runtime resolves the trait via [`PluginRegistry`](../native/odbc_engine/src/plugins/registry.rs)
or directly through the per-plugin module.

## Traits

| Trait | File | Purpose |
|---|---|---|
| `BulkLoader` | [`plugins/capabilities/bulk_loader.rs`](../native/odbc_engine/src/plugins/capabilities/bulk_loader.rs) | Native bulk insert path (BCP, COPY, LOAD DATA, direct path) |
| `Upsertable` | [`plugins/capabilities/upsert.rs`](../native/odbc_engine/src/plugins/capabilities/upsert.rs) | Build dialect-specific UPSERT SQL |
| `Returnable` | [`plugins/capabilities/returning.rs`](../native/odbc_engine/src/plugins/capabilities/returning.rs) | Append RETURNING / OUTPUT clause |
| `TypeCatalog` | [`plugins/capabilities/type_catalog.rs`](../native/odbc_engine/src/plugins/capabilities/type_catalog.rs) | Extended type mapping using DBMS-specific TYPE_NAME |
| `IdentifierQuoter` | [`plugins/capabilities/quoter.rs`](../native/odbc_engine/src/plugins/capabilities/quoter.rs) | Per-driver identifier quoting style |
| `CatalogProvider` | [`plugins/capabilities/catalog_provider.rs`](../native/odbc_engine/src/plugins/capabilities/catalog_provider.rs) | Dialect-specific schema introspection |
| `SessionInitializer` | [`plugins/capabilities/session_init.rs`](../native/odbc_engine/src/plugins/capabilities/session_init.rs) | Post-connect setup statements |

## Compatibility matrix

| Capability \ Engine | SQL Server | PostgreSQL | MySQL | MariaDB | Oracle | Sybase ASE | SQLite | Db2 | Snowflake |
|---|---|---|---|---|---|---|---|---|---|
| `DriverPlugin` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `BulkLoader` | BCP* | array+COPY** | LOAD DATA** | array+ON DUP | array+APPEND | — | — | — | PUT/COPY** |
| `Upsertable` | MERGE | ON CONFLICT | ON DUPLICATE | ON DUPLICATE | MERGE FROM dual | (unsupported) | ON CONFLICT | MERGE | MERGE |
| `Returnable` | OUTPUT | RETURNING | (unsupported) | RETURNING | RETURNING INTO | (unsupported) | RETURNING | FROM FINAL TABLE | RETURNING |
| `TypeCatalog` | NVARCHAR/MONEY/UUID/DATETIMEOFFSET/JSON | UUID/JSON/JSONB/TZ/INTERVAL/BYTEA | JSON/TINYINT(1)→Bool | JSON/UUID/Bool | TZ/INTERVAL/CLOB/BLOB/NVARCHAR2 | MONEY/NVARCHAR/IMAGE/Bool | TEXT/INTEGER/REAL/BLOB | GRAPHIC/CLOB/BLOB/XML | VARIANT/OBJECT/ARRAY/TZ |
| `IdentifierQuoter` | `[name]` | `"name"` | `` `name` `` | `` `name` `` | `"NAME"` | `[name]` | `"name"` | `"name"` | `"name"` |
| `CatalogProvider` | sys.* DMVs | INFORMATION_SCHEMA | INFORMATION_SCHEMA | INFORMATION_SCHEMA | ALL_TABLES/USER_TABLES | sysobjects | sqlite_master + pragma_* | SYSCAT.* | INFORMATION_SCHEMA |
| `SessionInitializer` | ARITHABORT/CONCAT_NULL_YIELDS_NULL | application_name/TIME ZONE/search_path | NAMES utf8mb4/time_zone/USE | NAMES/time_zone/USE | NLS_DATE_FORMAT/NLS_TIMESTAMP_FORMAT/NLS_NUMERIC | QUOTED_IDENTIFIER/CHAINED OFF | foreign_keys/journal_mode/synchronous PRAGMAs | SET CURRENT SCHEMA | TIMEZONE/USE SCHEMA/QUERY_TAG |

\* BCP via `sqlncli11.dll`/`msodbcsql17/18.dll` (Windows-only feature `sqlserver-bcp`, gated by env `ODBC_ENABLE_UNSTABLE_NATIVE_BCP=1`). Currently supports `I32` and `I64` types; extending to Text/Binary/Timestamp/Decimal is tracked for v3.1.
\** Native streaming paths (`COPY FROM STDIN BINARY`, `LOAD DATA LOCAL INFILE`, Snowflake `PUT/COPY INTO`) are tracked for v3.1. v3.0 uses optimised array-binding INSERT under `BulkLoader`.

## Transaction control matrix (released in v3.4.0)

| Capability \ Engine                | SQL Server   | PostgreSQL   | MySQL / MariaDB | Oracle        | DB2          | SQLite       | Snowflake    |
| ---------------------------------- | ------------ | ------------ | --------------- | ------------- | ------------ | ------------ | ------------ |
| Isolation levels (`SET TRANSACTION`) | full | full | full | RC + SER only† | UR/CS/RS/RR | PRAGMA‡ | skip§ |
| Savepoints (`SAVEPOINT` / `SAVE TRANSACTION`) | full (SQL Server dialect) | SQL-92 | SQL-92 | SQL-92 | SQL-92 | SQL-92 | SQL-92 |
| `TransactionAccessMode.readOnly` (Sprint 4.1) | no-op¶ | `SET TRANSACTION READ ONLY` | `SET TRANSACTION READ ONLY` | `SET TRANSACTION READ ONLY` | `SET TRANSACTION READ ONLY` | no-op¶ | no-op¶ |
| `LockTimeout` (Sprint 4.2) | `SET LOCK_TIMEOUT <ms>` | `SET LOCAL lock_timeout = '<ms>ms'` | `SET SESSION innodb_lock_wait_timeout = <s>`# | (per-statement only) | `SET CURRENT LOCK TIMEOUT <s>`# | `PRAGMA busy_timeout = <ms>` | (statement timeout, not lock) |
| `runInTransaction<T>` (Sprint 4.4) | universal — pure Service-layer wrapper around the matrix above; works on every engine | — | — | — | — | — | — |
| **XA / 2PC** (Sprint 4.3) | ✅ MSDTC + XA branch (Windows, `--features xa-dtc`)** | ✅ `PREPARE TRANSACTION` + `pg_prepared_xacts` | ✅ `XA START / END / PREPARE / COMMIT / RECOVER` | ⚠️ scaffolding†† | ✅ same SQL grammar as MySQL | ❌ no 2PC | ❌ no 2PC |

† Oracle: only `READ COMMITTED` and `SERIALIZABLE` are valid per
`SET TRANSACTION ISOLATION LEVEL`; the other two levels are rejected
with `ValidationError`.
‡ SQLite: `PRAGMA read_uncommitted = 0|1` is the closest equivalent.
§ Snowflake: per-transaction isolation isn't supported; the `SET` is
silently skipped and logged at debug.
¶ SQL Server / SQLite / Snowflake have no native `READ ONLY` hint;
the call is a logged no-op so callers can program against the
abstraction unconditionally.
\# MySQL/MariaDB and DB2 express waits in *seconds*; sub-second
millisecond values **round UP to 1 second** so the caller's bound is
never silently relaxed.
\*\* SQL Server XA uses MSDTC enlistment via Windows COM (`ITransaction*`
+ `SQL_ATTR_ENLIST_IN_DTC`). With `--features xa-dtc`, the engine runs
the DTC branch and participates in the cross-vendor `apply_xa_*` matrix
on **Windows** only; there is no Linux/MSDTC path. Optional **hardening**
(recovery edge cases, paid Windows CI, `IResourceManager::Reenlist` tuning)
remains in [`PENDING_IMPLEMENTATIONS.md` §1.1](Features/PENDING_IMPLEMENTATIONS.md).
†† Optional OCI XA *shim* (`--features xa-oci`) is **not** the production
path (Oracle uses `DBMS_XA`); the deferred OCI work is summarised in
[`PENDING_IMPLEMENTATIONS.md` §1.2](Features/PENDING_IMPLEMENTATIONS.md).

## OdbcType variants (v3.0 additions)

```
Varchar = 1, Integer = 2, BigInt = 3, Decimal = 4, Date = 5,
Timestamp = 6, Binary = 7,                                       // pre-v3.0
NVarchar = 8, TimestampWithTz = 9, DatetimeOffset = 10,
Time = 11, SmallInt = 12, Boolean = 13, Float = 14,
Double = 15, Json = 16, Uuid = 17, Money = 18, Interval = 19,    // NEW v3.0
```

`from_protocol_discriminant` round-trips every variant; `from_odbc_sql_type`
covers the new SQL_* type codes (`SQL_GUID`=−11, `SQL_TYPE_TIME`=92, …).

## FFI surface (v3.0 additions)

| FFI | Purpose |
|---|---|
| `odbc_build_upsert_sql` | Generate dialect UPSERT for the connection-string-resolved plugin |
| `odbc_append_returning_sql` | Append RETURNING/OUTPUT clause to a DML statement |
| `odbc_get_session_init_sql` | Get the post-connect SQL statements as a JSON array |

All three accept the **connection string** (not an open connection) and dispatch
through `PluginRegistry`. They are pure SQL generators — no I/O — which makes
them composable with the existing `odbc_exec_query` / `odbc_exec_query_params`
runtime entry points.

## Dart bindings

```dart
import 'package:odbc_fast/infrastructure/native/driver_capabilities_v3.dart';

final native = OdbcNative()..init();
final features = OdbcDriverFeatures(native);

// UPSERT
final upsert = features.buildUpsertSql(
  connectionString: 'Driver={PostgreSQL};...',
  table: 'public.users',
  columns: ['id', 'name', 'email'],
  conflictColumns: ['id'],
);
// → INSERT INTO "public"."users" ("id", "name", "email") VALUES (?, ?, ?)
//    ON CONFLICT ("id") DO UPDATE SET "name" = EXCLUDED."name", "email" = EXCLUDED."email"

// RETURNING
final withReturning = features.appendReturningClause(
  connectionString: 'Driver={SQL Server};...',
  sql: 'INSERT INTO [users] ([name]) VALUES (?)',
  verb: DmlVerb.insert,
  columns: ['id', 'created_at'],
);
// → INSERT INTO [users] ([name]) OUTPUT INSERTED.[id], INSERTED.[created_at] VALUES (?)

// Session init
final stmts = features.getSessionInitSql(
  connectionString: 'Driver={Oracle};...',
  options: SessionOptions(timezone: 'UTC', schema: 'MYAPP'),
);
// → ['ALTER SESSION SET NLS_DATE_FORMAT=...', 'ALTER SESSION SET TIME_ZONE=...', ...]
```

## Plugin lookup by DBMS name (live)

`PluginRegistry::plugin_id_for_dbms_name` maps real DBMS names to plugin ids:

| DBMS name (`SQL_DBMS_NAME`) | Plugin id |
|---|---|
| `Microsoft SQL Server` | `sqlserver` |
| `PostgreSQL` | `postgres` |
| `MySQL` | `mysql` |
| `MariaDB` | `mariadb` |
| `Oracle` | `oracle` |
| `Adaptive Server Anywhere` / `Adaptive Server Enterprise` | `sybase` |
| `SQLite` | `sqlite` |
| `IBM Db2` | `db2` |
| `Snowflake` | `snowflake` |

## Dart — `SqlDataType` kinds and directional parameters

- **27** `SqlDataType` *kind* strings shipped in `lib/infrastructure/native/protocol/param_value.dart` (30 was the design target; 27 are implemented as of v3.5.3 — including `geometry`, `intervalYearToMonth`, and `json` / `json_validated`). See
  `doc/notes/TYPE_MAPPING.md` §1.3 for the full table.
- **Directional API:** `ParamDirection`, `DirectedParam` — DRT1 / `OUT1` and
  engine bind for **scalar** `OUT` / `INOUT` (see `TYPE_MAPPING` §3.1);
  `paramValuesFromDirected` remains input-only. **Multi-result + OUT1:** when
  `SQLMoreResults` yields extra items, the engine emits a **MULT** envelope
  followed by `OUT1`; `QueryResult.additionalResults` exposes the tail items
  (`DirectedResultItem` / `DirectedRowCountItem`). **Ref-cursor** *wire* (tag
  6, `RC1\0` trailer) is decoded into `QueryResult.refCursorResults`. **Oracle**
  — with the active Oracle plugin, the engine materializes cursors (strip `?` +
  `more_results`; see `TYPE_MAPPING` §3.1.1, `ref_cursor_oracle`); other drivers
  return `ref_cursor_out_oracle_only` when `RefCursorOut` is used.
- **Columnar v2 (results):** opt-in Rust `columnar-v2` *feature* + Dart
  `columnarV2Flags` — production results remain row-major v1.
