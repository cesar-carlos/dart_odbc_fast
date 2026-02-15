# Investigation Summary - Implementation Notes

**Date**: 2026-02-15  
**Base**: leitura de `doc/notes/check.txt` + verificacao direta do codigo atual

---

## Status das anotacoes

### Resolvido

| ID | Nota original | Status atual | Evidencia |
| --- | --- | --- | --- |
| A1 | `GetCacheMetricsRequest() not added yet` | Resolved | `lib/infrastructure/native/isolate/worker_isolate.dart` (`case GetCacheMetricsRequest`) |
| A2 | `IOdbcRepository precisa declarar getPreparedStatementsMetrics()` | Resolved | `lib/domain/repositories/odbc_repository.dart` |
| A3 | `OdbcService needs to implement getPreparedStatementsMetrics()` | Resolved | `lib/application/services/odbc_service.dart` |
| A4 | `OdbcService needs to implement clearStatementCache()` | Resolved | `lib/application/services/odbc_service.dart` |
| A5 | `NULL converted to empty string` | Resolved | `native/odbc_engine/src/protocol/param_value.rs` + `execution_engine.rs` (`None -> SQL NULL`) |
| A6 | `worker_isolate: Case ClearCacheRequest() not yet added` | Resolved | `lib/infrastructure/native/isolate/worker_isolate.dart` (`case ClearCacheRequest`) |
| A7 | Async API: timeout, dispose, worker crash | Resolved | `lib/infrastructure/native/async_native_odbc_connection.dart` + `async_error.dart` |
| A8 | BinaryProtocolParser: RangeError em buffer truncado | Resolved | `lib/infrastructure/native/protocol/binary_protocol.dart` (`FormatException`) |
| A9 | Multi-result decoder Dart ausente | Resolved | `lib/infrastructure/native/protocol/multi_result_parser.dart` + `odbc_repository_impl.dart` |
| B4 | `Testes de integration precisam ser atualizados` | Resolved | `test/e2e/odbc_smoke_test.dart` + grupo E2E em `test/application/services/odbc_service_integration_simple_test.dart` |
| B5 | Named/multi integration coverage in service APIs | Resolved | `test/integration/named_parameters_integration_test.dart` (sync/async + multi full com skip seguro) |

### Parcial / pendente

| ID | Nota original | Status atual | Observacao |
| --- | --- | --- | --- |
| B1 | `Implementations are stubs that return default values (zeros)` | Partial | ainda ha stubs pontuais, mas fluxo principal usa implementacao real (repo/native) |
| REQ-005/PREP-002 | `StatementOptions complete` | Complete (with deprecation) | `asyncFetch` deprecado por nao ter efeito runtime |
| Named Parameters | `Complete` | Mostly complete | fluxo de alto nivel + API explicita async implementados; falta validacao E2E async dedicada |
| REQ-001 | `Multi-result complete` | Mostly complete | `QueryResultMulti` + `executeQueryMultiFull` implementados; falta validacao E2E real com banco |
| B3 | `PREP-004 Out of Scope` | Closed (not planned in core) | decisão formal registrada em `PREP_004_DECISION.md` |

---

## Verificacoes principais

### Cache metrics e clear cache

- `GetCacheMetricsRequest` e `ClearCacheRequest` existem no worker isolate.
- `IOdbcRepository` declara `getPreparedStatementsMetrics` e `clearStatementCache`.
- `OdbcService` delega ambos para o repositorio.

### NULL handling

- `ParamValue::Null` vira `None` em `param_values_to_strings`.
- bind usa `.as_deref().into_parameter()` no engine.
- `None` e enviado como SQL NULL.

### Multi-result

- parser Dart existe e e usado em `executeQueryMulti`.
- retorno completo implementado via `QueryResultMulti` e
  `executeQueryMultiFull` (repository/service).
- `executeQueryMulti` segue retornando o primeiro result set por compatibilidade.
- pendente: validacao E2E real com banco para fluxo completo multi-result.

### Async reliability

- timeout de request (`requestTimeout`) implementado.
- `_failAllPending` aplicado em `dispose`, `onError`, `onDone`.
- codigos `requestTimeout` e `workerTerminated` presentes.

### Named parameters

- implementado: `NamedParameterParser`, `prepareStatementNamed`, `executeNamed`.
- implementado no alto nivel: `prepareNamed`, `executePreparedNamed`, `executeQueryNamed`
  em `IOdbcRepository`, `OdbcService`, decorator de telemetry e `OdbcRepositoryImpl`.
- implementado em async native: `prepareNamed`, `executePreparedNamed`,
  `executeQueryNamed` em `AsyncNativeOdbcConnection`.
- suporte de sintaxe atual: `@name` e `:name` (nao `?name`).
- pendente: validacao E2E dedicada do fluxo com backend async real.

---

## Observabilidade e OTLP

Status: implementado com fallback.

- `TelemetryRepositoryImpl` inicializa OTLP via FFI.
- fallback para `ConsoleExporter` esta implementado.
- documentacao consolidada em `doc/OBSERVABILITY.md`.

---

## Correcos aplicadas nesta revisao

1. Removida data futura e padronizado para `2026-02-15`.
2. Corrigidos caminhos/nomes desatualizados.
3. Ajustado status de `StatementOptions` para **Complete (with deprecation)**.
4. Atualizado status de `Named Parameters` e `Multi-result` para
   **Mostly complete** com gaps E2E explícitos.
5. Corrigida referencia de teste para `odbc_service_integration_simple_test.dart`.

---

## Proximos passos recomendados

1. Validar named parameters no backend async (E2E).
2. Validar em E2E real o fluxo multi-result completo (`executeQueryMultiFull`).
3. Continuar validacao E2E com matriz de DSNs/drivers.
