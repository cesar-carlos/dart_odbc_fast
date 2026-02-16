# Documentation Coverage Audit

Date: 2026-02-16

## Scope

Audit focused on public package surface used by consumers:

- `OdbcService` (`IOdbcService`) methods
- Advanced exported APIs already exposed by `lib/odbc_fast.dart`
  (`RetryHelper`, telemetry contracts/services, statement/cache config, schema
  metadata entities)
- Runnable examples in `example/`

## Verification Method

1. Collected `IOdbcService` methods from `lib/application/services/odbc_service.dart`
2. Checked documentation presence in:
   - `README.md`
   - `example/README.md`
   - `doc/*.md`
3. Checked runnable usage in `example/*.dart`
4. Added missing examples/docs where gaps were found

## Result Summary

### `IOdbcService` coverage

All 34 service methods are now:

- documented
- and referenced in at least one runnable example

Notable gaps that were closed in this audit:

- `executeQueryParams`
- `prepare` / `executePrepared` / `closeStatement`
- pool methods via service (`poolCreate`, `poolGetConnection`,
  `poolReleaseConnection`, `poolHealthCheck`, `poolGetState`, `poolClose`)
- `bulkInsert` and service-level `bulkInsertParallel`
- `releaseSavepoint` and `rollbackTransaction`

### Advanced exported APIs coverage

Added or updated docs/examples for:

- `RetryHelper`, `RetryOptions`
- `PreparedStatementConfig`, `StatementOptions`
- `PrimaryKeyInfo`, `ForeignKeyInfo`, `IndexInfo`
- `ITelemetryService`, `ITelemetryRepository`, `SimpleTelemetryService`
- `TelemetryBuffer`
- `OpenTelemetryFFI`, `TelemetryRepositoryImpl`

## New/Updated Examples

- `example/service_api_coverage_demo.dart`
- `example/advanced_entities_demo.dart`
- `example/telemetry_demo.dart`
- `example/otel_repository_demo.dart`
- `example/connection_string_builder_demo.dart`
- `example/async_service_locator_demo.dart`

## Documentation Updated

- `README.md`
- `example/README.md`
- `doc/OBSERVABILITY.md`

## Residual Notes

- `doc/api/` is generated output (`dart doc`) and is excluded by `.gitignore`.
  It can diverge from source docs until regenerated.
