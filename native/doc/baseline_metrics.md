# Baseline de Metricas (Fase 0)

Documento para registrar baseline de throughput, latencia e memoria conforme
plano de implementacao. Atualizar apos execucao de benchmarks com DSN real.

## Benchmarks existentes

`cargo bench -p odbc_engine` executa benchmarks de protocolo (sem DSN):

| Benchmark | Tempo médio | Descrição |
|-----------|-------------|-----------|
| `array_binding_new_1000` | ~560 ps | Criação de array binding para 1000 linhas |
| `encode_empty_buffer` | ~88 ns | Codificação de buffer vazio |
| `encode_small_buffer_100_rows` | ~1.38 µs | Codificação de 100 linhas |
| `encode_with_compression_1000_rows` | ~11.05 µs | Codificação com compressão de 1000 linhas |

## Metricas a publicar (requer DSN)

| Metrica | Cenario | Unidade | Baseline |
|---------|--------|---------|----------|
| Throughput | Array binding (5k rows) | rows/s | ~11,134 |
| Throughput | Parallel insert (5k rows) | rows/s | ~34,541 (3.10x speedup) |
| Throughput | Array binding (20k rows) | rows/s | ~9,649 |
| Throughput | Parallel insert (20k rows) | rows/s | ~36,965 (3.83x speedup) |
| Latencia | SELECT simples (cold) | ms | ~50 |
| Latencia | Stream 50k linhas (buffer mode) | ms | ~219 |
| Latencia | Stream 50k linhas (batched mode, 1000 rows/batch) | ms | ~207 |
| Memoria pico | Stream 50k linhas (buffer mode) | MB | ~0.43 (450,021 bytes) |
| Memoria pico | Stream 50k linhas (batched mode) | MB | <0.1 (incremental) |
| Memoria pico | Stream 50k linhas (spill mode) | MB | N/A (não testado) |

## Como executar

```bash
# Benchmarks de protocolo (sem DSN)
cargo bench -p odbc_engine

# E2E benchmark com DSN (quando disponivel)
cargo test -p odbc_engine --features ffi-tests e2e_bulk_compare_benchmark -- --ignored

# Validacao de memoria com 50k linhas (buffer + batched mode)
# Requer: ENABLE_E2E_TESTS=1 e DSN configurado
cargo test --test e2e_streaming_test test_streaming_50k_rows_memory_validation -- --ignored --nocapture
```

## Criterios de aceite Fase 0

- [x] Matriz de testes criada (`test_matrix.md`)
- [x] Testes de compatibilidade FFI (`ffi_compatibility_test`)
- [x] Baseline de throughput/latencia preenchido (SQL Server local)
- [x] Baseline de memoria preenchido (SQL Server local)

## Notas

- **Ambiente de teste**: SQL Server Native Client 11.0, localhost, database Estacao
- **Hardware**: Valores obtidos em ambiente de desenvolvimento (não produção)
- **Uso**: Baselines servem como referência para detectar regressões de performance
- **Variabilidade**: Valores podem variar ±10-20% dependendo de carga do sistema e configuração do driver
