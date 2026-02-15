# GAPS_IMPLEMENTATION_MASTER_PLAN.md

Plano detalhado para fechar todos os GAPs entre implementacao Rust e Dart.

## Objetivo

Eliminar inconsistencias entre backend Rust (FFI/exportacoes) e camada Dart (bindings, wrappers sync/async, repositorio e servicos), com cobertura de testes e documentacao atualizada.

## Status atual (2026-02-15)

1. GAP 1 (telemetria FFI real): implementado no codigo.
2. GAP 3 (`clearAllStatements` real): implementado no codigo (Rust + Dart sync/async).
3. GAP 2 (streaming async real via isolate): implementado no codigo.
4. GAP 4 (`bulk_insert_parallel` ponta a ponta): implementado no codigo (Rust + Dart sync/async + service/repository).
5. Testes executados apos implementacao:
   - Rust: `cargo test --workspace --all-targets --all-features` (verde).
   - Dart: `dart test` (verde).
6. Benchmark comparativo publicado:
   - `native/odbc_engine/tests/e2e_bulk_compare_benchmark_test.rs`
   - execucao: `cargo test --test e2e_bulk_compare_benchmark_test -- --ignored --nocapture`
   - resultado de referencia (2026-02-15, SQL Server local):
     - small (5.000): array `12751.74` rows/s, parallel `39287.02` rows/s, `3.08x`.
     - medium (20.000): array `11889.44` rows/s, parallel `38119.74` rows/s, `3.21x`.

## Escopo dos GAPs

1. Telemetria: Rust exporta `otel_*`, mas Dart usa stub sem FFI real.
2. Streaming async: camada async nao usa streaming FFI real (faz fetch completo).
3. `clearAllStatements`: API Dart existe, mas esta como stub sem efeito.
4. `bulk_insert_parallel`: simbolo existe no binding, mas nao exposto no alto nivel Dart e no Rust ainda e stub.
5. Cancelamento: `cancelStatement` exposto no Dart, mas Rust marca como nao suportado.

## Prioridade e Sequencia

Ordem recomendada de implementacao:

1. GAP 1 (telemetria real) - alto impacto funcional e baixo risco de quebrar SQL path.
2. GAP 3 (`clearAllStatements`) - fechamento rapido de stub e consistencia de API.
3. GAP 2 (streaming async real) - impacto alto, altera fluxo de dados e memoria.
4. GAP 4 (`bulk_insert_parallel`) - maior esforco tecnico e validacao de performance.
5. GAP 5 (cancelamento) - decisao de produto + implementacao tecnica.

Motivo da ordem:

- Entregas 1 e 3 removem divergencias obvias com risco controlado.
- Entregas 2 e 4 sao estruturais e devem vir depois para reduzir superficie de debug.
- Entrega 5 depende de decisao de contrato (suportado de verdade vs capability false).

## Plano detalhado por GAP

## GAP 1 - Telemetria FFI real no Dart

### Estado atual

- Rust exporta e implementa `otel_init`, `otel_export_trace`, `otel_export_trace_to_string`, `otel_get_last_error`, `otel_cleanup_strings`, `otel_shutdown`.
- Dart (`OpenTelemetryFFI`) e stub e nao usa `DynamicLibrary`.

### Implementacao

1. Criar bindings FFI reais para `otel_*` em `lib/infrastructure/native/bindings/opentelemetry_ffi.dart`.
2. Reutilizar `library_loader.dart` para carregar a mesma DLL (`odbc_engine.dll` / `libodbc_engine.so`).
3. Mapear contratos com tipos corretos:
   - `otel_init(const char*, const char*, const char*) -> i32`
   - `otel_export_trace(const u8*, usize) -> i32`
   - `otel_export_trace_to_string(u8*, usize) -> i32`
   - `otel_get_last_error(u8*, usize*) -> i32`
   - `otel_cleanup_strings() -> void`
   - `otel_shutdown() -> void`
4. Atualizar `TelemetryRepositoryImpl` se necessario para tratar codigos de erro reais.
5. Manter fallback em modo seguro:
   - Se simbolo nao existir (DLL antiga), retornar erro claro e nao quebrar inicializacao do pacote inteiro.

### Testes

1. Atualizar `test/infrastructure/native/telemetry/opentelemetry_ffi_test.dart` para validar caminho real de FFI.
2. Adicionar testes de compatibilidade:
   - DLL sem simbolos `otel_*` (deve falhar de forma controlada).
   - fluxo init -> export -> shutdown.
3. Adicionar teste de regressao para mensagens de erro de `otel_get_last_error`.

### Documentacao

