# Docker test stack

`dart_odbc_fast` ships a complete Docker stack for running the engine's
E2E suite against the configured database services **without installing ODBC
drivers on the host**. This document explains what is in the stack, how
to start it, and how to drive the existing test matrix from it.

Use dedicated test databases; E2E tests create and drop objects. Container
runners supply drivers inside the image. Host-driven tests need host drivers.

## What's in the box

`docker-compose.yml` declares six database services, an optional SQLite helper,
and Linux test runners:

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

- Rust selected by `RUST_VERSION` in `Dockerfile.test-runner` (currently `1.93`).
- `unixodbc` + dev headers.
- ODBC drivers for **PostgreSQL**, **MySQL/MariaDB** (via `odbc-mariadb`),
  **Microsoft SQL Server 18** (`msodbcsql18`), and **IBM Db2** (ODBC/CLI
  `linuxx64_odbc_cli.tar.gz` from IBM’s public DHE, pinned in the
  Dockerfile as `IBM_ODBC_CLI_VERSION`).
- A pre-baked `/etc/odbcinst.ini` with the driver names that the
  project's connection-string templates expect, including
  `IBM DB2 ODBC DRIVER` (`IBM_DB_HOME=/opt/ibm/clidriver`).

ODBC drivers **not** baked in by default (or optional at build time):

- Oracle Instant Client + Oracle ODBC — opt in with `INCLUDE_ORACLE=true`
  when building the image (`test-runner-oracle` compose service).
- Sybase / SQL Anywhere.
- Snowflake.

See `Dockerfile.test-runner` for Oracle opt-in and Db2/IBM URL pinning.

## E2E env, slow DSN, and pool timeouts

Rust E2E tests in `native/odbc_engine/tests` often gate on
`ENABLE_E2E_TESTS=1` (and a valid DSN). `e2e_pool_test` uses
`ConnectionPool::new_with_options` with a **5s** `connection_timeout` so a
bad or slow DSN fails fast instead of R2D2’s default 30s acquire, which
looked like a hang. Keep this in mind when adding new pool E2E cases.

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
# PostgreSQL CI filter; enable integration targets that require test-helpers
pwsh scripts/docker_e2e.ps1 -Features "test-helpers,ffi-tests"

# Pick a different engine
pwsh scripts/docker_e2e.ps1 -Engine mysql -Features "test-helpers,ffi-tests"
pwsh scripts/docker_e2e.ps1 -Engine mariadb -Features "test-helpers,ffi-tests"
pwsh scripts/docker_e2e.ps1 -Engine mssql -Features "test-helpers,ffi-tests"

# Restrict to one test or family
pwsh scripts/docker_e2e.ps1 -Engine postgres -TestFilter xa_pg_ -Features "test-helpers,ffi-tests"

# Smoke-only (lib transaction tests, fast)
pwsh scripts/docker_e2e.ps1 -SmokeOnly
```

```bash
scripts/docker_e2e.sh --engine postgres --features test-helpers,ffi-tests
scripts/docker_e2e.sh --engine mysql --filter xa_mysql_ --features test-helpers,ffi-tests
scripts/docker_e2e.sh --smoke
```

The PowerShell default uses an engine-specific CI filter; `-Full` includes
ignored tests and runs the full suite serially. The Bash runner includes ignored
tests by default; use `--quick` to exclude them. Both default to `ffi-tests`,
so pass `test-helpers,ffi-tests` for integration targets gated by `test-helpers`.

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

### Host DSNs

Use [Cross-database connection strings](../../native/doc/cross_database.md#connection-strings)
for environment variables and driver-specific DSNs. Driver names must match
those installed on the host. Explicit test DSNs avoid relying on helper defaults.

### Dart `pool_integration_test` (T-SQL)

[`test/integration/pool_integration_test.dart`](../../test/integration/pool_integration_test.dart)
expects a **Microsoft SQL Server** backend: it uses T-SQL (`IF OBJECT_ID`, `IDENTITY`,
`NVARCHAR`). Set `ODBC_TEST_DSN` or `ODBC_DSN` to a SQL Server DSN before
`dart test test/integration/pool_integration_test.dart`. It is not compatible with
PostgreSQL or other engines without changing the SQL in the test.

## Running the XA / 2PC suite

The default image includes PostgreSQL, MySQL/MariaDB and Db2 drivers.
For Db2, start the `db2` profile as described above. Enable `test-helpers`
for the integration targets; include ignored tests when the selected case needs it.

```powershell
# PostgreSQL: most complete XA grammar coverage
pwsh scripts/docker_e2e.ps1 -Engine postgres -TestFilter xa_ -Features "test-helpers,ffi-tests"

# MySQL 8 (XA START / END / PREPARE / COMMIT / RECOVER)
pwsh scripts/docker_e2e.ps1 -Engine mysql    -TestFilter xa_ -Features "test-helpers,ffi-tests"

