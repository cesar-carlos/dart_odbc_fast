# Docker Setup for Multi-Database Testing

## Quick Start

```bash
docker compose up -d
```

Wait for healthchecks (~30s for SQL Server). Then set env vars and run tests.

## Services

| Service   | Port | Database  | User     | Password     |
|-----------|------|-----------|----------|--------------|
| PostgreSQL| 5432 | odbc_test| postgres | postgres     |
| MySQL     | 3306 | odbc_test| root     | mysql        |
| SQL Server| 1433 | master   | sa       | OdbcTest123! |

## ODBC Drivers Required

Install drivers for the databases you want to test:

- **PostgreSQL**: `psqlodbc` (Linux), PostgreSQL ODBC Driver (Windows)
- **MySQL**: `mysql-connector-odbc` (Linux), MySQL ODBC Driver (Windows)
- **SQL Server**: `msodbcsql17` (Linux), SQL Server Native Client (Windows)

## Environment Variables

- `ODBC_TEST_DSN`: Full connection string (overrides all below)
- `ODBC_TEST_DB`: `postgres` | `mysql` | (default: sqlserver)
- `ENABLE_E2E_TESTS`: `1` or `true` to run E2E tests

## Connection Strings (docker-compose defaults)

### PostgreSQL

```
ODBC_TEST_DSN=Driver={PostgreSQL Unicode};Server=localhost;Port=5432;Database=odbc_test;Uid=postgres;Pwd=postgres;
```

Or use env vars: `POSTGRES_TEST_SERVER=localhost`, `POSTGRES_TEST_DATABASE=odbc_test`, etc.

### MySQL

```
ODBC_TEST_DSN=Driver={MySQL ODBC 8.0 Driver};Server=localhost;Port=3306;Database=odbc_test;User=root;Password=mysql;
```

Or: `MYSQL_TEST_SERVER=localhost`, `MYSQL_TEST_DATABASE=odbc_test`, etc.

### SQL Server

```
ODBC_TEST_DSN=Driver={ODBC Driver 17 for SQL Server};Server=localhost,1433;Database=master;UID=sa;PWD=OdbcTest123!;TrustServerCertificate=yes;
```

Or: `SQLSERVER_TEST_SERVER=localhost`, `SQLSERVER_TEST_PORT=1433`, `SQLSERVER_TEST_PASSWORD=OdbcTest123!`, etc.

## Running E2E Tests

```bash
export ENABLE_E2E_TESTS=1

# PostgreSQL (ODBC_TEST_DB or ODBC_TEST_DSN)
export ODBC_TEST_DB=postgres
cd native && cargo test e2e_multi_db

# Or with full DSN
export ODBC_TEST_DSN="Driver={PostgreSQL Unicode};Server=localhost;Port=5432;Database=odbc_test;Uid=postgres;Pwd=postgres;"
cd native && cargo test e2e_multi_db

# MySQL
export ODBC_TEST_DB=mysql
cd native && cargo test e2e_multi_db

# SQL Server
export ODBC_TEST_DSN="Driver={ODBC Driver 17 for SQL Server};Server=localhost,1433;Database=master;UID=sa;PWD=OdbcTest123!;TrustServerCertificate=yes;"
cd native && cargo test --workspace
```

## Schema

E2E tests create and drop tables dynamically. No init scripts required.
