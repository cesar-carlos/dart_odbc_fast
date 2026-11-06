# Docker test environment

The canonical setup is [Docker test stack](../doc/development/docker-test-stack.md).
It covers services, ports, container runners, Oracle opt-in, host execution,
and troubleshooting. Run commands from the repository root.

- [Compose services](../docker-compose.yml): images, profiles, healthchecks and test credentials.
- [Connection strings](../native/doc/cross_database.md): host-side DSNs and driver quirks.
- [Test policy](../doc/TESTING.md): suite selection and opt-in flags.

Use only dedicated test databases: E2E tests create and drop database objects.
Container runners provide their own ODBC drivers; host-side tests need host drivers.

## SQLite

SQLite is file-based and needs no database server. The optional inspection
container mounts `./.tmp/sqlite` at `/data`:

```sh
docker compose --profile sqlite up -d sqlite-tools
```

For host tests, configure `ODBC_TEST_DB=sqlite` and
`SQLITE_TEST_DATABASE` with the host file path, or use an explicit
`ODBC_TEST_DSN`. The inspection container does not install an ODBC driver
on the host.
