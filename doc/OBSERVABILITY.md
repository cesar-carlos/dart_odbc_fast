# OBSERVABILITY.md

Guia de telemetria e metricas operacionais do `odbc_fast`.

## Componentes

- `TelemetryRepositoryImpl`: integra com backend OTLP via FFI
- `SimpleTelemetryService`: camada de servico para eventos/metricas
- `OdbcService.getMetrics()`: metricas operacionais de execucao
- `OdbcService.getPreparedStatementsMetrics()`: metricas de cache de prepared statements

## APIs operacionais relacionadas

- `OdbcService.clearStatementCache()`: limpa cache de prepared statements
- `OdbcService.detectDriver(connectionString)`: identifica driver a partir da connection string
- `ConnectionOptions.queryTimeout`: timeout por query (camada de repositorio)
- `ConnectionOptions.autoReconnectOnConnectionLost`: tentativa de reconnect com backoff

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

### Contrato FFI (Dart -> Rust)

- `OpenTelemetryFFI` usa a biblioteca nativa carregada por `library_loader.dart`.
- Simbolos esperados: `otel_init`, `otel_export_trace`, `otel_export_trace_to_string`, `otel_get_last_error`, `otel_cleanup_strings`, `otel_shutdown`.
- Compatibilidade da API Dart:
  - `initialize()` retorna `1` em sucesso (compatibilidade com versoes anteriores).
  - Erros de exportacao podem ser consultados por `getLastErrorMessage()`.

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
