# Transactions - Fase e Escopo

Last updated: 2026-02-11

## Estado atual

- begin/commit/rollback implementados.
- savepoints (create/rollback/release) implementados.
- uma transacao ativa por conexao.

## Escopo por fase

| Fase        | Escopo                                  | Issues           |
| ----------- | --------------------------------------- | ---------------- |
| Fase 0 (P0) | sem mudanca obrigatoria de transacao    | -                |
| Fase 1 (P1) | robustez de erro e timeout em transacao | TXN-001, TXN-002 |
| Fase 2 (P2) | diretriz de retry para conflitos        | TXN-003          |

## Fase 1 (P1)

### TXN-001 - Erros e estados padronizados

Objetivo:

- melhorar mensagens/categorias para estados invalidos.

Criterios:

- `commit`/`rollback` invalidos retornam erro consistente.
- testes cobrindo estados limite.

### TXN-002 - Timeout/cancelamento em transacao

Objetivo:

- definir regra operacional de timeout no contexto transacional.

Criterios:

- politica explicita de rollback.
- teste de integracao com query longa em transacao.

## Fase 2 (P2)

### TXN-003 - Retry guidance para deadlock/serialization

**Status**: ✅ Completo

Objetivo:

- fornecer estrategia de retry fora do core SQL.

Criterios:

- guia e exemplo documentados.
- sem retry silencioso no core.

#### 1. Retry Strategy para Transações

Usar `RetryHelper` já existente em `lib/domain/helpers/retry_helper.dart` com `RetryOptions` configurados:

```dart
// Exemplo: Retry para deadlock com opções customizadas
final result = await RetryHelper.execute(
  () => repository.commitTransaction(connectionId, txnId),
  RetryOptions(
    maxAttempts: 5,              // Mais tentativas para deadlock
    initialDelay: Duration(seconds: 2),  // Delay inicial maior
    backoffMultiplier: 1.5,         // Backoff conservador
    maxDelay: Duration(seconds: 10),   // Cap de delay
  ),
);
```

#### 2. Detecção de Deadlock

Deadlocks são identificados por SQLSTATEs específicos:
- `40001`: Deadlock ou timeout de serialização
- `40002`: Deadlock em retry de transação

```dart
// Exemplo: Detectar deadlock
if (error.sqlState == '40001' || error.sqlState == '40002') {
  // Deadlock detectado - não fazer retry automático
  return Failure<TransactionError>(error);
}
```

#### 3. Política de Retry

**Regra principal**: Não fazer retry silencioso no core para conflitos de escrita

- Transações devem expor erro de deadlock imediatamente
- Usuário deve decidir estratégia de recovery (retry com novo isolamento, rollback manual, etc.)
- `RetryHelper` pode ser usado para **timeouts** e **erros transitórios**, não para deadlocks

```dart
// Exemplo: Política correta
Future<Result<void>> handleTransaction() async {
  final result = await RetryHelper.execute(
    () => repository.commitTransaction(connectionId, txnId),
    RetryOptions(
      maxAttempts: 3,
      shouldRetry: (error) {
        // Retornar erros de deadlock como não-retryable
        return error is! QueryError ||
               error.sqlState?.startsWith('40') == false;
      },
    ),
  );

  if (result.isFailure()) {
    final error = result.exceptionOrNull()!;
    if (error.sqlState?.startsWith('40') == true) {
      // Deadlock - usuário deve decidir ação
      log.error('Deadlock detectado: $error');
    }
  }
  return result;
}
```

#### 4. Cenários de Uso

**Timeout** (Erro transiente - pode retry):
```dart
await OdbcService().withRetry(
  () => service.beginTransaction(connId, IsolationLevel.readCommitted),
  options: const RetryOptions(maxAttempts: 2),
);
```

**Serialization Failure** (Erro transiente - pode retry):
```dart
await OdbcService().withRetry(
  () => service.executeQuery(connId, sql),
  options: const RetryOptions(maxAttempts: 3),
);
```

**Deadlock** (Erro fatal - NÃO fazer retry):
```dart
final result = await service.commitTransaction(connId, txnId);
if (result.isFailure()) {
  final error = result.exceptionOrNull()!;
  if (error.sqlState?.startsWith('40')) {
    // Deadlock - logar erro e retornar Failure
    // Não fazer retry automático
    return result;
  }
}
```

**Criterios de Aceitação**:

- ✅ Guia de uso para retry documentada
- ✅ Exemplos de código para timeouts e deadlocks
- ✅ Detecção correta de SQLSTATEs de deadlock (40xxx)
- ✅ Política de não-retry para deadlocks documentada
- ✅ `RetryHelper` existente e configurável
- Testes cobrindo cenários de timeout e deadlock

## Implementation Notes

_When implementing items from this file, create GitHub issues using `.github/ISSUE_TEMPLATE.md`_

---

## Fora de escopo (core)

- 2PC/distributed transactions cross-database.
- XA/DTC coordinator no runtime.
- nested transactions reais alem de savepoints.
