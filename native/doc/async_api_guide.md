# Async API Guide

> **User-facing guide** for non-blocking ODBC operations.  
> **Complementa**: `async_api_design.md` (design técnico), `ffi_api.md` (FFI reference)

---

## Quando usar Sync vs Async

| Cenário | Recomendação |
|---------|--------------|
| **UI thread** (Flutter, etc.) | Sempre use async. Evita bloqueio da UI. |
| **CLI / scripts** | Sync é aceitável; async é opcional. |
| **Queries longas** (> 1 s) | Preferir async para não bloquear o worker. |
| **Streaming de grandes volumes** | Use `streamAsync` para memória limitada. |
| **Múltiplas queries paralelas** | Async permite executar em paralelo sem somar latência. |

---

## Arquitetura

```
Main thread (Dart)                    Worker isolate
     │                                      │
     │  executeAsync(connId, sql)           │
     │ ─────────────────────────────────────────► odbc_execute_async()
     │                                      │     (spawn Tokio task)
     │                                      │
     │  poll (loop)                         │
     │ ─────────────────────────────────────────► odbc_async_poll()
     │                                      │
     │  get_result                         │
     │ ◄───────────────────────────────────────── odbc_async_get_result()
     │                                      │
```

O worker isolate **não bloqueia** durante a execução da query. O poll é rápido e o resultado é obtido quando o status indica `ready`.

---

## Uso básico

### `executeAsync` — query única

```dart
final async = AsyncNativeOdbcConnection(
  requestTimeout: Duration(seconds: 30),
  autoRecoverOnWorkerCrash: true,
);

await async.initialize();
final connId = await async.connect(dsn);

// Executa SQL sem bloquear
final raw = await async.executeAsync(connId, 'SELECT 1 AS id, GETDATE() AS dt');
if (raw == null) {
  print('Erro: ${await async.getError()}');
} else {
  final parsed = BinaryProtocolParser.parse(raw);
  print('Rows: ${parsed.rowCount}');
}

await async.disconnect(connId);
async.dispose();
```

### `streamAsync` — streaming de grandes resultados

```dart
final async = AsyncNativeOdbcConnection(requestTimeout: Duration(seconds: 60));
await async.initialize();
final connId = await async.connect(dsn);

// Stream em batches (poll-based)
await for (final batch in async.streamAsync(
  connId,
  'SELECT * FROM large_table',
  fetchSize: 1000,
  chunkSize: 64 * 1024,
)) {
  for (final row in batch.rows) {
    process(row);
  }
}

await async.disconnect(connId);
async.dispose();
```

---

## Parâmetros importantes

### `executeAsync`

| Parâmetro | Default | Descrição |
|-----------|---------|-----------|
| `pollInterval` | 10 ms | Intervalo entre polls no worker |
| `timeout` | `requestTimeout` | Timeout máximo por request |
| `maxBufferBytes` | null | Limite de bytes no resultado (evita OOM) |

### `streamAsync`

| Parâmetro | Default | Descrição |
|-----------|---------|-----------|
| `fetchSize` | 1000 | Linhas por batch no engine |
| `chunkSize` | 64 KB | Bytes por chunk FFI |
| `pollInterval` | 10 ms | Intervalo entre polls |
| `maxBufferBytes` | null | Limite de buffer acumulado |

---

## Boas práticas

1. **Sempre dispose** `AsyncNativeOdbcConnection` quando não for mais usado.
2. **Use `requestTimeout`** para evitar hangs se o worker travar.
3. **`autoRecoverOnWorkerCrash`**: em produção, considere `true` para recuperar após crash do worker.
4. **Cancelamento**: use `asyncCancel(requestId)` para cancelar requests longas; chame `asyncFree` após cancel ou get_result.
5. **Streaming**: para tabelas grandes, prefira `streamAsync` em vez de `executeAsync` para evitar OOM.

---

## Erros e recuperação

- **`executeAsync` retorna `null`**: verifique `getError()` ou `getStructuredError()`.
- **Timeout**: `executeAsync` cancela automaticamente se `timeout` for excedido.
- **Worker crash**: com `autoRecoverOnWorkerCrash: true`, o recovery invalida todas as conexões; reconecte após o crash.

---

## Migration Guide: Sync → Async

### Antes (sync)

```dart
final native = NativeOdbcConnection();
native.initialize();
final connId = native.connect(dsn);

final raw = native.executeQuery(connId, 'SELECT 1');
final parsed = BinaryProtocolParser.parse(raw);

native.disconnect(connId);
```

### Depois (async)

```dart
final async = AsyncNativeOdbcConnection();
await async.initialize();
final connId = await async.connect(dsn);

final raw = await async.executeAsync(connId, 'SELECT 1');
final parsed = raw != null ? BinaryProtocolParser.parse(raw) : null;

await async.disconnect(connId);
async.dispose();
```

### Mudanças principais

| Sync | Async |
|------|-------|
| `NativeOdbcConnection` | `AsyncNativeOdbcConnection` |
| `initialize()` | `await initialize()` |
| `connect(dsn)` | `await connect(dsn)` |
| `executeQuery(connId, sql)` | `await executeAsync(connId, sql)` |
| `disconnect(connId)` | `await disconnect(connId)` |
| — | `async.dispose()` |

### Prepare/Execute

| Sync | Async |
|------|-------|
| `prepare(connId, sql)` | `await prepare(connId, sql)` |
| `executePrepared(stmtId, params, ...)` | `await executePrepared(stmtId, params, ...)` |
| `closeStatement(stmtId)` | `await closeStatement(stmtId)` |

### Streaming

| Sync | Async |
|------|-------|
| `streamQueryBatched(connId, sql)` | `await for (batch in async.streamAsync(connId, sql))` |
| `NativeOdbcConnection` | `AsyncNativeOdbcConnection` |

---

## Exemplos

- `example/async_demo.dart` — prepare/execute com async
- `example/execute_async_demo.dart` — `executeAsync` e `streamAsync` diretos
- `example/async_service_locator_demo.dart` — ServiceLocator com `useAsync: true`

---

## Referências

- `ffi_api.md` — funções FFI `odbc_execute_async`, `odbc_async_poll`, `odbc_stream_start_async`
- `async_api_design.md` — design técnico e lifecycle
