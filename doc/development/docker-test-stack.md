# Docker test stack

`dart_odbc_fast` ships a complete Docker stack for running the engine's
E2E suite against every supported database **without installing any ODBC
driver on the host**. This document explains what is in the stack, how
to start it, and how to drive the existing test matrix from it.

> **Status:** added in v3.4.0 follow-up. Replaces the previous
> "install drivers manually + tweak `.env`" workflow. Optional —
> the existing host-driven setup keeps working unchanged.

## What's in the box

`docker-compose.yml` declares 6 database services and 1 Linux test
runner:

| Service       | Image                                          | Port (host) | Notes                                              |
| ------------- | ---------------------------------------------- | ----------- | -------------------------------------------------- |
| `postgres`    | `postgres:16-alpine`                           | `5432`      | XA-aware (`max_prepared_transactions=64`)          |
| `mysql`       | `mysql:8.0`                                    | `3306`      | `mysql_native_password`                            |
| `mariadb`     | `mariadb:11.4`                                 | `3307`      | Separate port to avoid clash with `mysql`          |
| `mssql`       | `mcr.microsoft.com/mssql/server:2022-latest`   | `1433`      | Developer edition                                  |
| `oracle`      | `gvenzl/oracle-xe:21-slim-faststart`           | `1521`      | XE PDB `XEPDB1`                                    |
| `db2`         | `icr.io/db2_community/db2:latest`              | `50000`     | **Profile `db2`**, slow boot (~2 min)              |
| `sqlite-tools`| `keinos/sqlite3:latest`                        | —           | **Profile `sqlite`**, dev shell only               |
| `test-runner` | Custom (see `Dockerfile.test-runner`)          | —           | **Profile `test`**, Rust + unixODBC + drivers      |

The `test-runner` image bakes in:

- Rust stable (currently `1.86`).
- `unixodbc` + dev headers.
- ODBC drivers for **PostgreSQL**, **MySQL/MariaDB** (via `odbc-mariadb`),
  and **Microsoft SQL Server 18** (`msodbcsql18`).
- A pre-baked `/etc/odbcinst.ini` with the driver names that the
  project's connection-string templates expect.

ODBC drivers **not** baked in (proprietary / licensed):

- Oracle Instant Client + Oracle ODBC.
- IBM Db2 Data Server Driver (`ibm-data-server-driver-package`).
- Sybase / SQL Anywhere.
- Snowflake.

Each of these is a one-line `apt-get install` or a `COPY` of the
official tarball on top of the base image. See the comments inside
`Dockerfile.test-runner` for the exact recipes.

## Quick start

### 1. Bring up the DB stack

```powershell
# Windows / PowerShell
pwsh scripts/docker_db_up.ps1

# Add Db2 (slow startup, ~2 min)
pwsh scripts/docker_db_up.ps1 -IncludeDb2

# Tear everything down
pwsh scripts/docker_db_up.ps1 -Down
```

```bash
# Linux / macOS / WSL
scripts/docker_db_up.sh
scripts/docker_db_up.sh --include-db2
scripts/docker_db_up.sh --down
```

The script polls every container's healthcheck until it reports
`healthy` (or the timeout elapses). On success it prints a DSN
cheatsheet you can paste into your `.env`.

### 2. Run E2E tests inside the test-runner

This is the path that requires **zero** ODBC drivers on the Windows
host:

```powershell
# Default: PostgreSQL, full --include-ignored E2E suite
pwsh scripts/docker_e2e.ps1

# Pick a different engine
pwsh scripts/docker_e2e.ps1 -Engine mysql
pwsh scripts/docker_e2e.ps1 -Engine mariadb
pwsh scripts/docker_e2e.ps1 -Engine mssql

# Restrict to one test or family
pwsh scripts/docker_e2e.ps1 -Engine postgres -TestFilter xa_pg_

# Smoke-only (lib transaction tests, fast)
pwsh scripts/docker_e2e.ps1 -SmokeOnly
```

```bash
scripts/docker_e2e.sh --engine postgres
scripts/docker_e2e.sh --engine mysql --filter xa_mysql_
scripts/docker_e2e.sh --smoke
```

What the script does:

1. Calls `docker_db_up` to ensure the DB containers are healthy.
2. Builds the `test-runner` image (cached after the first run).
3. Mounts the workspace into the container and runs `cargo test`
   with `ODBC_TEST_DSN` set to the right docker-network DSN.

