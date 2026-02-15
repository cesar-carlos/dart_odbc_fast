# PERFORMANCE_RELIABILITY_IMPLEMENTATION_PLAN.md

Plano detalhado para melhorias de desempenho e confiabilidade no stack Dart + Rust (FFI + isolate + pool).

## Objetivo

Melhorar latencia, throughput e previsibilidade operacional sem quebrar compatibilidade publica.

## Data de referencia

- 2026-02-15

## Baseline (estado atual)

Principais pontos observados no codigo:

1. Streaming async pode encerrar silenciosamente em falha (`return` sem erro):
   - `lib/infrastructure/native/async_native_odbc_connection.dart`
2. Recuperacao do worker pode disparar em paralelo via `onError` e `onDone`:
   - `lib/infrastructure/native/async_native_odbc_connection.dart`
3. `getMetrics()` sync faz multiplas chamadas FFI para o mesmo snapshot:
   - `lib/infrastructure/native/native_odbc_connection.dart`
4. Bulk insert no repositorio copia buffer (`Uint8List.fromList`) em caminhos quentes:
   - `lib/infrastructure/repositories/odbc_repository_impl.dart`
5. Pool faz validacao com query no checkout (`test_on_check_out(true)` + `SELECT 1`):
   - `native/odbc_engine/src/pool/mod.rs`
6. Alguns caminhos Rust de runtime ainda usam `unwrap/expect`:
   - `native/odbc_engine/src/async_bridge/mod.rs`
   - `native/odbc_engine/src/pool/mod.rs`
   - `native/odbc_engine/src/observability/telemetry/mod.rs`

## Metas tecnicas (DoD global)

1. Nenhum erro de streaming async pode ser perdido silenciosamente.
2. Recuperacao de worker deve ser serializada (uma recuperacao por vez).
3. Reduzir alocacoes/copias em caminhos quentes de bulk insert.
4. Eliminar panic evitavel em runtime de producao.
5. Manter `dart analyze`, `dart test` e `cargo test -p odbc_engine --lib` verdes.
6. Atualizar documentacao de operacao e troubleshooting ao final de cada fase.

## Fase 0 - Medicao e guardrails

### Implementacao

1. Definir cenarios padrao de benchmark:
   - query pequena, media e grande
   - streaming sync e async
   - bulk insert array vs parallel
2. Padronizar variaveis de ambiente de benchmark em documento unico.
3. Registrar baseline de throughput, latencia p95 e uso de memoria.

### Testes

1. `dart test`
2. `cargo test -p odbc_engine --lib`
3. benchmark Rust de bulk (`e2e_bulk_compare_benchmark_test`)

### Documentacao

1. Atualizar `README.md` (secao de benchmark e comandos)
2. Atualizar `doc/BUILD.md` (como reproduzir benchmarks)

## Fase 1 - Confiabilidade critica (baixo risco, alto impacto)

### Item 1.1 - Propagacao de erro no streaming async

Arquivos alvo:

- `lib/infrastructure/native/async_native_odbc_connection.dart`

Mudancas:

1. Substituir `return` silencioso por `throw AsyncError` com contexto.
2. Preservar fechamento de stream em `finally`.
3. Incluir mensagem de erro do worker/nativo quando disponivel.

Testes:

1. erro em `streamStart`
2. erro em `streamFetch` no meio do fluxo
3. garantia de `streamClose` mesmo com excecao

### Item 1.2 - Recuperacao de worker sem corrida

Arquivos alvo:

- `lib/infrastructure/native/async_native_odbc_connection.dart`

Mudancas:

1. Introduzir lock logico (`_isRecovering` ou `Completer<void> _recovering`).
2. `onError` e `onDone` devem reutilizar a mesma recuperacao em andamento.
3. Evitar `dispose/initialize` concorrente.

Testes:

1. simular `onError` e `onDone` quase simultaneos
2. validar que apenas uma recuperacao roda
3. validar falha previsivel para requests em voo

### Item 1.3 - Remover panic evitavel em runtime Rust

Arquivos alvo (inicial):

- `native/odbc_engine/src/async_bridge/mod.rs`
- `native/odbc_engine/src/pool/mod.rs`
- `native/odbc_engine/src/observability/telemetry/mod.rs`

Mudancas:

1. Trocar `unwrap/expect` em caminhos de runtime por tratamento de erro.
2. Converter lock poisoned para erro controlado.
3. Registrar erro estruturado quando aplicavel.

