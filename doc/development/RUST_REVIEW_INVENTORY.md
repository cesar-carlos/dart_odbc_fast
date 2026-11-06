# Inventário de revisão Rust

Registro da campanha: **2026-11-06**. Base Git: `322fc1418bee76da8d28bab4bb5f02ac357f0b71`.
O inventário representa a árvore de trabalho, incluindo alterações ainda não commitadas.
Os hashes por arquivo identificam o conteúdo avaliado; o commit sozinho não representa esse conteúdo.

## Critério e limites

- Unidade auditável: um arquivo `.rs` da biblioteca em `native/odbc_engine/src/`, incluindo `lib.rs` e `mod.rs`.
- Todos os arquivos são contados independentemente da feature ou plataforma. Módulos inline não viram unidades adicionais.
- Arquivos dedicados a testes (`tests/`, `tests.rs`, `*_test.rs`, `*_tests.rs`) ficam no inventário de apoio.
- `engine/transaction/test_helpers.rs` integra o denominador: é declarado sem `cfg(test)`, apesar do nome.
- Build scripts, benchmarks, exemplos e a crate de modelos Loom ficam separados. Diretórios ocultos, `target/` e links simbólicos são excluídos.
- **Integral:** registro explícito da revisão do arquivo inteiro, com responsabilidades, contratos, erros, ownership/unsafe e validação pertinente documentados.
- **Parcial:** revisão focal ou triagem de trechos identificados. Não recebe peso arbitrário de 50% e não significa que o restante do arquivo foi auditado.
- **Não revisado:** ausência de evidência registrada nesta campanha, ou registro invalidado por mudança de conteúdo. Não afirma que ninguém revisou esse código em outro momento.
- Listar arquivos, consultar tipos/imports, executar testes ou conferir exportações FFI não concede revisão automática aos módulos.
- As revisões anteriores foram focais. Nenhum módulo de produção tem registro suficiente para ser declarado integralmente revisado.
- Linhas físicas incluem comentários e testes inline; servem apenas para dimensionamento. Não são usadas como percentual de código revisado.

## Percentuais defensáveis

| Medida | Cálculo | Resultado |
| --- | --- | ---: |
| Revisão integral documentada | 0 / 230 | 0.00% |
| Alcance da revisão, incluindo parciais | 9 / 230 | 3.91% |
| Revisão focal com testes/benchmarks específicos | 3 / 230 | 1.30% |

**O percentual de alcance mede arquivos com algum trecho revisado, não a fração de lógica integralmente auditada.**
Não há rastreabilidade suficiente de cada linha, função ou ramo para calcular esse segundo percentual sem inventar pesos.

Total: **375 arquivos Rust**, sendo **230 de produção** e **145 de apoio**.

## Resumo por área de produção

| Área | Arquivos | Integral | Parcial | Não revisado |
| --- | ---: | ---: | ---: | ---: |
| `async_bridge` | 1 | 0 | 0 | 1 |
| `engine` | 76 | 0 | 3 | 73 |
| `error` | 1 | 0 | 0 | 1 |
| `ffi` | 41 | 0 | 0 | 41 |
| `handles` | 3 | 0 | 0 | 3 |
| `lib.rs` | 1 | 0 | 0 | 1 |
| `observability` | 7 | 0 | 0 | 7 |
| `plugins` | 70 | 0 | 0 | 70 |
| `pool` | 3 | 0 | 0 | 3 |
| `protocol` | 17 | 0 | 6 | 11 |
| `security` | 6 | 0 | 0 | 6 |
| `versioning` | 4 | 0 | 0 | 4 |

## Escopos efetivamente registrados

As referências de teste sustentam somente o escopo descrito; aprovação da suíte completa não amplia esse escopo.

### `native/odbc_engine/benches/decoder_validation_bench.rs`

Estado: **Parcial**. Evidência: Validação de apoio. Categoria: benchmarks.

Fixtures de framing inválido e controles válidos utilizadas nas medições registradas. Não atribui revisão aos demais caminhos do motor.

Referências: [doc/PERFORMANCE.md](../../doc/PERFORMANCE.md).

### `native/odbc_engine/benches/encoder_bench.rs`

Estado: **Parcial**. Evidência: Validação de apoio. Categoria: benchmarks.

Grupo numeric_columnar e controles selecionados de tipos mistos e compressão. Não houve revisão integral de todos os grupos de benchmark.

Referências: [doc/PERFORMANCE.md](../../doc/PERFORMANCE.md).

### `native/odbc_engine/benches/fallback_transpose_bench.rs`

Estado: **Parcial**. Evidência: Validação de apoio. Categoria: benchmarks.

Grupo transpose_capacity e controles de reutilização usados para avaliar a reserva dos vetores.

Referências: [doc/PERFORMANCE.md](../../doc/PERFORMANCE.md).

### `native/odbc_engine/examples/compression_paired_bench.rs`

Estado: **Parcial**. Evidência: Validação de apoio. Categoria: benchmarks.

Referência sem reserva inicial, comparação de bytes, alternância pareada e cálculo das medições usados na validação focal. Não equivale a auditoria estatística independente ou a revisão integral do código incluído.

Referências: [doc/PERFORMANCE.md](../../doc/PERFORMANCE.md).

### `native/odbc_engine/src/engine/core/metadata_cache.rs`

Estado: **Parcial**. Evidência: Triagem preliminar. Categoria: producao.

Triagem de buscas/inserções, compartilhamento por Arc, TTL e remoção de payloads. Sem auditoria sistemática de concorrência, envenenamento de mutex, invalidação ou política completa de cache.

### `native/odbc_engine/src/engine/core/prepared_cache.rs`

Estado: **Parcial**. Evidência: Triagem preliminar. Categoria: producao.

Triagem de get_or_insert e dos contadores record_hit, record_prepare e record_execution. Sem revisão integral das métricas, limpeza, invalidação ou concorrência.

### `native/odbc_engine/src/engine/streaming/columns.rs`

Estado: **Parcial**. Evidência: Triagem preliminar. Categoria: producao.

Inspeção de FallbackColumnarEncoder::new/encode_into para localizar o uso do conversor e do workspace de compressão. A descoberta de metadados do driver e todos os caminhos de streaming não foram auditados.

### `native/odbc_engine/src/protocol/bound_param.rs`

Estado: **Parcial**. Evidência: Triagem preliminar. Categoria: producao.

Triagem da decodificação DRT1/legada, limites de contagem e conversão para parâmetros de entrada. Sem alteração ou nova validação específica deste módulo; outras direções, binding e todos os casos malformados não foram auditados.

### `native/odbc_engine/src/protocol/columnar_encoder.rs`

Estado: **Parcial**. Evidência: Revisão focal com testes/benchmarks. Categoria: producao.

Planejamento do tamanho numérico, escrita de payload em Vec, reserva/reutilização do scratch e decisões de compressão nos caminhos medidos. Testes de bytes, fronteiras, prefixos, frames vazios e orçamento de alocações. A avaliação foi focal em correção e desempenho; não equivale a auditoria integral de todos os limites, falhas de recurso e combinações de flags.

Referências: [native/odbc_engine/tests/columnar_compression_allocation_test.rs](../../native/odbc_engine/tests/columnar_compression_allocation_test.rs), [native/odbc_engine/benches/encoder_bench.rs](../../native/odbc_engine/benches/encoder_bench.rs), [native/odbc_engine/examples/compression_paired_bench.rs](../../native/odbc_engine/examples/compression_paired_bench.rs), [doc/PERFORMANCE.md](../../doc/PERFORMANCE.md).

### `native/odbc_engine/src/protocol/converter.rs`

Estado: **Parcial**. Evidência: Revisão focal com testes/benchmarks. Categoria: producao.

Reserva e reutilização dos vetores em transpose_row_buffer_into, com equivalência de bytes para crescimento/redução de lotes, NULLs, strings e binários. Não houve auditoria completa do mapeamento de todos os tipos ODBC ou de todas as combinações de entrada.

Referências: [native/odbc_engine/src/protocol/converter.rs](../../native/odbc_engine/src/protocol/converter.rs), [native/odbc_engine/benches/fallback_transpose_bench.rs](../../native/odbc_engine/benches/fallback_transpose_bench.rs), [doc/PERFORMANCE.md](../../doc/PERFORMANCE.md).

### `native/odbc_engine/src/protocol/decoder/mod.rs`

Estado: **Parcial**. Evidência: Revisão focal com testes/benchmarks. Categoria: producao.

Revisão focal da validação do tamanho do payload antes das alocações. Regressão de cabeçalho inválido reproduzida, limite de alocação verificado e entradas válidas comparadas. Não houve auditoria integral de todos os discriminantes, flags, entradas malformadas e contratos do decoder.

Referências: [native/odbc_engine/tests/decoder_allocation_test.rs](../../native/odbc_engine/tests/decoder_allocation_test.rs), [native/odbc_engine/benches/decoder_validation_bench.rs](../../native/odbc_engine/benches/decoder_validation_bench.rs), [doc/PERFORMANCE.md](../../doc/PERFORMANCE.md).

### `native/odbc_engine/src/protocol/decoder/tests.rs`

Estado: **Parcial**. Evidência: Validação de apoio. Categoria: testes.

Casos editados de framing e preservação de linhas sem colunas. Não há registro de revisão integral de todos os testes do arquivo.

Referências: [native/odbc_engine/src/protocol/decoder/mod.rs](../../native/odbc_engine/src/protocol/decoder/mod.rs).

### `native/odbc_engine/src/protocol/encoder/mod.rs`

Estado: **Parcial**. Evidência: Triagem preliminar. Categoria: producao.

Triagem dos caminhos Vec/Write e do footer OUT1 em busca de alocações. Sem correção aplicada neste módulo; medição de shape, demais footers e limites não receberam revisão integral.

### `native/odbc_engine/src/protocol/param_value/mod.rs`

Estado: **Parcial**. Evidência: Triagem preliminar. Categoria: producao.

Triagem da serialização/deserialização inicial, limites de payload/contagem e conversão para strings. A parte restante de binding ODBC, inferência e descrições de parâmetros não foi revisada integralmente.

### `native/odbc_engine/tests/columnar_compression_allocation_test.rs`