1. Atualizar `doc/OBSERVABILITY.md` com contrato real e codigos de retorno.
2. Atualizar `README.md` com status "telemetria nativa real".
3. Registrar mudanca no `CHANGELOG.md`.

### Criterio de aceite

- `OpenTelemetryFFI` nao e mais stub.
- Testes de telemetria passam com biblioteca real.
- Erros de telemetria sao rastreaveis via API Dart.

## GAP 3 - Implementar `clearAllStatements` (remover stub)

### Estado atual

- `clearAllStatements()` no Dart retorna sucesso fixo (`0`) sem acao real.
- Nao existe export FFI correspondente hoje.

### Implementacao

1. Definir contrato Rust novo:
   - `odbc_clear_all_statements() -> c_int`
2. Implementar no Rust:
   - fechar todos os statements abertos no estado global com seguranca.
   - limpar estruturas internas e atualizar erro estruturado em caso de falha.
3. Atualizar arquivos de export:
   - `native/odbc_engine/odbc_exports.def`
   - `native/odbc_engine/include/odbc_engine.h` (via cbindgen/build).
4. Atualizar Dart bindings:
   - adicionar lookup e typedef.
   - ligar `OdbcNative.clearAllStatements()` ao FFI real.
5. Atualizar camada async:
   - adicionar request/response no `message_protocol.dart`.
   - tratar no `worker_isolate.dart`.

### Testes

1. Rust: unit/integration para cenarios:
   - sem statements.
   - multiplos statements abertos.
   - limpeza idempotente.
2. Dart sync/async:
   - preparar N statements, chamar clear all, validar que `execute`/`close` nos IDs antigos falham.

### Documentacao

1. Atualizar docs de prepared statements (`doc/api/prepared-statements.md` e `README.md`).
2. Remover qualquer referencia de "stub".

### Criterio de aceite

- Metodo executa limpeza real no Rust.
- Sync e async usam o mesmo caminho funcional.

## GAP 2 - Streaming async usando FFI streaming real

### Estado atual

- Async `streamQuery`/`streamQueryBatched` usa `executeQueryParams` e retorna resultado completo.
- Sync ja usa `odbc_stream_start/fetch/close`.

### Implementacao

1. Estender protocolo da isolate:
   - `StreamStartRequest`, `StreamFetchRequest`, `StreamCloseRequest`.
   - respostas com `data`, `hasMore`, `error`.
2. Implementar roteamento no `worker_isolate.dart` usando `NativeOdbcConnection` + `OdbcNative.stream*`.
3. Atualizar `AsyncNativeOdbcConnection.streamQuery` e `streamQueryBatched` para:
   - iniciar stream remoto.
   - consumir chunks progressivamente.
   - fechar stream em `finally`.
4. Garantir cleanup em falha/timeouts/dispose:
   - se request falhar, fechar stream no worker.
   - ao `dispose`, encerrar streams ativos.
5. Ajustar parse incremental:
   - manter buffer parcial e parse por mensagem completa, sem exigir carga completa em memoria.

### Testes

1. Unit:
   - fluxo start/fetch/close.
   - tratamento de chunk parcial.
   - erro no meio do stream.
2. Integration:
   - resultados grandes sem explosao de memoria.
   - comparacao de resultado async vs sync.
3. Regressao:
   - testes existentes de streaming continuam passando.

### Documentacao

1. Atualizar `README.md` e docs de streaming com comportamento real no async.
2. Atualizar troubleshooting para timeouts/cancelamento de stream.

### Criterio de aceite

- Async streaming nao faz fetch completo por padrao.
- Comportamento de `hasMore` e chunking consistente com sync.

## GAP 4 - `bulk_insert_parallel` ponta a ponta

### Estado atual

- Implementado:
  - Rust FFI `odbc_bulk_insert_parallel` real com pool + chunking paralelo + validacoes.
  - Binding Dart `OdbcNative.bulkInsertParallel`.
  - Fluxo async isolate (`message_protocol` + `worker_isolate` + `AsyncNativeOdbcConnection`).
  - Exposicao no backend/repository/service + fallback para `bulkInsertArray` quando `parallelism <= 1`.
- Validado:
  - Testes Rust de argumentos invalidos para bulk parallel.
  - Teste Dart de caminho async para `bulkInsertParallel`.

### Implementacao

1. Rust:
   - implementar `odbc_bulk_insert_parallel` real usando pool valido.
   - validar payload/colunas/parallelism.
   - retornar `rows_inserted` e erro estruturado por conexao/pool.
2. Dart bindings:
   - expor metodo `bulkInsertParallel` em `OdbcNative`.
