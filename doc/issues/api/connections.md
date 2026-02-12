# Connections - Fase e Escopo

Last updated: 2026-02-11

## Estado atual

- connect/disconnect com login timeout.
- pool create/get/release/health/state/close.
- backend async por worker isolate.

## Escopo por fase

| Fase        | Escopo                                       | Issues             |
| ----------- | -------------------------------------------- | ------------------ |
| Fase 0 (P0) | sem mudanca estrutural em connections        | -                  |
| Fase 1 (P1) | padronizacao de contrato e telemetria basica | CONN-001, CONN-002 |
| Fase 2 (P2) | estrategia explicita de reuse                | CONN-003           |

## Fase 1 (P1)

### CONN-001 - Contrato unico de lifecycle

Objetivo:

- alinhar comportamento sync/async para os mesmos cenarios de erro.

Criterios:

- mesmos codigos de erro para falhas equivalentes.
- testes de integracao para timeout, invalid DSN e disconnect.

### CONN-002 - Pool telemetry minima

Objetivo:

- expor metricas operacionais basicas de pool.

Criterios:

- API sem quebra retroativa.
- teste para pool vazio, ocupado e fechado.

## Fase 2 (P2)

### CONN-003 - Política de reutilização explícita

**Status**: ✅ Completo

**Objetivo**:

Definir e documentar política de reutilização de conexões no Dart.

Criterios:

- regra de reuse documentada com tradeoffs.
- teste de nao regressao em paralelo.

#### 1. Política de Reuse Implementada

**Regra padrão**: Connections NÃO são reutilizadas por padrão. Cada chamada a `connect()` cria uma nova conexão.

```dart
// Cada operação cria nova conexão
final conn1 = await service.connect(dsn);
final conn2 = await service.connect(dsn);  // Nova conexão (não reutiliza conn1)
```

#### 2. Pool de Conexões (Recomendado para Produção)

Para ambientes de produção, usar **pool de conexões** para gerenciar reutilização automatica:

```dart
// Criar pool de conexões
final poolId = await service.poolCreate(
  'DSN=MyDatabase;UID=user;PWD=pass',
  maxSize: 10,
);

// Obter conexão do pool (reutilização automática)
final conn = await service.poolGetConnection(poolId);
final result = await service.executeQuery(conn.id, 'SELECT * FROM users');

// Liberar conexão de volta para o pool (reutilizável)
await service.poolReleaseConnection(conn.id);
```

**Trade-offs**: Pool vs Conexões Diretas

| Aspecto          | Pool                             | Diretas                              |
| ---------------- | -------------------------------- | ------------------------------------ |
| **Performance**  | Alta                             | Baixa                                |
| **Memória**      | Mais (múltiplas conexões)        | Menos (uma conexão)                  |
| **Complexidade** | Alta (gerenciamento adicional)   | Baixa (uso simples)                  |
| **Telemetria**   | Integrada (métricas automáticas) | Manual (sem métricas)                |
| **State**        | Centralizado (no pool)           | Distribuído (cada chamada)           |
| **When to use**  | Produção, alta carga             | Desenvolvimento, testes, baixa carga |

#### 3. Boas Práticas

**Para Pool de Conexões**:

- ✅ Sempre usar `poolReleaseConnection()` no `finally` ou garantir liberação
- ✅ Usar `poolGetState()` para verificar tamanho e uso atual
- ✅ Usar `poolHealthCheck()` para verificar saúde do pool periodicamente
- ✅ Não reutilizar conexões após chamar `disconnect()`
- ✅ Definir `maxSize` apropriado para workload (não criar pool sem limite)

**Para Conexões Diretas**:

- ✅ Chamar `disconnect()` no `finally` para garantir fechamento
- ✅ Manter lifetime curto (não segurar conexão por tempo desnecessário)
- ✅ Detectar leaks usando telemetria ou audit (quando possível)
- ✅ Não reutilizar mesma conexão após `disconnect()`

#### 4. Anti-patterns (Evitar)

**❌ Anti-patterns de Pool**:

- Reutilizar conexões após `disconnect()` (elas não devem ser reusadas)
- Não fazer release de conexões do pool (causa memory leak)
- Criar pools sem definir `maxSize` (crescimento indefinido)
- Esquecer de chamar `poolReleaseConnection()` (vazamento de recursos)
- Usar `connect()` em loops longos sem liberar conexões

**❌ Anti-patterns de Conexões Diretas**:

- Chamar `connect()` repetidamente sem `disconnect()` (creep de conexões)
- Abrir múltiplas conexões simultaneamente sem necessidade
- Não tratar erros de conexão (deixar conexões órfãs)
- Usar conexões em operações de longa duração sem cleanup adequado

#### 5. Exemplos de Código

**Pool - Produção**:

```dart
import 'package:odbc_fast/odbc_fast.dart';

void main() async {
  final service = OdbcService(repository);

  await service.initialize();

  // Criar pool com até 10 conexões
  final poolId = await service.poolCreate(
    'DSN=ProductionDB;UID=app;PWD=secret;',
    maxSize: 10,
  );

  try {
    // Usar múltiplas operações com reutilização
    for (var i = 0; i < 100; i++) {
      final conn = await service.poolGetConnection(poolId);

      final result = await service.executeQuery(
        conn.id,
        'SELECT * FROM products WHERE id = ?',
      );

      // Libera para reutilização por outras operações
      await service.poolReleaseConnection(conn.id);
    }

    // Verificar estado final do pool
    final state = await service.poolGetState(poolId);
    print('Pool state: ${state.activeConnections}/${state.totalCreated}');

  } finally {
    // Sempre fechar o pool ao final
    await service.poolClose(poolId);
  }
}
```

**Diretas - Desenvolvimento/Testes**:

```dart
import 'package:odbc_fast/odbc_fast.dart';

void main() async {
  final service = OdbcService(repository);

  await service.initialize();

  Connection? conn;

  try {
    // Conexão simples para operação única
    conn = await service.connect('DSN=TestDB;UID=user;PWD=pass;');

    final result = await service.executeQuery(
      conn.id,
      'SELECT COUNT(*) FROM users',
    );

    print('User count: ${result.fold(
      (qr) => qr.rowCount,
      (error) => error.toString(),
    )}');

  } finally {
    // Sempre fechar a conexão
    if (conn != null && conn.isSuccess()) {
      final connection = conn.getOrElse((_) => throw Exception());
      await service.disconnect(connection.id);
    }
  }
}
```

**Misto - Pool para Alta Disponibilidade**:

```dart
// Pool com health check para produção
class ConnectionManager {
  late String _poolId;

  Future<void> initialize() async {
    _poolId = await service.poolCreate(dsn, maxSize: 20);

    // Health check periódico
    Timer.periodic(Duration(seconds: 30), (_) async {
      final isHealthy = await service.poolHealthCheck(_poolId);
      if (!isHealthy) {
        print('Pool unhealthy - recreating');
        await service.poolClose(_poolId);
        _poolId = await service.poolCreate(dsn, maxSize: 20);
      }
    });
  }

  Future<void> executeQuery(String sql) async {
    final conn = await service.poolGetConnection(_poolId);
    try {
      return await service.executeQuery(conn.id, sql);
    } finally {
      await service.poolReleaseConnection(conn.id);
    }
  }
}
```

## Fora de escopo (core)

- router cross-database com failover automatico.
- federacao de query entre bancos no mesmo request.
