# OBSERVABILITY.md

Telemetry and operational metrics guide for `odbc_fast`.

## Components

- `ITelemetryService` / `ITelemetryRepository`: domain contracts
- `TelemetryRepositoryImpl`: integrates with OTLP backend via FFI
- `SimpleTelemetryService`: service layer for events/metrics
- `OdbcService.getMetrics()`: runtime operational metrics
- `OdbcService.getPreparedStatementsMetrics()`: prepared-statement cache metrics

## Related operational APIs

- `OdbcService.clearStatementCache()`: clears prepared statements cache
- `OdbcService.detectDriver(connectionString)`: identifies driver from connection string
- `ConnectionOptions.queryTimeout`: per-query timeout (repository layer)
- `ConnectionOptions.autoReconnectOnConnectionLost`: reconnect attempts with backoff

## OTLP initialization

```dart
import 'package:odbc_fast/infrastructure/native/bindings/opentelemetry_ffi.dart';
import 'package:odbc_fast/infrastructure/repositories/telemetry_repository.dart';

final ffi = OpenTelemetryFFI();
final repository = TelemetryRepositoryImpl(
  ffi,
  batchSize: 100,
  flushInterval: Duration(seconds: 30),
);

await repository.initialize(otlpEndpoint: 'http://localhost:4318');
```

### FFI contract (Dart -> Rust)

- `OpenTelemetryFFI` uses native library loaded by `library_loader.dart`.
- Expected symbols: `otel_init`, `otel_export_trace`, `otel_export_trace_to_string`, `otel_get_last_error`, `otel_cleanup_strings`, `otel_shutdown`.
- Dart API compatibility:
  - `initialize()` returns `1` on success (backward compatibility)
  - export failures can be inspected with `getLastErrorMessage()`
  - internal telemetry-state lock poisoning returns code `4` from `otel_*` FFI functions

## Console fallback

When consecutive OTLP export failures happen, repository can use fallback exporter.

```dart
import 'package:odbc_fast/infrastructure/native/telemetry/console.dart';

repository.setFallbackExporter(ConsoleExporter());
```

## ODBC metrics

### `getMetrics()`

Main fields:

- `queryCount`
- `errorCount`
- `uptimeSecs`
- `totalLatencyMillis`
- `avgLatencyMillis`

### `getPreparedStatementsMetrics()`

Main fields:

- `cacheSize`, `cacheMaxSize`
- `cacheHits`, `cacheMisses`
- `cacheHitRate`
- `totalPrepares`, `totalExecutions`
- `avgExecutionsPerStmt`

## Minimal example

```dart
final metricsResult = await service.getMetrics();
metricsResult.fold(
  (m) => print('queries=${m.queryCount} avg=${m.avgLatencyMillis}ms'),
  (e) => print('error: $e'),
);
```

## Runnable examples

- `dart run example/telemetry_demo.dart`:
  `SimpleTelemetryService`, `ITelemetryRepository`, and `TelemetryBuffer`
- `dart run example/otel_repository_demo.dart`:
  `OpenTelemetryFFI` + `TelemetryRepositoryImpl` with optional OTLP endpoint

## Recommendations

1. In production, use OTLP endpoint with TLS and authentication
2. Enable fallback only as contingency, not as primary path
3. Monitor `errorCount` and `cacheHitRate` to detect regressions
