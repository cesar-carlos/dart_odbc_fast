# Async Execute API — Design (M2 Feature 2.1)

> **Status**: Etapa 1 — Design  
> **Objetivo**: API FFI não-bloqueante para execução de queries longas

## Contexto

- **Atual**: `odbc_exec_query` e variantes são síncronas — bloqueiam até completar.
- **Dart**: `AsyncNativeOdbcConnection` usa worker isolate; o worker bloqueia no FFI.
- **Problema**: Queries longas bloqueiam o worker; múltiplas queries sequenciais somam latência.

## Abordagem: Poll-based (sem callbacks C)

Evitar callbacks C → Dart para simplificar e evitar problemas de isolate/cross-thread.

### Lifecycle

```
odbc_execute_async(conn_id, sql) → request_id
         │
         ▼
    [Background task no Tokio]
         │
         ▼
odbc_async_poll(request_id, out_status) → 0=pending, 1=ready, -1=error/cancelled
         │
         ▼ (quando status=ready)
odbc_async_get_result(request_id, buffer, len, out) → 0=ok, -1=error, -2=buffer small
         │
         ▼
odbc_async_free(request_id) → libera recursos (opcional, ou auto-cleanup)
```

### Tipos C (FFI)

```c
// Status codes for odbc_async_poll
#define ODBC_ASYNC_PENDING  0
#define ODBC_ASYNC_READY    1
#define ODBC_ASYNC_ERROR   -1
#define ODBC_ASYNC_CANCELLED -2

// odbc_execute_async(conn_id, sql) -> request_id
// Returns 0 on failure (check odbc_get_error)
unsigned int odbc_execute_async(unsigned int conn_id, const char *sql);

// odbc_async_poll(request_id, out_status) -> 0=ok, -1=invalid request
// out_status: ODBC_ASYNC_PENDING, ODBC_ASYNC_READY, ODBC_ASYNC_ERROR, ODBC_ASYNC_CANCELLED
int odbc_async_poll(unsigned int request_id, int *out_status);

// odbc_async_get_result(request_id, buffer, len, out_written) -> 0=ok, -1=error, -2=buffer small
// Only valid when poll returned ODBC_ASYNC_READY
int odbc_async_get_result(unsigned int request_id, uint8_t *buffer,
                          unsigned int buffer_len, unsigned int *out_written);

// odbc_async_cancel(request_id) -> 0=ok, -1=invalid/already done
int odbc_async_cancel(unsigned int request_id);

// odbc_async_free(request_id) -> 0=ok (idempotent)
// Frees resources; required after get_result or cancel to avoid leaks
int odbc_async_free(unsigned int request_id);
```

### Estado interno (Rust)

```rust
struct AsyncRequest {
    conn_id: u32,
    sql: String,
    status: AsyncStatus,  // Pending | Ready(Result<Vec<u8>, OdbcError>) | Cancelled
    join_handle: Option<JoinHandle<()>>,  // ou task handle Tokio
}

enum AsyncStatus {
    Pending,
    Ready(Result<Vec<u8>, OdbcError>),
    Cancelled,
}
```

### Integração com async_bridge

- `odbc_execute_async`: spawn `tokio::spawn(async { execute_query_with_connection(...) })`, armazena `JoinHandle` ou `AbortHandle`.
- `odbc_async_poll`: verifica se a task terminou; se sim, atualiza status para Ready/Error.
- `odbc_async_get_result`: serializa o resultado para o buffer; retorna -2 se buffer pequeno.
- `odbc_async_cancel`: chama `AbortHandle::abort()` na task.

### Limites

- Máximo de N requests ativas (ex: 64). `allocate_async_request_id` falha se exceder.
- Request IDs reutilizáveis após `odbc_async_free`.

## Protótipo (Etapa 1)

1. Criar `AsyncRequestManager` em `GlobalState` com `HashMap<u32, AsyncRequest>`.
2. Implementar `odbc_execute_async` que spawna a task e retorna request_id.
3. Implementar `odbc_async_poll` que verifica o status.
4. Teste mínimo: iniciar request, poll até ready, obter resultado.

## Compatibilidade com Dart

- **Worker isolate**: pode chamar `odbc_execute_async`, depois poll em loop (ou com backoff) até ready, então `odbc_async_get_result`. O worker não bloqueia na query — bloqueia apenas no poll (que é rápido).
- **Alternativa**: adicionar `ExecuteQueryAsyncRequest` ao protocolo do worker; o worker gerencia o ciclo poll/get_result e envia a resposta quando pronto.

## Próximos passos (Etapa 2+)

- [ ] AsyncRequest struct
- [ ] AsyncRequestManager em GlobalState
- [ ] allocate_async_request_id / next_request_id
- [ ] Integração com execute_query_with_connection
- [ ] FFI exports e testes

---

## Extensão: Async Stream (Feature 2.2)

A estratégia de async stream segue o mesmo princípio poll-based (sem callbacks C):

```
odbc_stream_start_async(conn_id, sql, fetch_size, chunk_size) -> stream_id
        │
        ▼
odbc_stream_poll_async(stream_id, out_status)
        │       status: 0=pending, 1=ready, 2=done, -1=error, -2=cancelled
        ▼
odbc_stream_fetch(stream_id, buffer, len, out_written, out_has_more)
        │
        ▼
odbc_stream_close(stream_id)
```

### Decisão de design

- Reuso de `odbc_stream_fetch` e `odbc_stream_close` para compatibilidade.
- `odbc_stream_poll_async` desacopla prontidão de dados do ato de copiar chunks.
- Sem `NativeCallable` / callback C→Dart: menor complexidade de isolate e threading.

## Nota: cbindgen

O módulo `async_request.rs` (com `AtomicBool`, `thread::JoinHandle`, etc.) causou
erro de parse no cbindgen ("cannot parse string into token stream"). Opções:
1. Mover para crate separado (não parseado pelo cbindgen)
2. Usar feature flag para excluir do build default
3. Investigar sintaxe específica que quebra o syn/cbindgen