Estado: **Parcial**. Evidência: Validação de apoio. Categoria: testes.

Regressão do orçamento de alocações/realocações de lote comprimido pequeno, criada e executada antes/depois.

Referências: [doc/PERFORMANCE.md](../../doc/PERFORMANCE.md).

### `native/odbc_engine/tests/decoder_allocation_test.rs`

Estado: **Parcial**. Evidência: Validação de apoio. Categoria: testes.

Regressão de alocação para cabeçalho inválido, criada e executada antes/depois. Validação focal de apoio; não é revisão integral do subsistema de memória.

Referências: [doc/PERFORMANCE.md](../../doc/PERFORMANCE.md).

## Como manter este registro

A fonte de decisões é [rust_review_ledger.json](rust_review_ledger.json). O relatório e o
[inventário completo em JSON](rust_review_inventory.json) são gerados, sem promover estados automaticamente.
Cada decisão contém escopo, nível de evidência e SHA-256 do texto com quebras de linha normalizadas para LF.
Se um arquivo mudar, seu estado efetivo passa a não revisado até reavaliação explícita. Arquivos novos também começam nesse estado.

```powershell
python scripts/inventory_rust_review.py
python scripts/inventory_rust_review.py --check
```

Atualizar o hash no ledger exige reavaliar o escopo registrado; regenerar o relatório não substitui revisão.

## Inventário completo de produção

