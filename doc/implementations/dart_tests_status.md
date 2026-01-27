# Status dos Testes Dart - 2026-01-27

## Resumo

**Executado:** `dart test --exclude-tags=requires-db`

| Métrica | Valor |
|---------|--------|
| ✅ Testes passados | 68+ |
| ⏭️ Testes skipados | 2 |
| ❌ Testes falhados (timeout) | Vários testes async |
| Tempo de execução | > 1min 25s (interrompido) |

## Problemas Identificados

### Timeouts em Testes Async

Alguns testes do `AsyncNativeOdbcConnection` estão dando timeout (30s):

```
test\infrastructure\native\async_native_odbc_connection_test.dart:
  - AsyncNativeOdbcConnection should handle errors gracefully [TIMEOUT 30s]
  - AsyncNativeOdbcConnection should execute multiple queries (all complete without deadlock) [TIMEOUT 15s]
  - AsyncNativeOdbcConnection should handle getStructuredError async [TIMEOUT 30s]

test\integration\async_api_integration_test.dart:
  - Async API Integration Tests should handle transactions with real database [TIMEOUT 30s]
  - Async API Integration Tests should handle prepared statements with real database [TIMEOUT 30s]
  - Async API Integration Tests should handle pool operations with real database [TIMEOUT 30s]

test\stress\isolate_stress_test.dart:
  - Isolate Stress Tests should handle 100 concurrent operations without deadlock [TIMEOUT 2min]

test\integration\select_one_test.dart:
  - SELECT 1 should return 1 [TIMEOUT após conectar]
```

**Causa provável:** Worker isolate não está respondendo corretamente ou há deadlock na comunicação SendPort/ReceivePort.

## Testes que Passaram

✅ **68+ testes** passando:
- `odbc_native_test.dart` - FFI bindings
- `structured_error_test.dart` - Desserialização de erros
- `metrics_parser_test.dart` - Parsing de métricas
- `param_value_test.dart` - Serialização de parâmetros
- `bulk_insert_builder_test.dart` - Builder de bulk insert
- Vários testes de inicialização async (quando não conectam)

## Testes Skipados

⏭️ **2 testes** skipados (esperado):
- `Native Assets should load library via Native Assets`
- `Native Assets should load library from custom path`

## Próximos Passos

### 1. Investigar Worker Isolate

Verificar `lib/infrastructure/native/isolate/worker_isolate.dart`:
- SendPort/ReceivePort estão configurados corretamente?
- Há algum ponto onde o worker pode travar?
- Error handling está propagando corretamente?

### 2. Adicionar Timeout nos Workers

No `worker_isolate.dart`, adicionar timeout interno:

```dart
receivePort.listen((message) async {
  try {
    final response = await _handleRequest(message).timeout(
      Duration(seconds: 25),
      onTimeout: () => ErrorResponse(...),
    );
    mainSendPort.send(response);
  } catch (e) {
    mainSendPort.send(ErrorResponse(...));
  }
});
```

### 3. Debug Individual

Rodar teste individual para isolar problema:

```bash
dart test test/infrastructure/native/async_native_odbc_connection_test.dart --plain-name "should handle errors gracefully"
```

### 4. Verificar Native Connection

Testar se `NativeOdbcConnection` (sync) funciona isoladamente:

```bash
dart test test/infrastructure/native/bindings/odbc_native_test.dart
```

## Compilação Rust

✅ Rust está compilando com as alterações atuais:
- `cargo check -p odbc_engine` → EXIT 0
- `cargo build -p odbc_engine --release` → Compilou mas falhou ao gravar DLL (DLL em uso)

## Recomendação

Antes de continuar testando:
1. Fechar qualquer processo que use `odbc_engine.dll`
2. Recompilar em release: `cargo build -p odbc_engine --release`
3. Investigar deadlock em `worker_isolate.dart` (SendPort/ReceivePort)
4. Adicionar logs debug no worker para ver onde trava