### 3. Run E2E tests from the host (alternative)

If you already have ODBC drivers installed on the host, you can drive
the same containers from your normal `cargo test` command — just paste
one of the lines from `.env.docker` into your `.env`:

```ini
ENABLE_E2E_TESTS=1
ODBC_TEST_DSN=Driver={ODBC Driver 18 for SQL Server};Server=localhost,1433;Database=master;UID=sa;PWD=OdbcTest123!;TrustServerCertificate=yes;
```

## Running the v3.4.0 XA / 2PC suite

Sprint 4.3 in v3.4.0 added 9 `#[ignore]` E2E tests for distributed
transactions on PostgreSQL / MySQL / MariaDB / DB2. The runner image
covers PG / MySQL / MariaDB out of the box; for DB2 you also need to
add the Db2 driver tarball to the image (commented snippet at the
bottom of `Dockerfile.test-runner`).

```powershell
# PostgreSQL: most complete XA grammar coverage
pwsh scripts/docker_e2e.ps1 -Engine postgres -TestFilter xa_

# MySQL 8 (XA START / END / PREPARE / COMMIT / RECOVER)
pwsh scripts/docker_e2e.ps1 -Engine mysql    -TestFilter xa_

# MariaDB 11 (same XA grammar as MySQL but slightly different RECOVER)
pwsh scripts/docker_e2e.ps1 -Engine mariadb  -TestFilter xa_
```

## What about MSDTC (4.3b) and OCI (4.3c)?

- **MSDTC** is a Windows COM service. The `test-runner` Linux container
  cannot exercise the Phase 2 wiring — those tests must run on a
  Windows host with `sc query MSDTC` reporting `RUNNING`. Docker only
  helps to provide the SQL Server endpoint (the `mssql` service above
  works with MSDTC enrolment from a Windows client).
- **OCI XA** needs Oracle Instant Client + the OCI XA shared library.
  Easiest path inside Docker: extend `Dockerfile.test-runner` with a
  `COPY instantclient_*.zip /opt/` step (the Oracle Free download EULA
  forbids redistribution so the file has to come from your local
  download). Then set the `XA_OPEN` entry on the `oracle` container.

## CI / GitHub Actions

The same `docker-compose.yml` + scripts work in CI. A starter workflow
that exercises PG/MySQL/MariaDB/MSSQL in parallel jobs is sketched in
`doc/notes/FUTURE_IMPLEMENTATIONS.md` (Sprint 4.5). The matrix takes
~6 minutes on `ubuntu-latest` runners; Db2 adds another ~3 min so it
typically lives behind a manual workflow trigger.

## Troubleshooting

| Symptom                                                        | Fix                                                                                       |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `docker compose up` hangs at `mssql` healthcheck               | First boot can take 30 s; the script waits up to 5 minutes. Inspect `docker logs odbc_test_mssql`. |
| `Invalid object name 'odbc_test'` after `up`                   | The first connection auto-creates `odbc_test` only on PG/MySQL/MariaDB. Other engines need the schema fixture from your test setup. |
| `[unixODBC][Driver Manager]Can't open lib …`                   | The driver alias in the connection string does not match `odbcinst.ini`. Check `odbcinst -q -d` inside the container. |
| Test passes from container but fails from host                 | The host has a different ODBC driver version. Switch to the runner-image path or upgrade your host driver. |
| `docker_db_up` exits with `Timed out waiting for: oracle`      | Increase the timeout: `pwsh scripts/docker_db_up.ps1 -TimeoutSeconds 600`.                |

## Related files

- [`docker-compose.yml`](../../docker-compose.yml)
- [`Dockerfile.test-runner`](../../Dockerfile.test-runner)
- [`.env.docker`](../../.env.docker) — DSN templates
- [`scripts/docker_db_up.ps1`](../../scripts/docker_db_up.ps1) /
  [`scripts/docker_db_up.sh`](../../scripts/docker_db_up.sh)
- [`scripts/docker_e2e.ps1`](../../scripts/docker_e2e.ps1) /
  [`scripts/docker_e2e.sh`](../../scripts/docker_e2e.sh)
- [`doc/notes/FUTURE_IMPLEMENTATIONS.md`](../notes/FUTURE_IMPLEMENTATIONS.md) —
  Sprint 4.3b / 4.3c follow-up work