3. Backend/repository/service:
   - incluir operacao no `OdbcConnectionBackend` (sync e async).
   - adicionar requests/handler no worker isolate.
   - expor na camada de servico publica.
4. Compatibilidade:
   - fallback para `bulkInsertArray` quando parallel nao suportado/configurado.

### Testes

1. Rust:
   - sucesso basico.
   - pool invalido.
   - parallelism invalido (0, acima do limite).
2. Dart:
   - unit + integration sync/async.
   - validacao de rows inserted.
3. Performance:
   - benchmark comparando array vs parallel (cenario minimo e medio).
   - entregue em `native/odbc_engine/tests/e2e_bulk_compare_benchmark_test.rs`.

### Documentacao

1. Atualizar `doc/FUTURE_IMPLEMENTATIONS.md` removendo item de backlog quando concluir.
2. Atualizar exemplos (`example/`) com caso de uso de bulk paralelo.
3. Atualizar README com pre-requisitos e limites.

### Criterio de aceite

- Operacao funciona ponta a ponta (service -> repository -> async/sync -> FFI -> Rust).
- Ganho de throughput documentado e reproduzivel.

## GAP 5 - Cancelamento de statement

### Estado atual

- API Dart exposta.
- Rust retorna erro "Unsupported feature".

### Decisao requerida

Escolher 1 das 2 estrategias:

1. Implementar cancelamento real agora.
2. Formalizar como nao suportado (capability), mantendo API com erro explicito.

### Plano tecnico (se estrategia 1)

1. Arquitetura de execucao com handle rastreavel por statement em execucao.
2. Integracao com `SQLCancel`/`SQLCancelHandle` no momento correto.
3. Sincronizacao entre thread de execucao e thread de cancelamento.
4. Garantia de limpeza de estado apos cancel.

### Plano tecnico (se estrategia 2)

1. Introduzir capability API:
   - `supportsStatementCancel` no Dart (e opcionalmente no Rust via metrics/capabilities).
2. Ajustar docs e mensagens de erro para deixar claro que timeout e o mecanismo oficial.
3. Marcar `cancelStatement` como "best-effort / unsupported".

### Testes

1. Estrategia 1:
   - cancelar query longa.
   - cancelar statement inexistente.
   - corrida cancel x close.
2. Estrategia 2:
   - erro deterministico e documentado.
   - fallback para timeout coberto por teste.

### Criterio de aceite

- Nao pode haver ambiguidade entre API publica e comportamento real.

## Itens transversais (todos os GAPs)

1. Versionamento e ABI:
   - toda mudanca de surface FFI atualiza header/export e nota de compatibilidade.
   - revisar `doc/VERSIONING_STRATEGY.md` e `doc/VERSIONING_QUICK_REFERENCE.md`.
2. CI:
   - adicionar jobs/etapas para validar simbolos exportados vs bindings Dart.
3. Rebuild e distribuicao da DLL:
   - atualizar `doc/BUILD.md`, `doc/TROUBLESHOOTING.md` e processo de release.
4. Qualidade:
   - rodar `cargo test --workspace --all-targets --all-features`.
   - rodar `dart test`.
   - rodar lint Rust/Dart.

## Matriz de entrega (DoD por fase)

## Fase 1

1. GAP 1 concluido.
2. GAP 3 concluido.
3. Tests Rust/Dart verdes.
4. Docs e changelog atualizados.

## Fase 2

1. GAP 2 concluido.
2. Tests de streaming async com casos grandes e regressao.
3. Sem aumento relevante de uso de memoria em cenarios de stream.

## Fase 3

1. GAP 4 concluido.
2. Benchmark minimo publicado.
3. Exemplo atualizado.

## Fase 4

1. GAP 5 concluido (estrategia escolhida e implementada).
2. API e documentacao sem contradicoes.

## Riscos e mitigacao

1. Divergencia de assinatura FFI entre Rust e Dart.
   - Mitigacao: teste automatico de simbolos e smoke test de bind.
2. Regressao em async isolate.
   - Mitigacao: testes de stress leves + cenarios de timeout/dispose.
3. Quebra de compatibilidade para usuarios com DLL antiga.
   - Mitigacao: fallback com erro claro e politica de versao explicita.
4. Variacao de driver ODBC entre ambientes.
   - Mitigacao: testes com matriz minima de drivers suportados.

## Checklist executivo

- [x] GAP 1 implementado e validado.
- [x] GAP 2 implementado e validado.
- [x] GAP 3 implementado e validado.
- [x] GAP 4 implementado e validado.
- [ ] GAP 5 implementado e validado.
- [x] Documentacao atualizada (README + doc/* relevantes).
- [x] Changelog atualizado.
- [ ] Build/release process atualizado.
