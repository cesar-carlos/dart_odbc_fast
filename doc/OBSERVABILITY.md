# Observability

Configuration and usage of OTLP telemetry and ODBC operational metrics.

## OTLP Configuration

Configure telemetry with `TelemetryRepositoryImpl` and an OpenTelemetry FFI backend. The OTLP endpoint defaults to `http://localhost:4318` (HTTP/protobuf).

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

## Fallback to ConsoleExporter

When OTLP export fails repeatedly, the repository can switch to `ConsoleExporter` to write telemetry to stdout. Set a fallback before initialization:

```dart
import 'package:odbc_fast/infrastructure/native/telemetry/console.dart';

final repository = TelemetryRepositoryImpl(ffi);
repository.setFallbackExporter(ConsoleExporter());

await repository.initialize(otlpEndpoint: 'http://localhost:4318');
```

Fallback triggers when failures exceed `consecutiveFailureThreshold` (default: 3) within `failureCheckInterval` (default: 30s).

## ODBC Metrics

The ODBC service exposes operational metrics via `getMetrics()` and `getPreparedStatementsMetrics()`.

### OdbcMetrics

- `queryCount` – total queries executed
- `errorCount` – total errors
- `uptimeSecs` – engine uptime
- `totalLatencyMillis` – cumulative latency
- `avgLatencyMillis` – average query latency

```dart
final metrics = await service.getMetrics();
metrics.fold(
  (m) => print('Queries: ${m.queryCount}, Avg: ${m.avgLatencyMillis}ms'),
  (e) => print('Error: $e'),
);
```

### PreparedStatementMetrics

- `cacheSize` / `cacheMaxSize` – cache usage
- `cacheHits` / `cacheMisses` – hit/miss counts
- `totalPrepares` / `totalExecutions` – prepare/execute counts
- `cacheHitRate` – percentage (0–100)
- `avgExecutionsPerStmt` – average executions per statement

```dart
final stmtMetrics = await service.getPreparedStatementsMetrics();
stmtMetrics.fold(
  (m) => print('Cache hit rate: ${m.cacheHitRate}%'),
  (e) => print('Error: $e'),
);
```

## Minimal Example

```dart
import 'package:odbc_fast/core/di/service_locator.dart';

void main() async {
  final locator = ServiceLocator()..initialize(useAsync: true);
  await locator.syncService.initialize();

  final connResult = await locator.syncService.connect('DSN=YourDSN');
  connResult.fold(
    (conn) async {
      final metrics = await locator.syncService.getMetrics();
      metrics.fold(
        (m) => print('Query count: ${m.queryCount}'),
        (_) {},
      );
      await locator.syncService.disconnect(conn.id);
    },
    (_) {},
  );
}
```



