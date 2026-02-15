# OBSERVABILITY.md

Guia de telemetria e metricas operacionais do `odbc_fast`.

## Componentes

- `TelemetryRepositoryImpl`: integra com backend OTLP via FFI
- `SimpleTelemetryService`: camada de servico para eventos/metricas
- `OdbcService.getMetrics()`: metricas operacionais de execucao
- `OdbcService.getPreparedStatementsMetrics()`: metricas de cache de prepared statements

## Inicializacao OTLP

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

## Fallback para console

Quando houver falhas consecutivas na exportacao OTLP, o repositorio pode usar fallback.

```dart
import 'package:odbc_fast/infrastructure/native/telemetry/console.dart';

repository.setFallbackExporter(ConsoleExporter());
```

## Metricas de ODBC

### `getMetrics()`

Campos principais:

- `queryCount`
- `errorCount`
- `uptimeSecs`
- `totalLatencyMillis`
- `avgLatencyMillis`

### `getPreparedStatementsMetrics()`

Campos principais:

- `cacheSize`, `cacheMaxSize`
- `cacheHits`, `cacheMisses`
- `cacheHitRate`
- `totalPrepares`, `totalExecutions`
- `avgExecutionsPerStmt`

## Exemplo minimo

```dart
final metricsResult = await service.getMetrics();
metricsResult.fold(
  (m) => print('queries=${m.queryCount} avg=${m.avgLatencyMillis}ms'),
  (e) => print('erro: $e'),
);
```

## Recomendacoes

1. Em producao, usar endpoint OTLP com TLS e autenticacao.
2. Ativar fallback apenas como contingencia, nao como caminho principal.
3. Monitorar `errorCount` e `cacheHitRate` para identificar regressao.
