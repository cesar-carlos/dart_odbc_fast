# Convencoes FFI (Fase 1)

Documento que define padroes para a API C ABI `odbc_*`.

## Codigos de retorno

| Codigo | Significado | Quando usar |
|--------|-------------|-------------|
| `0` | Sucesso | Operacao concluida com sucesso |
| `-1` | Erro geral | Ponteiro invalido, lock falhou, ID inexistente, erro de execucao |
| `-2` | Buffer insuficiente | `out_buffer` menor que dados a escrever |
| `1` | Sem dados / nao aplicavel | Ex.: `odbc_get_structured_error` quando nao ha erro estruturado |

### Funcoes que retornam ID (conn_id, stmt_id, stream_id, etc.)

- **Sucesso**: retorna ID > 0
- **Falha**: retorna 0

## Contrato de `out_written`

Para funcoes com parametro `out_written: *mut c_uint`:

- **Sucesso (retorno 0)**: `*out_written` = numero de bytes escritos em `out_buffer`
- **Erro (retorno != 0)**: `*out_written` = 0 (quando ponteiro valido)
- **Ponteiro nulo**: funcao retorna -1 sem escrever; caller nao deve dereferenciar

## Geracao de IDs

- **Estrategia padronizada**: todos os IDs usam `wrapping_add(1)` para evitar panic em overflow
- **Colisao**: ao alocar ID na camada FFI (`GlobalState`), verificar se ja existe no mapa; se existir, incrementar ate achar livre (max tentativas: 1000)
- **Colisao em `HandleManager`**: connection IDs tambem verificam colisao com max tentativas de 1000
- **IDs iniciais**:
  - `conn_id`: 1 (gerenciado por `HandleManager`)
  - `stmt_id`: 1
  - `stream_id`: 1
  - `pool_id`: 1
  - `pooled_conn_id`: 1_000_000 (espaco separado para evitar colisao com conn_id)
  - `txn_id`: 1
- **Invariante**: ID 0 e sempre invalido/reservado para indicar falha de alocacao

## Validacao de ponteiros

- Antes de dereferenciar: checar `ptr.is_null()`
- Para `out_written`: checar `out_written.is_null()` antes de escrever
- Para buffers de saida: checar `buffer_len == 0` quando aplicavel