Testes:

1. testes unitarios de erro de inicializacao runtime/pool
2. testes FFI para codigos de erro, sem panic

### Documentacao da Fase 1

1. `doc/TROUBLESHOOTING.md` (novos sintomas e mensagens)
2. `doc/OBSERVABILITY.md` (comportamento de erro/recovery)
3. `CHANGELOG.md`

## Fase 2 - Performance imediata (baixo risco)

### Item 2.1 - Snapshot unico em `getMetrics()`

Arquivo alvo:

- `lib/infrastructure/native/native_odbc_connection.dart`

Mudancas:

1. chamar `_native.getMetrics()` uma vez
2. montar `OdbcMetrics` a partir do mesmo snapshot

Teste:

1. unit test garantindo apenas um fetch (mock/spy)

### Item 2.2 - Evitar copia desnecessaria em bulk insert

Arquivo alvo:

- `lib/infrastructure/repositories/odbc_repository_impl.dart`

Mudancas:

1. evitar `Uint8List.fromList` quando `dataBuffer` ja for `Uint8List`
2. avaliar overload interno para aceitar `Uint8List` direto
3. manter compatibilidade da API publica

Testes:

1. unit test de caminho sem copia
2. regressao de bulk insert sync/async

### Item 2.3 - Pool health-check configuravel no checkout

Arquivo alvo:

- `native/odbc_engine/src/pool/mod.rs`

Mudancas:

1. tornar `test_on_check_out` configuravel
2. manter default seguro para compatibilidade
3. adicionar modo de alta performance para cargas controladas

Testes:

1. pool com validacao ligada/desligada
2. comparativo simples de latencia de checkout

### Documentacao da Fase 2

1. `README.md` (flags/recomendacoes de performance)
2. `doc/BUILD.md` (parametros de execucao)
3. `doc/TROUBLESHOOTING.md` (trade-off seguranca vs latencia)
4. `CHANGELOG.md`

## Fase 3 - Streaming escalavel no alto nivel

### Item 3.1 - API de consumo incremental no repositorio/servico

Arquivos candidatos:

- `lib/domain/repositories/odbc_repository.dart`
- `lib/application/services/odbc_service.dart`
- `lib/infrastructure/repositories/odbc_repository_impl.dart`

Mudancas:

1. introduzir caminho opcional de stream sem materializar todos os rows
2. manter API atual para compatibilidade
3. documentar quando usar stream vs resultado completo

Testes:

1. integracao com dataset grande sem crescimento excessivo de memoria
2. equivalencia funcional entre modo stream e modo completo

### Item 3.2 - Fallback de streaming mais robusto

Arquivo alvo:

- `lib/infrastructure/repositories/odbc_repository_impl.dart`

Mudancas:

1. ajustar fallback para capturar falhas no consumo (nao apenas na criacao do stream)
2. distinguir erro de protocolo, erro SQL e timeout

Testes:

1. falha durante iteracao
2. timeout de query em streaming
3. cancelamento/dispose no meio do fluxo

### Documentacao da Fase 3

1. `README.md` (guia de streaming em producao)
2. `doc/TROUBLESHOOTING.md` (erros de stream)
3. `CHANGELOG.md`

## Fase 4 - Hardening final e rollout

### Implementacao

1. revisar limites e defaults de timeout/retry/pool
2. checklist de backward compatibility de FFI
3. smoke de release em Windows e Linux

### Testes finais

1. `dart analyze`
2. `dart test`
3. `cargo test -p odbc_engine --lib`
4. execucao manual de exemplos chave:
   - `example/async_demo.dart`
   - `example/streaming_demo.dart`
   - `example/pool_demo.dart`

### Documentacao final

1. `README.md` (estado final consolidado)
2. `doc/OBSERVABILITY.md`
3. `doc/TROUBLESHOOTING.md`
4. `doc/VERSIONING_QUICK_REFERENCE.md` (se houver mudanca de surface/ABI)
5. `CHANGELOG.md`

## Sequencia recomendada de execucao

1. Fase 0
2. Fase 1
3. Fase 2
4. Fase 3
5. Fase 4

## Checklist executivo

- [ ] Fase 0 concluida
- [ ] Fase 1 concluida
- [ ] Fase 2 concluida
- [ ] Fase 3 concluida
- [ ] Fase 4 concluida
- [ ] Documentacao consolidada e sem contradicao
- [ ] Pronto para release

