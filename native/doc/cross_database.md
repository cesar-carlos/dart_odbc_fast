# Cross-Database Support

The ODBC engine supports multiple databases via ODBC drivers. This document describes connection strings, quirks, and compatibility for each supported database.

---

## Supported databases and capabilities

The [capability matrix](../../doc/CAPABILITIES_v3.md) owns per-engine support.
A configured CI job is not proof of a successful live-driver run; inspect the
specific run and its prerequisites before claiming certification.

---

## Connection Strings

### SQL Server

```text
Driver={ODBC Driver 17 for SQL Server};Server=localhost,1433;Database=master;UID=sa;PWD=YourPassword;TrustServerCertificate=yes;
```

Or with Native Client 11.0 (required for native BCP):

```text
Driver={SQL Server Native Client 11.0};Server=localhost;Database=Estacao;UID=sa;PWD=YourPassword;
```

**Environment variables**: `ODBC_TEST_DSN` or `SQLSERVER_TEST_SERVER`, `SQLSERVER_TEST_DATABASE`, `SQLSERVER_TEST_USER`, `SQLSERVER_TEST_PASSWORD`, `SQLSERVER_TEST_PORT`.

### PostgreSQL

```text
Driver={PostgreSQL Unicode};Server=localhost;Port=5432;Database=odbc_test;Uid=postgres;Pwd=postgres;
```

**Environment variables**: `ODBC_TEST_DSN` or `POSTGRES_TEST_SERVER`, `POSTGRES_TEST_DATABASE`, `POSTGRES_TEST_USER`, `POSTGRES_TEST_PASSWORD`, `POSTGRES_TEST_PORT` (default 5432).

### MySQL

```text
Driver={MySQL ODBC 8.0 Driver};Server=localhost;Port=3306;Database=odbc_test;User=root;Password=mysql;
```

**Environment variables**: `ODBC_TEST_DSN` or `MYSQL_TEST_SERVER`, `MYSQL_TEST_DATABASE`, `MYSQL_TEST_USER`, `MYSQL_TEST_PASSWORD`, `MYSQL_TEST_PORT` (default 3306).

### SQLite

```text
Driver={SQLite3};Database=/tmp/odbc_test.db;
```

**Environment variables**: `ODBC_TEST_DSN` or `ODBC_TEST_DB=sqlite` with `SQLITE_TEST_DATABASE` (default `/tmp/odbc_test.db`).

**Note**: Requires `libsqliteodbc` on Linux. No server; file-based database.

### Oracle

```text
Driver={Oracle Instant Client ODBC};Dbq=//localhost:1521/XEPDB1;Uid=system;Pwd=YourPassword;
```

**Environment variables**: `ODBC_TEST_DSN` or `ODBC_TEST_DB=oracle` with
`ORACLE_TEST_SERVER`, `ORACLE_TEST_PORT` (default 1521),
`ORACLE_TEST_SERVICE_NAME` (default `FREEPDB1`),
`ORACLE_TEST_USER`, `ORACLE_TEST_PASSWORD`.

---

## SQL Quirks by Database

### DROP TABLE IF EXISTS

| Database | Syntax |
|----------|--------|
| SQL Server | `IF OBJECT_ID(N'table_name', N'U') IS NOT NULL DROP TABLE table_name` |
| PostgreSQL, MySQL, SQLite | `DROP TABLE IF EXISTS table_name` |

Use `sql_drop_table_if_exists(table, db_type)` in tests (see `helpers/e2e.rs`).

### Savepoints

| Database | Syntax |
|----------|--------|
| SQL Server | `SAVE TRANSACTION name` / `ROLLBACK TRANSACTION name` |
| PostgreSQL, MySQL | `SAVEPOINT name` / `ROLLBACK TO SAVEPOINT name` |

### Identifiers

- **SQL Server**: `dbo.table_name` for schema-qualified tables.
- **PostgreSQL**: `public.table_name` (default schema).
- **MySQL**: No schema; use database name if needed.
- **SQLite**: No schema; single database per file.

---

## Test environments

- [Docker test stack](../../doc/development/docker-test-stack.md): services,
  profiles, container runners and host execution.
- [Test policy](../../doc/TESTING.md): test scopes and canonical opt-in flags.
- [Multi-database workflow](../../.github/workflows/e2e_multidb.yml) and
  [Docker workflow](../../.github/workflows/e2e_docker_stack.yml): configured CI jobs.

From the repository root, after configuring a dedicated test DSN:

```bash
cd native
ENABLE_E2E_TESTS=1 cargo test -p odbc_engine --features test-helpers --test e2e_multi_db_basic_test -- --nocapture --test-threads=1
```

SQLite needs no server container; see the [SQLite setup](../../docker/README.md#sqlite).

---

## Driver Capabilities

Two detection paths are available:

### 1. Heuristic, no I/O — `odbc_get_driver_capabilities(conn_str, buffer, len, out)`

Inspects the connection string only. Cheap; works before connecting.
JSON fields:

- `engine` — canonical id (`sqlserver`, `postgres`, `mysql`, `mariadb`,
  `oracle`, `sybase_ase`, `sybase_asa`, `sqlite`, `db2`, `snowflake`,
  `redshift`, `bigquery`, `mongodb`, `unknown`).
- `driver_name`, `driver_version`
- `supports_prepared_statements`
- `supports_batch_operations`
- `supports_streaming`
- `max_row_array_size`

Limitations: DSN-only strings (`DSN=mydsn;UID=x;PWD=y`) yield `unknown`;
custom drivers (Devart, DataDirect, ...) are not recognised; MariaDB is
distinguished from MySQL only when the driver string contains `mariadb`.

### 2. Live introspection — `odbc_get_connection_dbms_info(conn_id, buffer, len, out)`

Calls `SQLGetInfo(SQL_DBMS_NAME)` against the live connection. JSON fields:

- `dbms_name` — server-reported product name (e.g.
  `"Microsoft SQL Server"`, `"PostgreSQL"`, `"MariaDB"`,
  `"Adaptive Server Anywhere"`).
- `engine` — canonical id derived from `dbms_name`.
- `max_catalog_name_len`, `max_schema_name_len`,
  `max_table_name_len`, `max_column_name_len`
- `current_catalog` — currently selected database
- `capabilities` — same shape as the heuristic payload above

This path resolves all the limitations of the heuristic. Prefer it once
the connection is open.

Implementation: `engine/core/driver_capabilities.rs`,
`engine/dbms_info.rs`, `plugins/registry.rs::get_for_live_connection`.

---

## Recommendations

1. **SQL Server**: Use native BCP for bulk inserts (10k+ rows) when `sqlncli11.dll` is available. See `bcp_dll_compatibility.md`.
2. **PostgreSQL / MySQL / SQLite**: Use ArrayBinding or ParallelBulkInsert; no native BCP.
3. **SQLite**: No server; ideal for local testing and CI. Use `ODBC_TEST_DB=sqlite` with `SQLITE_TEST_DATABASE`.
4. **Cross-database code**: Use `DatabaseType` detection and `sql_drop_table_if_exists` for DDL portability.
5. **Connection string**: Prefer `ODBC_TEST_DSN` for tests; fall back to component env vars.

---

## References

- `native/doc/performance_comparison.md` — Benchmarks per strategy
- `native/doc/bcp_dll_compatibility.md` — SQL Server BCP requirements
- `native/odbc_engine/tests/helpers/env.rs` — Connection string builders
- `native/odbc_engine/tests/helpers/e2e.rs` — `sql_drop_table_if_exists`, `DatabaseType`
