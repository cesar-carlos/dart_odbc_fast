# Async API Guide

> **User-facing guide** for non-blocking ODBC operations.  
> **Complementa**: `ffi_api.md` (FFI reference)

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

## Worker pool Dart

`AsyncNativeOdbcConnection` aceita `workerCount` opcional. O default e `1`,
preservando comportamento e consumo historicos. Com `workerCount > 1`, o
backend cria multiplos worker isolates Dart e despacha chamadas independentes
para o worker menos carregado.

```dart
final async = AsyncNativeOdbcConnection(
  workerCount: 4,
  maxPendingRequests: 16,
);
await async.initialize();
```

Via service locator:

```dart
final locator = ServiceLocator()
  ..initialize(
    useAsync: true,
    asyncWorkerCount: 4,
    asyncMaxPendingRequests: 16,
  );
```

Regras de concorrencia:

- `connect`, `poolGetConnection` e operacoes sem handle usam roteamento por carga.
- Operacoes por connection, statement, transaction, stream e async request mantem afinidade com o worker que recebeu o handle.
- Os IDs publicos continuam sendo os IDs nativos; nao existe ID virtual Dart.
- Paralelismo real exige multiplas conexoes ou checkouts de pool. A mesma conexao continua serializada pelo mutex nativo da conexao.
- `maxPendingRequests` / `asyncMaxPendingRequests` sao backpressure opt-in. Use um limite proximo de `poolSize * 2` ou `poolSize * 4` quando o workload usa pool nativo.
- `backpressureMode` pode ser `failFast` (default) ou `waitForSlot`. `waitForSlot` aguarda vaga FIFO ate `backpressureTimeout`.
- `getWorkerPoolStats()` retorna contadores Dart-side agregados e por worker, incluindo cancelamento e latencia.
- Timeout de requests async tenta `asyncCancel`/`asyncFree`; streaming tenta `streamCancel` antes de `streamClose` quando a stream nao termina normalmente.
- Cancelamento e best-effort quando o driver ODBC ja esta bloqueado dentro de uma chamada nativa.

Tuning recomendado:

- API web com pool: `workerCount = min(poolSize, cores)` e `maxPendingRequests = poolSize * 2..4`.
- Batch: `workerCount = poolSize`; use streaming para resultados grandes.
- Flutter/UI: mantenha `workerCount = 1`, salvo quando houver multiplas conexoes reais.

Exemplos documentados:

- `example/high_concurrency_worker_pool_demo.dart`
- `example/high_concurrency_pool_demo.dart`
- `example/async_concurrency_benchmark.dart` - compara worker pool, pool nativo,
  streaming, `ResultEncoding.columnar`, `ResultEncoding.columnarCompressed` e
  prepared reuse.

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
4. **Cancelamento**: `asyncCancel(requestId)` e best-effort sobre request async Rust; chame `asyncFree` apos cancel ou get_result. `streamCancel` e efetivo entre batches/iteracoes. `cancelStatement` pode retornar unsupported dependendo do caminho e do driver.
5. **Streaming**: para tabelas grandes, prefira `streamAsync` em vez de `executeAsync` para evitar OOM.

---

## Erros e recuperação

- **`executeAsync` retorna `null`**: verifique `getError()` ou `getStructuredError()`.
- **Timeout**: `executeAsync` cancela automaticamente se `timeout` for excedido.
- **Worker crash**: com `autoRecoverOnWorkerCrash: true`, o recovery invalida todas as conexões; reconecte após o crash.
- **Queue cheia**: quando `maxPendingRequests` e excedido, a chamada falha com `AsyncErrorCode.resourceExhausted` antes de ser enviada para o worker.

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
- `example/high_concurrency_worker_pool_demo.dart` - worker pool com multiplas conexoes
- `example/high_concurrency_pool_demo.dart` - pool nativo com limite de tarefas em voo
- `example/async_concurrency_benchmark.dart` - benchmark local de worker pool, pool nativo e streaming

---

## Referências

- `ffi_api.md` - funcoes FFI `odbc_execute_async`, `odbc_execute_async_params`, `odbc_async_poll`, `odbc_stream_start_async`
