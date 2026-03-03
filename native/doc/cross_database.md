# Cross-Database Support

The ODBC engine supports multiple databases via ODBC drivers. This document describes connection strings, quirks, and compatibility for each supported database.

---

## Supported Databases

| Database | CI Status | Driver | Notes |
|----------|------------|--------|-------|
| SQL Server | ✅ | ODBC Driver 17 / Native Client 11.0 | Full support, native BCP available |
| PostgreSQL | ✅ | PostgreSQL Unicode | Full support |
| MySQL | ⚠️ | MySQL ODBC 8.0 Driver | `continue-on-error` in CI (driver setup) |
| SQLite | ✅ | SQLite3 (libsqliteodbc) | File-based, no server; full support |
| Oracle | ✅ | Oracle Instant Client ODBC | CI job active (`continue-on-error` for stabilization) |
| Sybase SQL Anywhere | ❌ | SQL Anywhere | Optional, not in CI |

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

## Feature Support by Database

| Feature | SQL Server | PostgreSQL | MySQL | SQLite |
|---------|------------|------------|-------|--------|
| Connect, query, disconnect | ✅ | ✅ | ✅ | ✅ |
| Prepared statements | ✅ | ✅ | ✅ | ✅ |
| Transactions, savepoints | ✅ | ✅ | ✅ | ✅ |
| Streaming | ✅ | ✅ | ✅ | ✅ |
| Bulk insert (ArrayBinding) | ✅ | ✅ | ✅ | ✅ |
| Parallel bulk insert | ✅ | ✅ | ✅ | ✅ |
| Native BCP | ✅ (`sqlncli11.dll`) | ❌ | ❌ | ❌ |
| Driver capabilities JSON | ✅ | ✅ | ✅ | ✅ |

---

## CI/CD Matrix

The `e2e_multidb.yml` workflow runs E2E tests against:

1. **SQLite** (libsqliteodbc, file-based `/tmp/odbc_test.db`)
2. **PostgreSQL** (postgres:16-alpine, odbc-postgresql)
3. **MySQL** (mysql:8.0, mysql-connector-odbc) — `continue-on-error: true`
4. **SQL Server** (mcr.microsoft.com/mssql/server:2022, msodbcsql17)
5. **Oracle** (gvenzl/oracle-xe + Oracle Instant Client ODBC) — `continue-on-error: true`

Run locally:

```bash
ENABLE_E2E_TESTS=1 ODBC_TEST_DSN="Driver={...};..." cargo test e2e_multi_db -- --nocapture
```

---

## Driver Capabilities

Use `odbc_get_driver_capabilities(conn_str, buffer, len, out)` to get JSON capabilities per driver:

- `supports_prepared_statements`
- `supports_batch_operations`
- `supports_streaming`
- `max_row_array_size`
- `driver_name`, `driver_version`

Detection is heuristic (connection string substring). See `engine/core/driver_capabilities.rs`.

---

## Recommendations

1. **SQL Server**: Use native BCP for bulk inserts (10k+ rows) when `sqlncli11.dll` is available. See `bcp_dll_compatibility.md`.
2. **PostgreSQL / MySQL / SQLite**: Use ArrayBinding or ParallelBulkInsert; no native BCP.
3. **SQLite**: No server; ideal for local testing and CI. Use `ODBC_TEST_DB=sqlite` with `SQLITE_TEST_DATABASE`.
4. **Cross-database code**: Use `DatabaseType` detection and `sql_drop_table_if_exists` for DDL portability.
5. **Connection string**: Prefer `ODBC_TEST_DSN` for tests; fall back to component env vars.

---

## 5th Database (Status)

5 bancos em CI já foram validados na execução `22641867638`:

- **Oracle**: Job ativa e validada; próximo passo é remover `continue-on-error`
  após janela curta de estabilidade.
- **Sybase SQL Anywhere**: Docker image available; driver `SQL Anywhere 17`. Connection string: `Driver={SQL Anywhere 17};ServerName=...;Database=...;Uid=...;Pwd=...;`

Implemented:
- `get_oracle_test_dsn()` and `get_sybase_test_dsn()` in `helpers/env.rs`
- `ODBC_TEST_DB=oracle|sybase` routing in `get_connection_and_db_type()`
- Oracle-safe SQL in `e2e_multi_db_basic_test.rs` (`SELECT ... FROM DUAL`, Oracle drop guard)

---

## References

- `native/doc/performance_comparison.md` — Benchmarks per strategy
- `native/doc/bcp_dll_compatibility.md` — SQL Server BCP requirements
- `native/odbc_engine/tests/helpers/env.rs` — Connection string builders
- `native/odbc_engine/tests/helpers/e2e.rs` — `sql_drop_table_if_exists`, `DatabaseType`