| Arquivo/unidade | Estado | Nível | Linhas físicas |
| --- | --- | --- | ---: |
| [native/odbc_engine/src/async_bridge/mod.rs](../../native/odbc_engine/src/async_bridge/mod.rs) | Não revisado | Sem evidência de revisão | 195 |
| [native/odbc_engine/src/engine/catalog/adapters.rs](../../native/odbc_engine/src/engine/catalog/adapters.rs) | Não revisado | Sem evidência de revisão | 88 |
| [native/odbc_engine/src/engine/catalog/mod.rs](../../native/odbc_engine/src/engine/catalog/mod.rs) | Não revisado | Sem evidência de revisão | 189 |
| [native/odbc_engine/src/engine/catalog/parsing.rs](../../native/odbc_engine/src/engine/catalog/parsing.rs) | Não revisado | Sem evidência de revisão | 149 |
| [native/odbc_engine/src/engine/catalog/query_builders.rs](../../native/odbc_engine/src/engine/catalog/query_builders.rs) | Não revisado | Sem evidência de revisão | 414 |
| [native/odbc_engine/src/engine/cell_reader.rs](../../native/odbc_engine/src/engine/cell_reader.rs) | Não revisado | Sem evidência de revisão | 386 |
| [native/odbc_engine/src/engine/connection.rs](../../native/odbc_engine/src/engine/connection.rs) | Não revisado | Sem evidência de revisão | 323 |
| [native/odbc_engine/src/engine/core/array_binding/column_buffers.rs](../../native/odbc_engine/src/engine/core/array_binding/column_buffers.rs) | Não revisado | Sem evidência de revisão | 204 |
| [native/odbc_engine/src/engine/core/array_binding/insert_sql.rs](../../native/odbc_engine/src/engine/core/array_binding/insert_sql.rs) | Não revisado | Sem evidência de revisão | 29 |
| [native/odbc_engine/src/engine/core/array_binding/mod.rs](../../native/odbc_engine/src/engine/core/array_binding/mod.rs) | Não revisado | Sem evidência de revisão | 412 |
| [native/odbc_engine/src/engine/core/array_binding/validation.rs](../../native/odbc_engine/src/engine/core/array_binding/validation.rs) | Não revisado | Sem evidência de revisão | 22 |
| [native/odbc_engine/src/engine/core/batch_executor/execution.rs](../../native/odbc_engine/src/engine/core/batch_executor/execution.rs) | Não revisado | Sem evidência de revisão | 129 |
| [native/odbc_engine/src/engine/core/batch_executor/inference.rs](../../native/odbc_engine/src/engine/core/batch_executor/inference.rs) | Não revisado | Sem evidência de revisão | 12 |
| [native/odbc_engine/src/engine/core/batch_executor/mod.rs](../../native/odbc_engine/src/engine/core/batch_executor/mod.rs) | Não revisado | Sem evidência de revisão | 435 |
| [native/odbc_engine/src/engine/core/batch_executor/planning.rs](../../native/odbc_engine/src/engine/core/batch_executor/planning.rs) | Não revisado | Sem evidência de revisão | 187 |
| [native/odbc_engine/src/engine/core/block_fetch/column_buffers.rs](../../native/odbc_engine/src/engine/core/block_fetch/column_buffers.rs) | Não revisado | Sem evidência de revisão | 433 |
| [native/odbc_engine/src/engine/core/block_fetch/driver_adapters.rs](../../native/odbc_engine/src/engine/core/block_fetch/driver_adapters.rs) | Não revisado | Sem evidência de revisão | 286 |
| [native/odbc_engine/src/engine/core/block_fetch/fetch_loop.rs](../../native/odbc_engine/src/engine/core/block_fetch/fetch_loop.rs) | Não revisado | Sem evidência de revisão | 103 |
| [native/odbc_engine/src/engine/core/block_fetch/mod.rs](../../native/odbc_engine/src/engine/core/block_fetch/mod.rs) | Não revisado | Sem evidência de revisão | 41 |
| [native/odbc_engine/src/engine/core/block_fetch/streaming_session.rs](../../native/odbc_engine/src/engine/core/block_fetch/streaming_session.rs) | Não revisado | Sem evidência de revisão | 114 |
| [native/odbc_engine/src/engine/core/bulk_copy.rs](../../native/odbc_engine/src/engine/core/bulk_copy.rs) | Não revisado | Sem evidência de revisão | 366 |
| [native/odbc_engine/src/engine/core/columnar_fetch.rs](../../native/odbc_engine/src/engine/core/columnar_fetch.rs) | Não revisado | Sem evidência de revisão | 438 |
| [native/odbc_engine/src/engine/core/connection_manager.rs](../../native/odbc_engine/src/engine/core/connection_manager.rs) | Não revisado | Sem evidência de revisão | 247 |
| [native/odbc_engine/src/engine/core/disk_spill.rs](../../native/odbc_engine/src/engine/core/disk_spill.rs) | Não revisado | Sem evidência de revisão | 307 |
| [native/odbc_engine/src/engine/core/driver_capabilities.rs](../../native/odbc_engine/src/engine/core/driver_capabilities.rs) | Não revisado | Sem evidência de revisão | 616 |
| [native/odbc_engine/src/engine/core/execution/mod.rs](../../native/odbc_engine/src/engine/core/execution/mod.rs) | Não revisado | Sem evidência de revisão | 652 |
| [native/odbc_engine/src/engine/core/execution/multi_result_collect.rs](../../native/odbc_engine/src/engine/core/execution/multi_result_collect.rs) | Não revisado | Sem evidência de revisão | 315 |
| [native/odbc_engine/src/engine/core/execution/param_binding.rs](../../native/odbc_engine/src/engine/core/execution/param_binding.rs) | Não revisado | Sem evidência de revisão | 120 |
| [native/odbc_engine/src/engine/core/execution/result_encoding.rs](../../native/odbc_engine/src/engine/core/execution/result_encoding.rs) | Não revisado | Sem evidência de revisão | 363 |
| [native/odbc_engine/src/engine/core/memory_engine.rs](../../native/odbc_engine/src/engine/core/memory_engine.rs) | Não revisado | Sem evidência de revisão | 162 |
| [native/odbc_engine/src/engine/core/metadata_cache.rs](../../native/odbc_engine/src/engine/core/metadata_cache.rs) | Parcial | Triagem preliminar | 530 |
| [native/odbc_engine/src/engine/core/mod.rs](../../native/odbc_engine/src/engine/core/mod.rs) | Não revisado | Sem evidência de revisão | 44 |
| [native/odbc_engine/src/engine/core/output_aware_params.rs](../../native/odbc_engine/src/engine/core/output_aware_params.rs) | Não revisado | Sem evidência de revisão | 531 |
| [native/odbc_engine/src/engine/core/parallel_insert.rs](../../native/odbc_engine/src/engine/core/parallel_insert.rs) | Não revisado | Sem evidência de revisão | 368 |
| [native/odbc_engine/src/engine/core/pipeline.rs](../../native/odbc_engine/src/engine/core/pipeline.rs) | Não revisado | Sem evidência de revisão | 374 |
| [native/odbc_engine/src/engine/core/prepared_cache.rs](../../native/odbc_engine/src/engine/core/prepared_cache.rs) | Parcial | Triagem preliminar | 294 |
| [native/odbc_engine/src/engine/core/protocol_engine.rs](../../native/odbc_engine/src/engine/core/protocol_engine.rs) | Não revisado | Sem evidência de revisão | 291 |
| [native/odbc_engine/src/engine/core/ref_cursor_oracle.rs](../../native/odbc_engine/src/engine/core/ref_cursor_oracle.rs) | Não revisado | Sem evidência de revisão | 205 |
| [native/odbc_engine/src/engine/core/security_layer.rs](../../native/odbc_engine/src/engine/core/security_layer.rs) | Não revisado | Sem evidência de revisão | 111 |
| [native/odbc_engine/src/engine/core/sqlserver_bcp/bound_column.rs](../../native/odbc_engine/src/engine/core/sqlserver_bcp/bound_column.rs) | Não revisado | Sem evidência de revisão | 129 |
| [native/odbc_engine/src/engine/core/sqlserver_bcp/execute.rs](../../native/odbc_engine/src/engine/core/sqlserver_bcp/execute.rs) | Não revisado | Sem evidência de revisão | 186 |
| [native/odbc_engine/src/engine/core/sqlserver_bcp/helpers.rs](../../native/odbc_engine/src/engine/core/sqlserver_bcp/helpers.rs) | Não revisado | Sem evidência de revisão | 37 |
| [native/odbc_engine/src/engine/core/sqlserver_bcp/library.rs](../../native/odbc_engine/src/engine/core/sqlserver_bcp/library.rs) | Não revisado | Sem evidência de revisão | 118 |
| [native/odbc_engine/src/engine/core/sqlserver_bcp/mod.rs](../../native/odbc_engine/src/engine/core/sqlserver_bcp/mod.rs) | Não revisado | Sem evidência de revisão | 70 |
| [native/odbc_engine/src/engine/core/sqlserver_bcp/payload.rs](../../native/odbc_engine/src/engine/core/sqlserver_bcp/payload.rs) | Não revisado | Sem evidência de revisão | 114 |
| [native/odbc_engine/src/engine/dbms_info.rs](../../native/odbc_engine/src/engine/dbms_info.rs) | Não revisado | Sem evidência de revisão | 248 |
| [native/odbc_engine/src/engine/environment.rs](../../native/odbc_engine/src/engine/environment.rs) | Não revisado | Sem evidência de revisão | 74 |
| [native/odbc_engine/src/engine/fetch.rs](../../native/odbc_engine/src/engine/fetch.rs) | Não revisado | Sem evidência de revisão | 149 |
| [native/odbc_engine/src/engine/identifier.rs](../../native/odbc_engine/src/engine/identifier.rs) | Não revisado | Sem evidência de revisão | 260 |
| [native/odbc_engine/src/engine/mod.rs](../../native/odbc_engine/src/engine/mod.rs) | Não revisado | Sem evidência de revisão | 75 |
| [native/odbc_engine/src/engine/odbc_get_info.rs](../../native/odbc_engine/src/engine/odbc_get_info.rs) | Não revisado | Sem evidência de revisão | 216 |
| [native/odbc_engine/src/engine/query.rs](../../native/odbc_engine/src/engine/query.rs) | Não revisado | Sem evidência de revisão | 501 |
| [native/odbc_engine/src/engine/session_defaults.rs](../../native/odbc_engine/src/engine/session_defaults.rs) | Não revisado | Sem evidência de revisão | 64 |
| [native/odbc_engine/src/engine/sqlserver_json.rs](../../native/odbc_engine/src/engine/sqlserver_json.rs) | Não revisado | Sem evidência de revisão | 262 |
| [native/odbc_engine/src/engine/statement.rs](../../native/odbc_engine/src/engine/statement.rs) | Não revisado | Sem evidência de revisão | 140 |
| [native/odbc_engine/src/engine/streaming/batched_fetch.rs](../../native/odbc_engine/src/engine/streaming/batched_fetch.rs) | Não revisado | Sem evidência de revisão | 299 |
| [native/odbc_engine/src/engine/streaming/chunk.rs](../../native/odbc_engine/src/engine/streaming/chunk.rs) | Não revisado | Sem evidência de revisão | 252 |
| [native/odbc_engine/src/engine/streaming/columns.rs](../../native/odbc_engine/src/engine/streaming/columns.rs) | Parcial | Triagem preliminar | 136 |
| [native/odbc_engine/src/engine/streaming/mod.rs](../../native/odbc_engine/src/engine/streaming/mod.rs) | Não revisado | Sem evidência de revisão | 32 |
| [native/odbc_engine/src/engine/streaming/multi_result.rs](../../native/odbc_engine/src/engine/streaming/multi_result.rs) | Não revisado | Sem evidência de revisão | 736 |
| [native/odbc_engine/src/engine/streaming/state.rs](../../native/odbc_engine/src/engine/streaming/state.rs) | Não revisado | Sem evidência de revisão | 587 |
| [native/odbc_engine/src/engine/streaming/worker.rs](../../native/odbc_engine/src/engine/streaming/worker.rs) | Não revisado | Sem evidência de revisão | 736 |
| [native/odbc_engine/src/engine/transaction/dialect_sql.rs](../../native/odbc_engine/src/engine/transaction/dialect_sql.rs) | Não revisado | Sem evidência de revisão | 433 |
| [native/odbc_engine/src/engine/transaction/lifecycle.rs](../../native/odbc_engine/src/engine/transaction/lifecycle.rs) | Não revisado | Sem evidência de revisão | 460 |
| [native/odbc_engine/src/engine/transaction/mod.rs](../../native/odbc_engine/src/engine/transaction/mod.rs) | Não revisado | Sem evidência de revisão | 302 |
| [native/odbc_engine/src/engine/transaction/savepoint.rs](../../native/odbc_engine/src/engine/transaction/savepoint.rs) | Não revisado | Sem evidência de revisão | 130 |
| [native/odbc_engine/src/engine/transaction/test_helpers.rs](../../native/odbc_engine/src/engine/transaction/test_helpers.rs) | Não revisado | Sem evidência de revisão | 144 |
| [native/odbc_engine/src/engine/wide_text.rs](../../native/odbc_engine/src/engine/wide_text.rs) | Não revisado | Sem evidência de revisão | 92 |
| [native/odbc_engine/src/engine/xa/apply.rs](../../native/odbc_engine/src/engine/xa/apply.rs) | Não revisado | Sem evidência de revisão | 444 |
| [native/odbc_engine/src/engine/xa/hex.rs](../../native/odbc_engine/src/engine/xa/hex.rs) | Não revisado | Sem evidência de revisão | 43 |
| [native/odbc_engine/src/engine/xa/mod.rs](../../native/odbc_engine/src/engine/xa/mod.rs) | Não revisado | Sem evidência de revisão | 79 |
| [native/odbc_engine/src/engine/xa/mssql.rs](../../native/odbc_engine/src/engine/xa/mssql.rs) | Não revisado | Sem evidência de revisão | 39 |
| [native/odbc_engine/src/engine/xa/oracle.rs](../../native/odbc_engine/src/engine/xa/oracle.rs) | Não revisado | Sem evidência de revisão | 55 |
| [native/odbc_engine/src/engine/xa/transaction.rs](../../native/odbc_engine/src/engine/xa/transaction.rs) | Não revisado | Sem evidência de revisão | 729 |
| [native/odbc_engine/src/engine/xa/xid.rs](../../native/odbc_engine/src/engine/xa/xid.rs) | Não revisado | Sem evidência de revisão | 172 |
| [native/odbc_engine/src/engine/xa_dtc.rs](../../native/odbc_engine/src/engine/xa_dtc.rs) | Não revisado | Sem evidência de revisão | 352 |
| [native/odbc_engine/src/engine/xa_oci.rs](../../native/odbc_engine/src/engine/xa_oci.rs) | Não revisado | Sem evidência de revisão | 587 |
| [native/odbc_engine/src/error/mod.rs](../../native/odbc_engine/src/error/mod.rs) | Não revisado | Sem evidência de revisão | 612 |
| [native/odbc_engine/src/ffi/bulk.rs](../../native/odbc_engine/src/ffi/bulk.rs) | Não revisado | Sem evidência de revisão | 416 |
| [native/odbc_engine/src/ffi/capabilities/helpers.rs](../../native/odbc_engine/src/ffi/capabilities/helpers.rs) | Não revisado | Sem evidência de revisão | 231 |
| [native/odbc_engine/src/ffi/capabilities/mod.rs](../../native/odbc_engine/src/ffi/capabilities/mod.rs) | Não revisado | Sem evidência de revisão | 474 |
| [native/odbc_engine/src/ffi/capped_writer.rs](../../native/odbc_engine/src/ffi/capped_writer.rs) | Não revisado | Sem evidência de revisão | 239 |
| [native/odbc_engine/src/ffi/catalog.rs](../../native/odbc_engine/src/ffi/catalog.rs) | Não revisado | Sem evidência de revisão | 294 |
| [native/odbc_engine/src/ffi/columnar_decompress.rs](../../native/odbc_engine/src/ffi/columnar_decompress.rs) | Não revisado | Sem evidência de revisão | 351 |
| [native/odbc_engine/src/ffi/connection.rs](../../native/odbc_engine/src/ffi/connection.rs) | Não revisado | Sem evidência de revisão | 261 |
| [native/odbc_engine/src/ffi/diagnostics.rs](../../native/odbc_engine/src/ffi/diagnostics.rs) | Não revisado | Sem evidência de revisão | 277 |
| [native/odbc_engine/src/ffi/global.rs](../../native/odbc_engine/src/ffi/global.rs) | Não revisado | Sem evidência de revisão | 431 |
| [native/odbc_engine/src/ffi/global_state.rs](../../native/odbc_engine/src/ffi/global_state.rs) | Não revisado | Sem evidência de revisão | 405 |
| [native/odbc_engine/src/ffi/guard.rs](../../native/odbc_engine/src/ffi/guard.rs) | Não revisado | Sem evidência de revisão | 432 |
| [native/odbc_engine/src/ffi/init.rs](../../native/odbc_engine/src/ffi/init.rs) | Não revisado | Sem evidência de revisão | 174 |
| [native/odbc_engine/src/ffi/mod.rs](../../native/odbc_engine/src/ffi/mod.rs) | Não revisado | Sem evidência de revisão | 46 |
| [native/odbc_engine/src/ffi/pool/alloc_id.rs](../../native/odbc_engine/src/ffi/pool/alloc_id.rs) | Não revisado | Sem evidência de revisão | 31 |
| [native/odbc_engine/src/ffi/pool/checkout_checkin.rs](../../native/odbc_engine/src/ffi/pool/checkout_checkin.rs) | Não revisado | Sem evidência de revisão | 367 |
| [native/odbc_engine/src/ffi/pool/metrics.rs](../../native/odbc_engine/src/ffi/pool/metrics.rs) | Não revisado | Sem evidência de revisão | 273 |
| [native/odbc_engine/src/ffi/pool/mod.rs](../../native/odbc_engine/src/ffi/pool/mod.rs) | Não revisado | Sem evidência de revisão | 198 |
| [native/odbc_engine/src/ffi/prelude.rs](../../native/odbc_engine/src/ffi/prelude.rs) | Não revisado | Sem evidência de revisão | 56 |
| [native/odbc_engine/src/ffi/query/async.rs](../../native/odbc_engine/src/ffi/query/async.rs) | Não revisado | Sem evidência de revisão | 331 |
| [native/odbc_engine/src/ffi/query/helpers.rs](../../native/odbc_engine/src/ffi/query/helpers.rs) | Não revisado | Sem evidência de revisão | 69 |
| [native/odbc_engine/src/ffi/query/mod.rs](../../native/odbc_engine/src/ffi/query/mod.rs) | Não revisado | Sem evidência de revisão | 10 |
| [native/odbc_engine/src/ffi/query/sync/exec.rs](../../native/odbc_engine/src/ffi/query/sync/exec.rs) | Não revisado | Sem evidência de revisão | 120 |
| [native/odbc_engine/src/ffi/query/sync/mod.rs](../../native/odbc_engine/src/ffi/query/sync/mod.rs) | Não revisado | Sem evidência de revisão | 9 |
| [native/odbc_engine/src/ffi/query/sync/multi.rs](../../native/odbc_engine/src/ffi/query/sync/multi.rs) | Não revisado | Sem evidência de revisão | 391 |
| [native/odbc_engine/src/ffi/query/sync/params.rs](../../native/odbc_engine/src/ffi/query/sync/params.rs) | Não revisado | Sem evidência de revisão | 397 |
| [native/odbc_engine/src/ffi/release_buffer.rs](../../native/odbc_engine/src/ffi/release_buffer.rs) | Não revisado | Sem evidência de revisão | 37 |
| [native/odbc_engine/src/ffi/runnable.rs](../../native/odbc_engine/src/ffi/runnable.rs) | Não revisado | Sem evidência de revisão | 348 |
| [native/odbc_engine/src/ffi/state/connections.rs](../../native/odbc_engine/src/ffi/state/connections.rs) | Não revisado | Sem evidência de revisão | 99 |
| [native/odbc_engine/src/ffi/state/mod.rs](../../native/odbc_engine/src/ffi/state/mod.rs) | Não revisado | Sem evidência de revisão | 482 |
| [native/odbc_engine/src/ffi/state/pending.rs](../../native/odbc_engine/src/ffi/state/pending.rs) | Não revisado | Sem evidência de revisão | 473 |
| [native/odbc_engine/src/ffi/state/pools.rs](../../native/odbc_engine/src/ffi/state/pools.rs) | Não revisado | Sem evidência de revisão | 310 |
| [native/odbc_engine/src/ffi/state/statements.rs](../../native/odbc_engine/src/ffi/state/statements.rs) | Não revisado | Sem evidência de revisão | 124 |
| [native/odbc_engine/src/ffi/state/streams.rs](../../native/odbc_engine/src/ffi/state/streams.rs) | Não revisado | Sem evidência de revisão | 294 |
| [native/odbc_engine/src/ffi/state/transactions.rs](../../native/odbc_engine/src/ffi/state/transactions.rs) | Não revisado | Sem evidência de revisão | 210 |
| [native/odbc_engine/src/ffi/state/xa.rs](../../native/odbc_engine/src/ffi/state/xa.rs) | Não revisado | Sem evidência de revisão | 119 |
| [native/odbc_engine/src/ffi/statement.rs](../../native/odbc_engine/src/ffi/statement.rs) | Não revisado | Sem evidência de revisão | 387 |
| [native/odbc_engine/src/ffi/stream/adapter.rs](../../native/odbc_engine/src/ffi/stream/adapter.rs) | Não revisado | Sem evidência de revisão | 966 |
| [native/odbc_engine/src/ffi/stream/helpers.rs](../../native/odbc_engine/src/ffi/stream/helpers.rs) | Não revisado | Sem evidência de revisão | 117 |
| [native/odbc_engine/src/ffi/stream/mod.rs](../../native/odbc_engine/src/ffi/stream/mod.rs) | Não revisado | Sem evidência de revisão | 384 |
| [native/odbc_engine/src/ffi/transaction.rs](../../native/odbc_engine/src/ffi/transaction.rs) | Não revisado | Sem evidência de revisão | 452 |
| [native/odbc_engine/src/ffi/xa.rs](../../native/odbc_engine/src/ffi/xa.rs) | Não revisado | Sem evidência de revisão | 733 |
| [native/odbc_engine/src/handles/cached_connection.rs](../../native/odbc_engine/src/handles/cached_connection.rs) | Não revisado | Sem evidência de revisão | 856 |
| [native/odbc_engine/src/handles/mod.rs](../../native/odbc_engine/src/handles/mod.rs) | Não revisado | Sem evidência de revisão | 552 |
| [native/odbc_engine/src/handles/owned_prepared.rs](../../native/odbc_engine/src/handles/owned_prepared.rs) | Não revisado | Sem evidência de revisão | 158 |
| [native/odbc_engine/src/lib.rs](../../native/odbc_engine/src/lib.rs) | Não revisado | Sem evidência de revisão | 151 |
| [native/odbc_engine/src/observability/logging.rs](../../native/odbc_engine/src/observability/logging.rs) | Não revisado | Sem evidência de revisão | 291 |
| [native/odbc_engine/src/observability/metrics.rs](../../native/odbc_engine/src/observability/metrics.rs) | Não revisado | Sem evidência de revisão | 502 |
| [native/odbc_engine/src/observability/mod.rs](../../native/odbc_engine/src/observability/mod.rs) | Não revisado | Sem evidência de revisão | 14 |
| [native/odbc_engine/src/observability/telemetry/console.rs](../../native/odbc_engine/src/observability/telemetry/console.rs) | Não revisado | Sem evidência de revisão | 31 |
| [native/odbc_engine/src/observability/telemetry/exporters.rs](../../native/odbc_engine/src/observability/telemetry/exporters.rs) | Não revisado | Sem evidência de revisão | 298 |
| [native/odbc_engine/src/observability/telemetry/mod.rs](../../native/odbc_engine/src/observability/telemetry/mod.rs) | Não revisado | Sem evidência de revisão | 488 |
| [native/odbc_engine/src/observability/tracing.rs](../../native/odbc_engine/src/observability/tracing.rs) | Não revisado | Sem evidência de revisão | 393 |
| [native/odbc_engine/src/plugins/capabilities/bulk_loader.rs](../../native/odbc_engine/src/plugins/capabilities/bulk_loader.rs) | Não revisado | Sem evidência de revisão | 98 |
| [native/odbc_engine/src/plugins/capabilities/catalog_provider.rs](../../native/odbc_engine/src/plugins/capabilities/catalog_provider.rs) | Não revisado | Sem evidência de revisão | 185 |
| [native/odbc_engine/src/plugins/capabilities/mod.rs](../../native/odbc_engine/src/plugins/capabilities/mod.rs) | Não revisado | Sem evidência de revisão | 96 |
| [native/odbc_engine/src/plugins/capabilities/quoter.rs](../../native/odbc_engine/src/plugins/capabilities/quoter.rs) | Não revisado | Sem evidência de revisão | 58 |
| [native/odbc_engine/src/plugins/capabilities/returning.rs](../../native/odbc_engine/src/plugins/capabilities/returning.rs) | Não revisado | Sem evidência de revisão | 81 |
| [native/odbc_engine/src/plugins/capabilities/session_init.rs](../../native/odbc_engine/src/plugins/capabilities/session_init.rs) | Não revisado | Sem evidência de revisão | 92 |
| [native/odbc_engine/src/plugins/capabilities/type_catalog.rs](../../native/odbc_engine/src/plugins/capabilities/type_catalog.rs) | Não revisado | Sem evidência de revisão | 40 |
| [native/odbc_engine/src/plugins/capabilities/upsert.rs](../../native/odbc_engine/src/plugins/capabilities/upsert.rs) | Não revisado | Sem evidência de revisão | 183 |
| [native/odbc_engine/src/plugins/db2/catalog.rs](../../native/odbc_engine/src/plugins/db2/catalog.rs) | Não revisado | Sem evidência de revisão | 93 |
| [native/odbc_engine/src/plugins/db2/mod.rs](../../native/odbc_engine/src/plugins/db2/mod.rs) | Não revisado | Sem evidência de revisão | 79 |
| [native/odbc_engine/src/plugins/db2/returning.rs](../../native/odbc_engine/src/plugins/db2/returning.rs) | Não revisado | Sem evidência de revisão | 33 |
| [native/odbc_engine/src/plugins/db2/session.rs](../../native/odbc_engine/src/plugins/db2/session.rs) | Não revisado | Sem evidência de revisão | 25 |
| [native/odbc_engine/src/plugins/db2/type_catalog.rs](../../native/odbc_engine/src/plugins/db2/type_catalog.rs) | Não revisado | Sem evidência de revisão | 24 |
| [native/odbc_engine/src/plugins/db2/upsert.rs](../../native/odbc_engine/src/plugins/db2/upsert.rs) | Não revisado | Sem evidência de revisão | 71 |
| [native/odbc_engine/src/plugins/detection.rs](../../native/odbc_engine/src/plugins/detection.rs) | Não revisado | Sem evidência de revisão | 83 |
| [native/odbc_engine/src/plugins/driver_plugin.rs](../../native/odbc_engine/src/plugins/driver_plugin.rs) | Não revisado | Sem evidência de revisão | 170 |
| [native/odbc_engine/src/plugins/mariadb/catalog.rs](../../native/odbc_engine/src/plugins/mariadb/catalog.rs) | Não revisado | Sem evidência de revisão | 41 |
| [native/odbc_engine/src/plugins/mariadb/mod.rs](../../native/odbc_engine/src/plugins/mariadb/mod.rs) | Não revisado | Sem evidência de revisão | 87 |
| [native/odbc_engine/src/plugins/mariadb/returning.rs](../../native/odbc_engine/src/plugins/mariadb/returning.rs) | Não revisado | Sem evidência de revisão | 21 |
| [native/odbc_engine/src/plugins/mariadb/session.rs](../../native/odbc_engine/src/plugins/mariadb/session.rs) | Não revisado | Sem evidência de revisão | 24 |
| [native/odbc_engine/src/plugins/mariadb/type_catalog.rs](../../native/odbc_engine/src/plugins/mariadb/type_catalog.rs) | Não revisado | Sem evidência de revisão | 25 |
| [native/odbc_engine/src/plugins/mariadb/upsert.rs](../../native/odbc_engine/src/plugins/mariadb/upsert.rs) | Não revisado | Sem evidência de revisão | 40 |
| [native/odbc_engine/src/plugins/mod.rs](../../native/odbc_engine/src/plugins/mod.rs) | Não revisado | Sem evidência de revisão | 20 |
| [native/odbc_engine/src/plugins/mysql/bulk_loader.rs](../../native/odbc_engine/src/plugins/mysql/bulk_loader.rs) | Não revisado | Sem evidência de revisão | 31 |
| [native/odbc_engine/src/plugins/mysql/catalog.rs](../../native/odbc_engine/src/plugins/mysql/catalog.rs) | Não revisado | Sem evidência de revisão | 41 |
| [native/odbc_engine/src/plugins/mysql/mod.rs](../../native/odbc_engine/src/plugins/mysql/mod.rs) | Não revisado | Sem evidência de revisão | 88 |
| [native/odbc_engine/src/plugins/mysql/returning.rs](../../native/odbc_engine/src/plugins/mysql/returning.rs) | Não revisado | Sem evidência de revisão | 24 |
| [native/odbc_engine/src/plugins/mysql/session.rs](../../native/odbc_engine/src/plugins/mysql/session.rs) | Não revisado | Sem evidência de revisão | 24 |
| [native/odbc_engine/src/plugins/mysql/type_catalog.rs](../../native/odbc_engine/src/plugins/mysql/type_catalog.rs) | Não revisado | Sem evidência de revisão | 26 |
| [native/odbc_engine/src/plugins/mysql/upsert.rs](../../native/odbc_engine/src/plugins/mysql/upsert.rs) | Não revisado | Sem evidência de revisão | 39 |
| [native/odbc_engine/src/plugins/oracle/bulk_loader.rs](../../native/odbc_engine/src/plugins/oracle/bulk_loader.rs) | Não revisado | Sem evidência de revisão | 37 |
| [native/odbc_engine/src/plugins/oracle/catalog.rs](../../native/odbc_engine/src/plugins/oracle/catalog.rs) | Não revisado | Sem evidência de revisão | 128 |
| [native/odbc_engine/src/plugins/oracle/mod.rs](../../native/odbc_engine/src/plugins/oracle/mod.rs) | Não revisado | Sem evidência de revisão | 89 |
| [native/odbc_engine/src/plugins/oracle/returning.rs](../../native/odbc_engine/src/plugins/oracle/returning.rs) | Não revisado | Sem evidência de revisão | 35 |
| [native/odbc_engine/src/plugins/oracle/session.rs](../../native/odbc_engine/src/plugins/oracle/session.rs) | Não revisado | Sem evidência de revisão | 29 |
| [native/odbc_engine/src/plugins/oracle/type_catalog.rs](../../native/odbc_engine/src/plugins/oracle/type_catalog.rs) | Não revisado | Sem evidência de revisão | 26 |
| [native/odbc_engine/src/plugins/oracle/upsert.rs](../../native/odbc_engine/src/plugins/oracle/upsert.rs) | Não revisado | Sem evidência de revisão | 77 |
| [native/odbc_engine/src/plugins/postgres/bulk_loader.rs](../../native/odbc_engine/src/plugins/postgres/bulk_loader.rs) | Não revisado | Sem evidência de revisão | 34 |
| [native/odbc_engine/src/plugins/postgres/catalog.rs](../../native/odbc_engine/src/plugins/postgres/catalog.rs) | Não revisado | Sem evidência de revisão | 48 |
| [native/odbc_engine/src/plugins/postgres/mod.rs](../../native/odbc_engine/src/plugins/postgres/mod.rs) | Não revisado | Sem evidência de revisão | 88 |
| [native/odbc_engine/src/plugins/postgres/returning.rs](../../native/odbc_engine/src/plugins/postgres/returning.rs) | Não revisado | Sem evidência de revisão | 21 |
| [native/odbc_engine/src/plugins/postgres/session.rs](../../native/odbc_engine/src/plugins/postgres/session.rs) | Não revisado | Sem evidência de revisão | 30 |
| [native/odbc_engine/src/plugins/postgres/type_catalog.rs](../../native/odbc_engine/src/plugins/postgres/type_catalog.rs) | Não revisado | Sem evidência de revisão | 27 |
| [native/odbc_engine/src/plugins/postgres/upsert.rs](../../native/odbc_engine/src/plugins/postgres/upsert.rs) | Não revisado | Sem evidência de revisão | 43 |
| [native/odbc_engine/src/plugins/registry.rs](../../native/odbc_engine/src/plugins/registry.rs) | Não revisado | Sem evidência de revisão | 318 |
| [native/odbc_engine/src/plugins/snowflake/catalog.rs](../../native/odbc_engine/src/plugins/snowflake/catalog.rs) | Não revisado | Sem evidência de revisão | 42 |
| [native/odbc_engine/src/plugins/snowflake/mod.rs](../../native/odbc_engine/src/plugins/snowflake/mod.rs) | Não revisado | Sem evidência de revisão | 78 |
| [native/odbc_engine/src/plugins/snowflake/returning.rs](../../native/odbc_engine/src/plugins/snowflake/returning.rs) | Não revisado | Sem evidência de revisão | 23 |
| [native/odbc_engine/src/plugins/snowflake/session.rs](../../native/odbc_engine/src/plugins/snowflake/session.rs) | Não revisado | Sem evidência de revisão | 31 |
| [native/odbc_engine/src/plugins/snowflake/type_catalog.rs](../../native/odbc_engine/src/plugins/snowflake/type_catalog.rs) | Não revisado | Sem evidência de revisão | 25 |
| [native/odbc_engine/src/plugins/snowflake/upsert.rs](../../native/odbc_engine/src/plugins/snowflake/upsert.rs) | Não revisado | Sem evidência de revisão | 76 |
| [native/odbc_engine/src/plugins/sqlite/catalog.rs](../../native/odbc_engine/src/plugins/sqlite/catalog.rs) | Não revisado | Sem evidência de revisão | 73 |
| [native/odbc_engine/src/plugins/sqlite/mod.rs](../../native/odbc_engine/src/plugins/sqlite/mod.rs) | Não revisado | Sem evidência de revisão | 78 |
| [native/odbc_engine/src/plugins/sqlite/returning.rs](../../native/odbc_engine/src/plugins/sqlite/returning.rs) | Não revisado | Sem evidência de revisão | 21 |
| [native/odbc_engine/src/plugins/sqlite/session.rs](../../native/odbc_engine/src/plugins/sqlite/session.rs) | Não revisado | Sem evidência de revisão | 17 |
| [native/odbc_engine/src/plugins/sqlite/type_catalog.rs](../../native/odbc_engine/src/plugins/sqlite/type_catalog.rs) | Não revisado | Sem evidência de revisão | 33 |
| [native/odbc_engine/src/plugins/sqlite/upsert.rs](../../native/odbc_engine/src/plugins/sqlite/upsert.rs) | Não revisado | Sem evidência de revisão | 41 |
| [native/odbc_engine/src/plugins/sqlserver/catalog.rs](../../native/odbc_engine/src/plugins/sqlserver/catalog.rs) | Não revisado | Sem evidência de revisão | 61 |
| [native/odbc_engine/src/plugins/sqlserver/mod.rs](../../native/odbc_engine/src/plugins/sqlserver/mod.rs) | Não revisado | Sem evidência de revisão | 86 |
| [native/odbc_engine/src/plugins/sqlserver/quoting.rs](../../native/odbc_engine/src/plugins/sqlserver/quoting.rs) | Não revisado | Sem evidência de revisão | 22 |
| [native/odbc_engine/src/plugins/sqlserver/returning.rs](../../native/odbc_engine/src/plugins/sqlserver/returning.rs) | Não revisado | Sem evidência de revisão | 67 |
| [native/odbc_engine/src/plugins/sqlserver/session.rs](../../native/odbc_engine/src/plugins/sqlserver/session.rs) | Não revisado | Sem evidência de revisão | 33 |
| [native/odbc_engine/src/plugins/sqlserver/type_catalog.rs](../../native/odbc_engine/src/plugins/sqlserver/type_catalog.rs) | Não revisado | Sem evidência de revisão | 28 |
| [native/odbc_engine/src/plugins/sqlserver/upsert.rs](../../native/odbc_engine/src/plugins/sqlserver/upsert.rs) | Não revisado | Sem evidência de revisão | 82 |
| [native/odbc_engine/src/plugins/sybase/catalog.rs](../../native/odbc_engine/src/plugins/sybase/catalog.rs) | Não revisado | Sem evidência de revisão | 78 |
| [native/odbc_engine/src/plugins/sybase/mod.rs](../../native/odbc_engine/src/plugins/sybase/mod.rs) | Não revisado | Sem evidência de revisão | 79 |
| [native/odbc_engine/src/plugins/sybase/returning.rs](../../native/odbc_engine/src/plugins/sybase/returning.rs) | Não revisado | Sem evidência de revisão | 22 |
| [native/odbc_engine/src/plugins/sybase/session.rs](../../native/odbc_engine/src/plugins/sybase/session.rs) | Não revisado | Sem evidência de revisão | 16 |
| [native/odbc_engine/src/plugins/sybase/type_catalog.rs](../../native/odbc_engine/src/plugins/sybase/type_catalog.rs) | Não revisado | Sem evidência de revisão | 25 |
| [native/odbc_engine/src/plugins/sybase/upsert.rs](../../native/odbc_engine/src/plugins/sybase/upsert.rs) | Não revisado | Sem evidência de revisão | 24 |
| [native/odbc_engine/src/pool/mod.rs](../../native/odbc_engine/src/pool/mod.rs) | Não revisado | Sem evidência de revisão | 371 |
| [native/odbc_engine/src/pool/pool_config.rs](../../native/odbc_engine/src/pool/pool_config.rs) | Não revisado | Sem evidência de revisão | 387 |
| [native/odbc_engine/src/pool/pool_health.rs](../../native/odbc_engine/src/pool/pool_health.rs) | Não revisado | Sem evidência de revisão | 122 |
| [native/odbc_engine/src/protocol/bound_param.rs](../../native/odbc_engine/src/protocol/bound_param.rs) | Parcial | Triagem preliminar | 320 |
| [native/odbc_engine/src/protocol/bulk_insert/common.rs](../../native/odbc_engine/src/protocol/bulk_insert/common.rs) | Não revisado | Sem evidência de revisão | 366 |
| [native/odbc_engine/src/protocol/bulk_insert/legacy.rs](../../native/odbc_engine/src/protocol/bulk_insert/legacy.rs) | Não revisado | Sem evidência de revisão | 266 |
| [native/odbc_engine/src/protocol/bulk_insert/mod.rs](../../native/odbc_engine/src/protocol/bulk_insert/mod.rs) | Não revisado | Sem evidência de revisão | 253 |
| [native/odbc_engine/src/protocol/bulk_insert/v2.rs](../../native/odbc_engine/src/protocol/bulk_insert/v2.rs) | Não revisado | Sem evidência de revisão | 143 |
| [native/odbc_engine/src/protocol/columnar.rs](../../native/odbc_engine/src/protocol/columnar.rs) | Não revisado | Sem evidência de revisão | 222 |
| [native/odbc_engine/src/protocol/columnar_encoder.rs](../../native/odbc_engine/src/protocol/columnar_encoder.rs) | Parcial | Revisão focal com testes/benchmarks | 1165 |
| [native/odbc_engine/src/protocol/columnar_v2.rs](../../native/odbc_engine/src/protocol/columnar_v2.rs) | Não revisado | Sem evidência de revisão | 42 |
| [native/odbc_engine/src/protocol/compression.rs](../../native/odbc_engine/src/protocol/compression.rs) | Não revisado | Sem evidência de revisão | 356 |
| [native/odbc_engine/src/protocol/converter.rs](../../native/odbc_engine/src/protocol/converter.rs) | Parcial | Revisão focal com testes/benchmarks | 413 |
| [native/odbc_engine/src/protocol/decoder/mod.rs](../../native/odbc_engine/src/protocol/decoder/mod.rs) | Parcial | Revisão focal com testes/benchmarks | 237 |
| [native/odbc_engine/src/protocol/encoder/mod.rs](../../native/odbc_engine/src/protocol/encoder/mod.rs) | Parcial | Triagem preliminar | 330 |
| [native/odbc_engine/src/protocol/mod.rs](../../native/odbc_engine/src/protocol/mod.rs) | Não revisado | Sem evidência de revisão | 46 |
| [native/odbc_engine/src/protocol/multi_result.rs](../../native/odbc_engine/src/protocol/multi_result.rs) | Não revisado | Sem evidência de revisão | 687 |
| [native/odbc_engine/src/protocol/param_value/mod.rs](../../native/odbc_engine/src/protocol/param_value/mod.rs) | Parcial | Triagem preliminar | 522 |
| [native/odbc_engine/src/protocol/row_buffer.rs](../../native/odbc_engine/src/protocol/row_buffer.rs) | Não revisado | Sem evidência de revisão | 95 |
| [native/odbc_engine/src/protocol/types.rs](../../native/odbc_engine/src/protocol/types.rs) | Não revisado | Sem evidência de revisão | 372 |
| [native/odbc_engine/src/security/audit.rs](../../native/odbc_engine/src/security/audit.rs) | Não revisado | Sem evidência de revisão | 280 |
| [native/odbc_engine/src/security/connection_string.rs](../../native/odbc_engine/src/security/connection_string.rs) | Não revisado | Sem evidência de revisão | 191 |
| [native/odbc_engine/src/security/mod.rs](../../native/odbc_engine/src/security/mod.rs) | Não revisado | Sem evidência de revisão | 12 |
| [native/odbc_engine/src/security/sanitize.rs](../../native/odbc_engine/src/security/sanitize.rs) | Não revisado | Sem evidência de revisão | 183 |
| [native/odbc_engine/src/security/secret_manager.rs](../../native/odbc_engine/src/security/secret_manager.rs) | Não revisado | Sem evidência de revisão | 189 |
| [native/odbc_engine/src/security/secure_buffer.rs](../../native/odbc_engine/src/security/secure_buffer.rs) | Não revisado | Sem evidência de revisão | 152 |
| [native/odbc_engine/src/versioning/abi_version.rs](../../native/odbc_engine/src/versioning/abi_version.rs) | Não revisado | Sem evidência de revisão | 117 |
| [native/odbc_engine/src/versioning/api_version.rs](../../native/odbc_engine/src/versioning/api_version.rs) | Não revisado | Sem evidência de revisão | 141 |
| [native/odbc_engine/src/versioning/mod.rs](../../native/odbc_engine/src/versioning/mod.rs) | Não revisado | Sem evidência de revisão | 3 |
| [native/odbc_engine/src/versioning/protocol_version.rs](../../native/odbc_engine/src/versioning/protocol_version.rs) | Não revisado | Sem evidência de revisão | 169 |