# MariaDB 11 (same XA grammar as MySQL but slightly different RECOVER)
pwsh scripts/docker_e2e.ps1 -Engine mariadb  -TestFilter xa_ -Features "test-helpers,ffi-tests"
```

## What about MSDTC (4.3b) and OCI (4.3c)?

- **MSDTC** is a Windows COM service. The `test-runner` Linux container
  cannot exercise the Windows `xa-dtc` lifecycle path — those tests must run on a
  Windows host with `sc query MSDTC` reporting `RUNNING`. Docker only
  helps to provide the SQL Server endpoint (the `mssql` service above
  works with MSDTC enrolment from a Windows client). Step-by-step `cargo
  test`, `ENABLE_E2E_TESTS`, and DSN variables are in
  [`msdtc-recovery.md`](msdtc-recovery.md) (section *Local runbook*).
- **Oracle driver setup:** the `test-runner-oracle` service builds with
  `INCLUDE_ORACLE=true`. Driver availability does not establish OCI XA shim
  readiness. Current XA product support and shim limitations are tracked in
  [pending work](../Features/PENDING_IMPLEMENTATIONS.md).

## Optional: *golden* columnar, compressed v2, PostgreSQL `OUT`

- **Columnar *zstd* *golden* (Dart):** `test/fixtures/columnar_v2_int32_zstd.golden` —
  the Dart test *parses* it only when `odbc_columnar_decompress` resolves from a
  local `odbc_engine` build (or Native Assets on supported platforms). Linux CI
  without a built `.so` still relies on the Rust *sync* test in
  `native/odbc_engine/tests/columnar_v2_zstd_golden_file.rs`.
- **PostgreSQL directed `OUT` (Dart E2E):** set `E2E_PG_DIRECTED_OUT=1` and a
  suitable `ODBC_TEST_DSN` (see `test/e2e/postgres_directed_out_test.dart`),
  then run `dart test` **on a host** with Dart and a PostgreSQL ODBC driver.
  The `test/e2e` file is *not* executed by
  `scripts/docker_e2e` / `docker_e2e.sh` (those only run `cargo test` inside
  the Linux `test-runner` image, which has no Dart SDK in the current
  Dockerfile). The Docker DB stack is still a convenient `postgres` target for
  a host-side DSN if you point `Server` at `localhost:5432`. Not part of the
  default `ubuntu-latest` matrix because drivers and DSNs differ.
- **SQL Server directed `OUT` (Dart E2E, DRT1):** set `E2E_MSSQL_DIRECTED_OUT=1`
  and a SQL Server `ODBC_TEST_DSN` (see `test/e2e/mssql_directed_out_test.dart`);
  run on a **Windows** host with a SQL Server ODBC driver (e.g. *ODBC Driver 18*
  for SQL Server) — same *host* model as the PG `OUT` test above, not
  `scripts/docker_e2e` (Rust-only in `test-runner`). The procedure uses
  one `int OUTPUT` and `{CALL ... ?}`; `SET NOCOUNT ON` is inside the proc to
  keep result-set behaviour predictable. A host DSN for the `mssql` service is
  the usual `Server=localhost,1433;…` from the `docker_db_up` cheatsheet.

## CI / GitHub Actions

The configured matrix is in
[E2E Docker workflow](../../.github/workflows/e2e_docker_stack.yml).
Inspect the run logs for tested engines, enabled features and skipped tests;
startup and execution times vary with the runner and database image.

## Troubleshooting

| Symptom                                                        | Fix                                                                                       |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `docker compose up` hangs at `mssql` healthcheck               | First boot can take 30 s; the script waits up to 5 minutes. Inspect `docker logs odbc_test_mssql`. |
| `Invalid object name 'odbc_test'` after `up`                   | The first connection auto-creates `odbc_test` only on PG/MySQL/MariaDB. Other engines need the schema fixture from your test setup. |
| `[unixODBC][Driver Manager]Can't open lib …`                   | The driver alias in the connection string does not match `odbcinst.ini`. Check `odbcinst -q -d` inside the container. |
| Test passes from container but fails from host                 | The host has a different ODBC driver version. Switch to the runner-image path or upgrade your host driver. |
| `docker_db_up` exits with `Timed out waiting for: oracle`      | Increase the timeout: `pwsh scripts/docker_db_up.ps1 -TimeoutSeconds 600`.                |
| `test-runner` image build fails (Db2, `libdb2o.so.1` missing) | The `Dockerfile.test-runner` `COPY`/IBM client layer may need a valid tarball/URL, or use an image you already built; the Dart E2E above do **not** need this image. |

## Related files

- [`docker-compose.yml`](../../docker-compose.yml)
- [`Dockerfile.test-runner`](../../Dockerfile.test-runner)
- [`.env.docker`](../../.env.docker) — DSN templates
- [`scripts/docker_db_up.ps1`](../../scripts/docker_db_up.ps1) /
  [`scripts/docker_db_up.sh`](../../scripts/docker_db_up.sh)
- [`scripts/docker_e2e.ps1`](../../scripts/docker_e2e.ps1) /
  [`scripts/docker_e2e.sh`](../../scripts/docker_e2e.sh)
- [`doc/Features/PENDING_IMPLEMENTATIONS.md`](../Features/PENDING_IMPLEMENTATIONS.md) —
  delivered / opt-in / product-gated work (MSDTC recovery, OCI shim, TVP,
  directed output maturity, columnar default)