## Inventário de apoio — fora do denominador do motor

| Arquivo | Categoria | Estado | Linhas físicas |
| --- | --- | --- | ---: |
| [native/loom_models/src/lib.rs](../../native/loom_models/src/lib.rs) | apoio | Não revisado | 3 |
| [native/loom_models/tests/loom_state_test.rs](../../native/loom_models/tests/loom_state_test.rs) | testes | Não revisado | 148 |
| [native/odbc_engine/benches/buffer_recycle_bench.rs](../../native/odbc_engine/benches/buffer_recycle_bench.rs) | benchmarks | Não revisado | 78 |
| [native/odbc_engine/benches/bulk_operations_bench.rs](../../native/odbc_engine/benches/bulk_operations_bench.rs) | benchmarks | Não revisado | 234 |
| [native/odbc_engine/benches/cell_reader_bench.rs](../../native/odbc_engine/benches/cell_reader_bench.rs) | benchmarks | Não revisado | 361 |
| [native/odbc_engine/benches/columnar_v1_v2_encode.rs](../../native/odbc_engine/benches/columnar_v1_v2_encode.rs) | benchmarks | Não revisado | 107 |
| [native/odbc_engine/benches/columnar_v2_placeholder.rs](../../native/odbc_engine/benches/columnar_v2_placeholder.rs) | benchmarks | Não revisado | 19 |
| [native/odbc_engine/benches/comparative_bench.rs](../../native/odbc_engine/benches/comparative_bench.rs) | benchmarks | Não revisado | 311 |
| [native/odbc_engine/benches/decoder_validation_bench.rs](../../native/odbc_engine/benches/decoder_validation_bench.rs) | benchmarks | Parcial | 36 |
| [native/odbc_engine/benches/encoder_bench.rs](../../native/odbc_engine/benches/encoder_bench.rs) | benchmarks | Parcial | 321 |
| [native/odbc_engine/benches/fallback_transpose_bench.rs](../../native/odbc_engine/benches/fallback_transpose_bench.rs) | benchmarks | Parcial | 95 |
| [native/odbc_engine/benches/ffi_contention_bench.rs](../../native/odbc_engine/benches/ffi_contention_bench.rs) | benchmarks | Não revisado | 193 |
| [native/odbc_engine/benches/live_hotpaths_bench.rs](../../native/odbc_engine/benches/live_hotpaths_bench.rs) | benchmarks | Não revisado | 389 |
| [native/odbc_engine/benches/metadata_cache_bench.rs](../../native/odbc_engine/benches/metadata_cache_bench.rs) | benchmarks | Não revisado | 256 |
| [native/odbc_engine/benches/prepared_cache_bench.rs](../../native/odbc_engine/benches/prepared_cache_bench.rs) | benchmarks | Não revisado | 222 |
| [native/odbc_engine/benches/stream_param_decode_bench.rs](../../native/odbc_engine/benches/stream_param_decode_bench.rs) | benchmarks | Não revisado | 53 |
| [native/odbc_engine/build.rs](../../native/odbc_engine/build.rs) | build | Não revisado | 34 |
| [native/odbc_engine/examples/compression_paired_bench.rs](../../native/odbc_engine/examples/compression_paired_bench.rs) | benchmarks | Parcial | 181 |
| [native/odbc_engine/src/engine/core/execution/tests.rs](../../native/odbc_engine/src/engine/core/execution/tests.rs) | testes | Não revisado | 817 |
| [native/odbc_engine/src/engine/core/sqlserver_bcp/tests.rs](../../native/odbc_engine/src/engine/core/sqlserver_bcp/tests.rs) | testes | Não revisado | 267 |
| [native/odbc_engine/src/engine/streaming/tests/async_state.rs](../../native/odbc_engine/src/engine/streaming/tests/async_state.rs) | testes | Não revisado | 297 |
| [native/odbc_engine/src/engine/streaming/tests/batched.rs](../../native/odbc_engine/src/engine/streaming/tests/batched.rs) | testes | Não revisado | 287 |
| [native/odbc_engine/src/engine/streaming/tests/encode.rs](../../native/odbc_engine/src/engine/streaming/tests/encode.rs) | testes | Não revisado | 52 |
| [native/odbc_engine/src/engine/streaming/tests/executor.rs](../../native/odbc_engine/src/engine/streaming/tests/executor.rs) | testes | Não revisado | 26 |
| [native/odbc_engine/src/engine/streaming/tests/file_backed.rs](../../native/odbc_engine/src/engine/streaming/tests/file_backed.rs) | testes | Não revisado | 198 |
| [native/odbc_engine/src/engine/streaming/tests/in_memory.rs](../../native/odbc_engine/src/engine/streaming/tests/in_memory.rs) | testes | Não revisado | 221 |
| [native/odbc_engine/src/engine/streaming/tests/mod.rs](../../native/odbc_engine/src/engine/streaming/tests/mod.rs) | testes | Não revisado | 18 |
| [native/odbc_engine/src/engine/streaming/tests/multi_frame.rs](../../native/odbc_engine/src/engine/streaming/tests/multi_frame.rs) | testes | Não revisado | 139 |
| [native/odbc_engine/src/engine/streaming/tests/spill.rs](../../native/odbc_engine/src/engine/streaming/tests/spill.rs) | testes | Não revisado | 100 |
| [native/odbc_engine/src/engine/streaming/tests/support.rs](../../native/odbc_engine/src/engine/streaming/tests/support.rs) | testes | Não revisado | 7 |
| [native/odbc_engine/src/engine/transaction/tests/access_mode.rs](../../native/odbc_engine/src/engine/transaction/tests/access_mode.rs) | testes | Não revisado | 78 |
| [native/odbc_engine/src/engine/transaction/tests/engine_resolve.rs](../../native/odbc_engine/src/engine/transaction/tests/engine_resolve.rs) | testes | Não revisado | 117 |
| [native/odbc_engine/src/engine/transaction/tests/isolation.rs](../../native/odbc_engine/src/engine/transaction/tests/isolation.rs) | testes | Não revisado | 110 |
| [native/odbc_engine/src/engine/transaction/tests/lock_timeout.rs](../../native/odbc_engine/src/engine/transaction/tests/lock_timeout.rs) | testes | Não revisado | 163 |
| [native/odbc_engine/src/engine/transaction/tests/mod.rs](../../native/odbc_engine/src/engine/transaction/tests/mod.rs) | testes | Não revisado | 16 |
| [native/odbc_engine/src/engine/transaction/tests/savepoint.rs](../../native/odbc_engine/src/engine/transaction/tests/savepoint.rs) | testes | Não revisado | 265 |
| [native/odbc_engine/src/engine/transaction/tests/state.rs](../../native/odbc_engine/src/engine/transaction/tests/state.rs) | testes | Não revisado | 171 |
| [native/odbc_engine/src/engine/xa/tests.rs](../../native/odbc_engine/src/engine/xa/tests.rs) | testes | Não revisado | 876 |
| [native/odbc_engine/src/ffi/tests/bulk.rs](../../native/odbc_engine/src/ffi/tests/bulk.rs) | testes | Não revisado | 380 |
| [native/odbc_engine/src/ffi/tests/catalog.rs](../../native/odbc_engine/src/ffi/tests/catalog.rs) | testes | Não revisado | 186 |
| [native/odbc_engine/src/ffi/tests/connection.rs](../../native/odbc_engine/src/ffi/tests/connection.rs) | testes | Não revisado | 379 |
| [native/odbc_engine/src/ffi/tests/diagnostics.rs](../../native/odbc_engine/src/ffi/tests/diagnostics.rs) | testes | Não revisado | 117 |
| [native/odbc_engine/src/ffi/tests/errors.rs](../../native/odbc_engine/src/ffi/tests/errors.rs) | testes | Não revisado | 395 |
| [native/odbc_engine/src/ffi/tests/init.rs](../../native/odbc_engine/src/ffi/tests/init.rs) | testes | Não revisado | 282 |
| [native/odbc_engine/src/ffi/tests/mod.rs](../../native/odbc_engine/src/ffi/tests/mod.rs) | testes | Não revisado | 15 |
| [native/odbc_engine/src/ffi/tests/pool.rs](../../native/odbc_engine/src/ffi/tests/pool.rs) | testes | Não revisado | 580 |
| [native/odbc_engine/src/ffi/tests/query/async.rs](../../native/odbc_engine/src/ffi/tests/query/async.rs) | testes | Não revisado | 286 |
| [native/odbc_engine/src/ffi/tests/query/mod.rs](../../native/odbc_engine/src/ffi/tests/query/mod.rs) | testes | Não revisado | 9 |
| [native/odbc_engine/src/ffi/tests/query/params.rs](../../native/odbc_engine/src/ffi/tests/query/params.rs) | testes | Não revisado | 164 |
| [native/odbc_engine/src/ffi/tests/query/prepare.rs](../../native/odbc_engine/src/ffi/tests/query/prepare.rs) | testes | Não revisado | 295 |
| [native/odbc_engine/src/ffi/tests/query/sync.rs](../../native/odbc_engine/src/ffi/tests/query/sync.rs) | testes | Não revisado | 198 |
| [native/odbc_engine/src/ffi/tests/query/timeout.rs](../../native/odbc_engine/src/ffi/tests/query/timeout.rs) | testes | Não revisado | 95 |
| [native/odbc_engine/src/ffi/tests/stream.rs](../../native/odbc_engine/src/ffi/tests/stream.rs) | testes | Não revisado | 415 |
| [native/odbc_engine/src/ffi/tests/support.rs](../../native/odbc_engine/src/ffi/tests/support.rs) | testes | Não revisado | 177 |
| [native/odbc_engine/src/ffi/tests/transaction.rs](../../native/odbc_engine/src/ffi/tests/transaction.rs) | testes | Não revisado | 413 |
| [native/odbc_engine/src/ffi/tests/xa.rs](../../native/odbc_engine/src/ffi/tests/xa.rs) | testes | Não revisado | 58 |
| [native/odbc_engine/src/plugins/db2/tests.rs](../../native/odbc_engine/src/plugins/db2/tests.rs) | testes | Não revisado | 274 |
| [native/odbc_engine/src/plugins/mariadb/tests.rs](../../native/odbc_engine/src/plugins/mariadb/tests.rs) | testes | Não revisado | 234 |
| [native/odbc_engine/src/plugins/mysql/tests.rs](../../native/odbc_engine/src/plugins/mysql/tests.rs) | testes | Não revisado | 363 |
| [native/odbc_engine/src/plugins/oracle/tests.rs](../../native/odbc_engine/src/plugins/oracle/tests.rs) | testes | Não revisado | 401 |
| [native/odbc_engine/src/plugins/postgres/tests.rs](../../native/odbc_engine/src/plugins/postgres/tests.rs) | testes | Não revisado | 316 |
| [native/odbc_engine/src/plugins/registry/tests.rs](../../native/odbc_engine/src/plugins/registry/tests.rs) | testes | Não revisado | 538 |
| [native/odbc_engine/src/plugins/snowflake/tests.rs](../../native/odbc_engine/src/plugins/snowflake/tests.rs) | testes | Não revisado | 260 |
| [native/odbc_engine/src/plugins/sqlite/tests.rs](../../native/odbc_engine/src/plugins/sqlite/tests.rs) | testes | Não revisado | 87 |
| [native/odbc_engine/src/plugins/sqlserver/tests.rs](../../native/odbc_engine/src/plugins/sqlserver/tests.rs) | testes | Não revisado | 341 |
| [native/odbc_engine/src/plugins/sybase/tests.rs](../../native/odbc_engine/src/plugins/sybase/tests.rs) | testes | Não revisado | 161 |
| [native/odbc_engine/src/protocol/bulk_insert/tests/column_types.rs](../../native/odbc_engine/src/protocol/bulk_insert/tests/column_types.rs) | testes | Não revisado | 16 |
| [native/odbc_engine/src/protocol/bulk_insert/tests/estimate.rs](../../native/odbc_engine/src/protocol/bulk_insert/tests/estimate.rs) | testes | Não revisado | 52 |
| [native/odbc_engine/src/protocol/bulk_insert/tests/legacy_wire.rs](../../native/odbc_engine/src/protocol/bulk_insert/tests/legacy_wire.rs) | testes | Não revisado | 201 |
| [native/odbc_engine/src/protocol/bulk_insert/tests/mod.rs](../../native/odbc_engine/src/protocol/bulk_insert/tests/mod.rs) | testes | Não revisado | 21 |
| [native/odbc_engine/src/protocol/bulk_insert/tests/null_bitmap.rs](../../native/odbc_engine/src/protocol/bulk_insert/tests/null_bitmap.rs) | testes | Não revisado | 58 |
| [native/odbc_engine/src/protocol/bulk_insert/tests/roundtrip.rs](../../native/odbc_engine/src/protocol/bulk_insert/tests/roundtrip.rs) | testes | Não revisado | 98 |
| [native/odbc_engine/src/protocol/bulk_insert/tests/v2.rs](../../native/odbc_engine/src/protocol/bulk_insert/tests/v2.rs) | testes | Não revisado | 234 |
| [native/odbc_engine/src/protocol/bulk_insert/tests/validation.rs](../../native/odbc_engine/src/protocol/bulk_insert/tests/validation.rs) | testes | Não revisado | 184 |
| [native/odbc_engine/src/protocol/decoder/tests.rs](../../native/odbc_engine/src/protocol/decoder/tests.rs) | testes | Parcial | 374 |
| [native/odbc_engine/src/protocol/encoder/tests.rs](../../native/odbc_engine/src/protocol/encoder/tests.rs) | testes | Não revisado | 497 |
| [native/odbc_engine/src/protocol/param_value/tests.rs](../../native/odbc_engine/src/protocol/param_value/tests.rs) | testes | Não revisado | 794 |
| [native/odbc_engine/tests/abi_test.rs](../../native/odbc_engine/tests/abi_test.rs) | testes | Não revisado | 61 |
| [native/odbc_engine/tests/block_fetch_parity_test.rs](../../native/odbc_engine/tests/block_fetch_parity_test.rs) | testes | Não revisado | 197 |
| [native/odbc_engine/tests/cached_connection_params_test.rs](../../native/odbc_engine/tests/cached_connection_params_test.rs) | testes | Não revisado | 48 |
| [native/odbc_engine/tests/catalog_validation_test.rs](../../native/odbc_engine/tests/catalog_validation_test.rs) | testes | Não revisado | 96 |
| [native/odbc_engine/tests/cell_reader_test.rs](../../native/odbc_engine/tests/cell_reader_test.rs) | testes | Não revisado | 480 |
| [native/odbc_engine/tests/columnar_compression_allocation_test.rs](../../native/odbc_engine/tests/columnar_compression_allocation_test.rs) | testes | Parcial | 79 |
| [native/odbc_engine/tests/columnar_v2_zstd_golden_file.rs](../../native/odbc_engine/tests/columnar_v2_zstd_golden_file.rs) | testes | Não revisado | 87 |
| [native/odbc_engine/tests/concurrent_access_test.rs](../../native/odbc_engine/tests/concurrent_access_test.rs) | testes | Não revisado | 71 |
| [native/odbc_engine/tests/concurrent_error_test.rs](../../native/odbc_engine/tests/concurrent_error_test.rs) | testes | Não revisado | 190 |
| [native/odbc_engine/tests/decoder_allocation_test.rs](../../native/odbc_engine/tests/decoder_allocation_test.rs) | testes | Parcial | 55 |
| [native/odbc_engine/tests/e2e_async_api_test.rs](../../native/odbc_engine/tests/e2e_async_api_test.rs) | testes | Não revisado | 692 |
| [native/odbc_engine/tests/e2e_basic_connection_test.rs](../../native/odbc_engine/tests/e2e_basic_connection_test.rs) | testes | Não revisado | 311 |
| [native/odbc_engine/tests/e2e_batch_executor_test.rs](../../native/odbc_engine/tests/e2e_batch_executor_test.rs) | testes | Não revisado | 644 |
| [native/odbc_engine/tests/e2e_bcp_fallback_test.rs](../../native/odbc_engine/tests/e2e_bcp_fallback_test.rs) | testes | Não revisado | 191 |
| [native/odbc_engine/tests/e2e_bcp_native_numeric_test.rs](../../native/odbc_engine/tests/e2e_bcp_native_numeric_test.rs) | testes | Não revisado | 767 |
| [native/odbc_engine/tests/e2e_bulk_compare_benchmark_test.rs](../../native/odbc_engine/tests/e2e_bulk_compare_benchmark_test.rs) | testes | Não revisado | 187 |
| [native/odbc_engine/tests/e2e_bulk_operations_test.rs](../../native/odbc_engine/tests/e2e_bulk_operations_test.rs) | testes | Não revisado | 917 |
| [native/odbc_engine/tests/e2e_bulk_transaction_stress_test.rs](../../native/odbc_engine/tests/e2e_bulk_transaction_stress_test.rs) | testes | Não revisado | 322 |
| [native/odbc_engine/tests/e2e_catalog_test.rs](../../native/odbc_engine/tests/e2e_catalog_test.rs) | testes | Não revisado | 179 |
| [native/odbc_engine/tests/e2e_driver_capabilities_test.rs](../../native/odbc_engine/tests/e2e_driver_capabilities_test.rs) | testes | Não revisado | 348 |
| [native/odbc_engine/tests/e2e_execution_engine_test.rs](../../native/odbc_engine/tests/e2e_execution_engine_test.rs) | testes | Não revisado | 1285 |
| [native/odbc_engine/tests/e2e_ffi_refactor_regression_test.rs](../../native/odbc_engine/tests/e2e_ffi_refactor_regression_test.rs) | testes | Não revisado | 327 |
| [native/odbc_engine/tests/e2e_multi_db_basic_test.rs](../../native/odbc_engine/tests/e2e_multi_db_basic_test.rs) | testes | Não revisado | 136 |
| [native/odbc_engine/tests/e2e_oracle_ref_cursor_test.rs](../../native/odbc_engine/tests/e2e_oracle_ref_cursor_test.rs) | testes | Não revisado | 131 |
| [native/odbc_engine/tests/e2e_pool_test.rs](../../native/odbc_engine/tests/e2e_pool_test.rs) | testes | Não revisado | 806 |
| [native/odbc_engine/tests/e2e_savepoint_test.rs](../../native/odbc_engine/tests/e2e_savepoint_test.rs) | testes | Não revisado | 181 |
| [native/odbc_engine/tests/e2e_sqlserver_test.rs](../../native/odbc_engine/tests/e2e_sqlserver_test.rs) | testes | Não revisado | 1237 |
| [native/odbc_engine/tests/e2e_statement_reuse_test.rs](../../native/odbc_engine/tests/e2e_statement_reuse_test.rs) | testes | Não revisado | 178 |
| [native/odbc_engine/tests/e2e_streaming_test.rs](../../native/odbc_engine/tests/e2e_streaming_test.rs) | testes | Não revisado | 1103 |
| [native/odbc_engine/tests/e2e_structured_error_test.rs](../../native/odbc_engine/tests/e2e_structured_error_test.rs) | testes | Não revisado | 346 |
| [native/odbc_engine/tests/e2e_test.rs](../../native/odbc_engine/tests/e2e_test.rs) | testes | Não revisado | 206 |
| [native/odbc_engine/tests/e2e_timeout_test.rs](../../native/odbc_engine/tests/e2e_timeout_test.rs) | testes | Não revisado | 97 |
| [native/odbc_engine/tests/e2e_transaction_access_mode_test.rs](../../native/odbc_engine/tests/e2e_transaction_access_mode_test.rs) | testes | Não revisado | 234 |
| [native/odbc_engine/tests/e2e_transaction_lock_timeout_test.rs](../../native/odbc_engine/tests/e2e_transaction_lock_timeout_test.rs) | testes | Não revisado | 193 |
| [native/odbc_engine/tests/e2e_xa_transaction_test.rs](../../native/odbc_engine/tests/e2e_xa_transaction_test.rs) | testes | Não revisado | 650 |
| [native/odbc_engine/tests/ffi_compatibility_test.rs](../../native/odbc_engine/tests/ffi_compatibility_test.rs) | testes | Não revisado | 155 |
| [native/odbc_engine/tests/helpers/e2e.rs](../../native/odbc_engine/tests/helpers/e2e.rs) | testes | Não revisado | 282 |
| [native/odbc_engine/tests/helpers/env.rs](../../native/odbc_engine/tests/helpers/env.rs) | testes | Não revisado | 362 |
| [native/odbc_engine/tests/helpers/mod.rs](../../native/odbc_engine/tests/helpers/mod.rs) | testes | Não revisado | 15 |
| [native/odbc_engine/tests/integration_test.rs](../../native/odbc_engine/tests/integration_test.rs) | testes | Não revisado | 17 |
| [native/odbc_engine/tests/phase11_test.rs](../../native/odbc_engine/tests/phase11_test.rs) | testes | Não revisado | 78 |
| [native/odbc_engine/tests/phase12_test.rs](../../native/odbc_engine/tests/phase12_test.rs) | testes | Não revisado | 35 |
| [native/odbc_engine/tests/phase13_test.rs](../../native/odbc_engine/tests/phase13_test.rs) | testes | Não revisado | 78 |
| [native/odbc_engine/tests/phase14_test.rs](../../native/odbc_engine/tests/phase14_test.rs) | testes | Não revisado | 64 |
| [native/odbc_engine/tests/prepared_cache_invalidation_test.rs](../../native/odbc_engine/tests/prepared_cache_invalidation_test.rs) | testes | Não revisado | 102 |
| [native/odbc_engine/tests/regression/a1_ffi_savepoint_injection.rs](../../native/odbc_engine/tests/regression/a1_ffi_savepoint_injection.rs) | testes | Não revisado | 124 |
| [native/odbc_engine/tests/regression/a1_savepoint_injection.rs](../../native/odbc_engine/tests/regression/a1_savepoint_injection.rs) | testes | Não revisado | 28 |
| [native/odbc_engine/tests/regression/a2_array_binding_injection.rs](../../native/odbc_engine/tests/regression/a2_array_binding_injection.rs) | testes | Não revisado | 32 |
| [native/odbc_engine/tests/regression/a3_span_lifecycle.rs](../../native/odbc_engine/tests/regression/a3_span_lifecycle.rs) | testes | Não revisado | 46 |
| [native/odbc_engine/tests/regression/c10_integer_binary_decode.rs](../../native/odbc_engine/tests/regression/c10_integer_binary_decode.rs) | testes | Não revisado | 54 |
| [native/odbc_engine/tests/regression/c1_ffi_panic_safety.rs](../../native/odbc_engine/tests/regression/c1_ffi_panic_safety.rs) | testes | Não revisado | 51 |
| [native/odbc_engine/tests/regression/c2_telemetry_ffi_safety.rs](../../native/odbc_engine/tests/regression/c2_telemetry_ffi_safety.rs) | testes | Não revisado | 49 |
| [native/odbc_engine/tests/regression/c6_multi_result_loop.rs](../../native/odbc_engine/tests/regression/c6_multi_result_loop.rs) | testes | Não revisado | 24 |
| [native/odbc_engine/tests/regression/c9_bitmap_truncation.rs](../../native/odbc_engine/tests/regression/c9_bitmap_truncation.rs) | testes | Não revisado | 37 |
| [native/odbc_engine/tests/regression/d1_drt1_multi_result_wire.rs](../../native/odbc_engine/tests/regression/d1_drt1_multi_result_wire.rs) | testes | Não revisado | 262 |
| [native/odbc_engine/tests/regression/m1_multi_result_batch_shapes.rs](../../native/odbc_engine/tests/regression/m1_multi_result_batch_shapes.rs) | testes | Não revisado | 195 |
| [native/odbc_engine/tests/regression/m8_streaming_multi_result.rs](../../native/odbc_engine/tests/regression/m8_streaming_multi_result.rs) | testes | Não revisado | 295 |
| [native/odbc_engine/tests/regression/mod.rs](../../native/odbc_engine/tests/regression/mod.rs) | testes | Não revisado | 34 |
| [native/odbc_engine/tests/regression/v21_dbms_detection.rs](../../native/odbc_engine/tests/regression/v21_dbms_detection.rs) | testes | Não revisado | 158 |
| [native/odbc_engine/tests/regression/v30_capabilities.rs](../../native/odbc_engine/tests/regression/v30_capabilities.rs) | testes | Não revisado | 155 |
| [native/odbc_engine/tests/regression/v30_returning_dialects.rs](../../native/odbc_engine/tests/regression/v30_returning_dialects.rs) | testes | Não revisado | 113 |
| [native/odbc_engine/tests/regression/v30_session_init.rs](../../native/odbc_engine/tests/regression/v30_session_init.rs) | testes | Não revisado | 111 |
| [native/odbc_engine/tests/regression/v30_upsert_dialects.rs](../../native/odbc_engine/tests/regression/v30_upsert_dialects.rs) | testes | Não revisado | 112 |
| [native/odbc_engine/tests/regression/xa_dtc_test.rs](../../native/odbc_engine/tests/regression/xa_dtc_test.rs) | testes | Não revisado | 97 |
| [native/odbc_engine/tests/regression_test.rs](../../native/odbc_engine/tests/regression_test.rs) | testes | Não revisado | 4 |
| [native/odbc_engine/tests/state_locking_order_test.rs](../../native/odbc_engine/tests/state_locking_order_test.rs) | testes | Não revisado | 239 |
| [native/odbc_engine/tests/structured_error_regression_test.rs](../../native/odbc_engine/tests/structured_error_regression_test.rs) | testes | Não revisado | 161 |
| [native/odbc_engine/tests/transaction_test.rs](../../native/odbc_engine/tests/transaction_test.rs) | testes | Não revisado | 480 |
