# Prepared Statements - Fase e Escopo

Last updated: 2026-02-11

## ✅ FASE 0 CONCLUÍDA

Fase 0 (P0) foi completada com sucesso em 2026-02-11, abrangendo as melhorias críticas de estabilidade:

- ✅ **REQ-001** (Multi-result): Parser e payload binário definido em `multi-result.md`
- ✅ **REQ-002** (Limite de 5 parâmetros): Limite mantido para compatibilidade, melhoria de mensagem de erro para >5 params
- ✅ **REQ-003** (Suporte real a NULL): NULL convertido para string vazia, funções auxiliares adicionadas
- ✅ **REQ-004** (Contrato de cancelamento): Erro tipado `UnsupportedFeature` adicionado ao módulo de erros
- ✅ **CONN-001** (Connection Lifecycle): Lifecycle único, pool telemetry e state machine definidos
- ✅ **TXN-001** (Transaction Isolation): Isolation levels, error states e rollback/savepoints documentados
- ✅ **TXN-002** (Timeout/Cancel): Timeout mechanisms e cancel contract especificados

---

## Estado atual

- `prepare(connectionId, sql, timeoutMs)` implementado.
- `executePrepared(stmtId, params)` com parametros posicionais.
- `closeStatement(stmtId)` implementado.
- `cancel(stmtId)` retorna UnsupportedFeature (REQ-004 completado).

## Escopo por fase

| Fase        | Escopo                                              | Issues             |
| ----------- | --------------------------------------------------- | ------------------ |
| Fase 0 (P0) | estabilizacao compartilhada com requests (`cancel`) | REQ-004            |
| Fase 1 (P1) | lifecycle e options de prepared                     | PREP-001, PREP-002 |
| Fase 2 (P2) | named param facade e extensao plugin                | PREP-003, PREP-004 |

## Fase 1 (P1)

### PREP-001 - Lifecycle explicito prepare/execute/unprepare

**Status**: Pending

**Objetivo**:

Expor `unprepare` como alias claro de close statement e implementar cache LRU para prepared statements.

**Escopo**:

Esta issue abrange:

#### 1. Cache LRU Strategy

- **Key Generation**: Hash da query SQL + connection_id
- **Max Size**: Configurável (default: 50 statements por connection)
- **Eviction Policy**: Remove menos recentemente usado quando atinge limite
- **TTL**: Time-to-live opcional para auto-expiração
- **Thread Safety**: Cache protegido por mutex/RwLock para acesso concorrente

#### 2. Cache Telemetry

```rust
struct PreparedStatementMetrics {
    cache_size: usize,           // Número atual de statements no cache
    cache_max_size: usize,       // Tamanho máximo do cache
    cache_hits: u64,             // Total de cache hits
    cache_misses: u64,           // Total de cache misses
    hit_rate: f64,               // cache_hits / (cache_hits + cache_misses)
    total_prepares: u64,         // Total de prepares executados
    total_executions: u64,       // Total de execuções
    avg_executions_per_stmt: f64, // total_executions / total_prepares
    memory_usage_bytes: u64,     // Memória estimada do cache
}
```

#### 3. Lifecycle Operations

```dart
// Prepare com cache
Future<PreparedStatement> prepare(String sql, {Duration? timeout}) async {
  // Check cache
  final cacheKey = _hash(sql, connectionId);
  if (_cache.containsKey(cacheKey)) {
    _metrics.cacheHits++;
    return _cache[cacheKey]!;
  }

  // Prepare novo statement
  final stmtId = await _odbcPrepare(connectionId, sql, timeout);
  _metrics.cacheMisses++;
  _metrics.totalPrepares++;

  final stmt = PreparedStatement._(stmtId, sql, this);
  _cache[cacheKey] = stmt;
  return stmt;
}

// Execute multiple times
Future<QueryResult> execute(List<Object?> params) async {
  final result = await _odbcExecutePrepared(stmtId, params);
  _metrics.totalExecutions++;
  return result;
}

// Unprepare (close statement)
Future<void> unprepare() async {
  await _odbcCloseStatement(stmtId);
  _cache.remove(cacheKey);
}

// Clear cache (all or per connection)
Future<void> clearCache({int? connectionId}) async {
  if (connectionId != null) {
    _cache.removeWhere((key, _) => key.connectionId == connectionId);
  } else {
    _cache.clear();
  }
}
```

#### 4. Cache Configuration

```dart
class PreparedStatementConfig {
  /// Maximum number of prepared statements per connection
  final int maxCacheSize;

  /// Time-to-live for prepared statements (null = no expiration)
  final Duration? ttl;

  /// Enable/disable prepared statement cache
  final bool enabled;

  const PreparedStatementConfig({
    this.maxCacheSize = 50,
    this.ttl,
    this.enabled = true,
  });
}
```

**Cenários de Uso**:

##### 1. Single Query Multiple Executions

```dart
// Prepara uma vez
final stmt = await connection.prepareStatement(
  'SELECT * FROM users WHERE department = ? AND status = ?'
);

// Executa múltiplas vezes com parâmetros diferentes
final sales = await stmt.execute(['Sales', 'Active']);
final engineering = await stmt.execute(['Engineering', 'Active']);

// Fecha para liberar recursos
await stmt.unprepare();
```

##### 2. Batch Operations with Transaction

```dart
await transaction.begin();

final stmt = await connection.prepareStatement(
  'INSERT INTO orders (product_id, quantity) VALUES (?, ?)'
);

for (final order in orders) {
  await stmt.execute([order.productId, order.quantity]);
}

await transaction.commit();
await stmt.unprepare();
```

##### 3. Cache Warming

```dart
// Warm-up do cache durante inicialização
final commonQueries = [
  'SELECT * FROM users WHERE id = ?',
  'SELECT * FROM products WHERE category = ?',
  'UPDATE inventory SET quantity = ? WHERE product_id = ?',
];

for (final query in commonQueries) {
  await connection.prepareStatement(query);
}

// Queries subsequentes terão cache hit
```

**Vantagens**:

- **Performance**: SQL é parseado apenas uma vez
- **Execution Plan**: Otimizador cria plano uma vez, reusa múltiplas
- **Network**: Reduz para 1 prepare + N executes vs. N full queries
- **SQL Injection**: Parâmetros são tratados automaticamente

**Limitações**:

- Alguns drivers não suportam prepared statements nativos (fallback para emulate)
- Tipos devem ser consistentes entre prepare e execute
- DDL operations invalidam cache (requer clear manual)

**Criterios de Aceitação**:

- ✅ Cache LRU funcionando com hit rate >80% em workloads típicas
- ✅ Métricas de cache disponíveis via API pública
- ✅ `unprepare` como alias claro de close statement
- ✅ API pública sem ambiguidade
- ✅ Testes para id inválido e double-close
- ✅ Cache pode ser limpo manualmente (todos ou por connection)
- ✅ Suporte a transactions com prepared statements
- ✅ Testes de integração cobrindo lifecycle completo

### PREP-002 - Options por statement

**Status**: Pending

**Objetivo**:

Consolidar timeout e limites por statement com integração sem quebra retroativa.

**Escopo**:

Esta issue abrange:

#### 1. Statement-Level Options

```dart
class StatementOptions {
  /// Timeout para esta execução específica (sobrescreve global)
  final Duration? queryTimeout;

  /// Tamanho máximo do buffer de resultado
  final int? maxBufferSize;

  /// Habilita/desabilita fetch assíncrono
  final bool asyncFetch;

  /// Número de rows por batch (default: 1000)
  final int fetchSize;

  const StatementOptions({
    this.queryTimeout,
    this.maxBufferSize,
    this.asyncFetch = false,
    this.fetchSize = 1000,
  });
}
```

#### 2. Integration Points

```dart
// Em PreparedStatement
Future<QueryResult> execute(
  List<Object?> params, {
  StatementOptions? options,
}) async {
  final opts = options ?? _defaultOptions;
  return await _odbcExecutePrepared(
    stmtId,
    params,
    queryTimeout: opts.queryTimeout,
    maxBufferSize: opts.maxBufferSize,
    asyncFetch: opts.asyncFetch,
    fetchSize: opts.fetchSize,
  );
}

// Em Connection (para queries diretas)
Future<QueryResult> executeQuery(
  String sql, {
  StatementOptions? options,
}) async {
  // ...
}
```

#### 3. Priority Chain

```
Statement Options → Connection Options → Global Options
```

Exemplo:

```dart
// Global: 30s
final conn = Connection.connect(connString, globalOptions: Options(timeout: 30s));

// Connection: 60s (sobrescreve global)
conn.setDefaultOptions(Options(timeout: 60s));

// Statement: 10s (sobrescreve connection)
await stmt.execute(params, options: StatementOptions(queryTimeout: 10s));
```

**Cenários de Uso**:

##### 1. Timeout específico para query longa

```dart
final stmt = await connection.prepareStatement(
  'SELECT * FROM large_table WHERE complex_condition = ?'
);

// Timeout maior apenas para esta query específica
await stmt.execute([value], options: StatementOptions(
  queryTimeout: Duration(minutes: 5),
));
```

##### 2. Fetch size para streaming

```dart
final stmt = await connection.prepareStatement(
  'SELECT * FROM huge_table'
);

// Fetch size menor para reduzir uso de memória
await stmt.execute([], options: StatementOptions(
  fetchSize: 100,
));
```

##### 3. Limite de buffer para resultados grandes

```dart
await stmt.execute([], options: StatementOptions(
  maxBufferSize: 1024 * 1024, // 1MB
));
```

**Criterios de Aceitação**:

- ✅ Options por statement funcionam sem quebrar código existente
- ✅ Priority chain respeitada (statement → connection → global)
- ✅ Timeout por statement funciona corretamente
- ✅ Teste de timeout com query longa
- ✅ Fetch size respeitado em streaming
- ✅ maxBufferSize aplicado corretamente
- ✅ Integração sem quebra retroativa (null usa defaults)

## Fase 2 (P2)

### PREP-003 - Named param facade no Dart

**Status**: Pending

**Objetivo**:

Converter named params para positional no facade Dart com ordem de bind determinística.

**Escopo**:

Esta issue abrange:

#### 1. Named Parameter Syntax

Suporte a named parameters usando sintaxe padrão:

```dart
// Sintaxe suportada
@name (comercial)
:name (dois pontos)
?name (interrogação)

// Exemplo
final stmt = await connection.prepareStatement('''
  SELECT * FROM users
  WHERE department = @dept
    AND status = :status
    AND created_at > ?since
''');

// Execução com named params
await stmt.execute({
  'dept': 'Sales',
  'status': 'Active',
  'since': DateTime(2024, 1, 1),
});
```

#### 2. Parameter Extraction

```dart
class NamedParameterExtractor {
  /// Extrai named parameters da SQL e retorna ordem determinística
  static (String cleanSql, List<String> paramNames) extract(String sql) {
    final regex = RegExp(r'[@:?](\w+)');
    final matches = regex.allMatches(sql);

    // Extrai nomes mantendo ordem de primeira aparição
    final seen = <String>{};
    final paramNames = <String>[];
    final placeholders = <Match>[];

    for (final match in matches) {
      final name = match.group(1)!;
      if (!seen.contains(name)) {
        seen.add(name);
        paramNames.add(name);
      }
      placeholders.add(match);
    }

    // Substitui por ?
    var cleanSql = sql;
    for (final placeholder in placeholders) {
      cleanSql = cleanSql.replaceFirst(placeholder.group(0)!, '?');
    }

    return (cleanSql, paramNames);
  }
}
```

#### 3. Parameter Binding

```dart
class PreparedStatement {
  final List<String> _paramNames;

  Future<QueryResult> execute(Map<String, Object?> namedParams) async {
    // Converte named para positional mantendo ordem
    final positionalParams = _paramNames
        .map((name) => namedParams[name])
        .toList();

    // Valida que todos os parâmetros foram fornecidos
    final missing = _paramNames.where((name) => !namedParams.containsKey(name));
    if (missing.isNotEmpty) {
      throw ParameterMissingException(
        'Missing required parameters: ${missing.join(", ")}',
      );
    }

    return await _odbcExecutePrepared(stmtId, positionalParams);
  }
}
```

**Exemplo de Uso**:

```dart
// Preparar query com named params
final (cleanSql, paramNames) = NamedParameterExtractor.extract('''
  SELECT * FROM orders
  WHERE customer_id = @customer
    AND status = :status
    AND order_date > ?since
''');
// cleanSql: "SELECT * FROM orders WHERE customer_id = ? AND status = ? AND order_date > ?"
// paramNames: ["customer", "status", "since"]

final stmt = await connection.prepareStatement(cleanSql, paramNames: paramNames);

// Executar com named params
final result = await stmt.execute({
  'customer': 123,
  'status': 'pending',
  'since': DateTime.now().subtract(Duration(days: 30)),
});
```

**Criterios de Aceitação**:

- ✅ Named params funcionam com sintaxe @, :, ?
- ✅ Ordem de bind é determinística (primeira aparição na SQL)
- ✅ Erro claro para placeholder faltante
- ✅ Suporte a @name, :name, ?name
- ✅ Validação de parâmetros em tempo de execução
- ✅ Testes cobrindo todos os formatos de named params

### PREP-004 - Output params via plugin

**Status**: Pending

**Objetivo**:

Suportar output params como extensão opcional por driver, mantendo core multi-driver.

**Escopo**:

Esta issue abrange:

#### 1. Output Parameter Strategy

Output parameters são usados principalmente em stored procedures:

```sql
CREATE PROCEDURE GetUserStats(
  IN userId INT,
  OUT totalOrders INT,
  OUT lastOrderDate DATETIME
)
BEGIN
  SELECT COUNT(*) INTO totalOrders FROM orders WHERE user_id = userId;
  SELECT MAX(order_date) INTO lastOrderDate FROM orders WHERE user_id = userId;
END;
```

#### 2. Plugin-Based Extension

```dart
abstract class OutputParameterPlugin {
  /// Verifica se o driver atual suporta output params
  bool get isSupported;

  /// Registra output parameter
  Future<void> registerOutputParam(
    String paramName,
    OdbcDataType dataType,
  });

  /// Obtém valor de output parameter após execução
  Object? getOutputParam(String paramName);
}

// Exemplo de implementação para SQL Server
class SqlServerOutputPlugin extends OutputParameterPlugin {
  @override
  bool get isSupported => true;

  @override
  Future<void> registerOutputParam(String paramName, OdbcDataType dataType) async {
    // Usa SQLBindParameter com SQL_PARAM_OUTPUT
  }

  @override
  Object? getOutputParam(String paramName) {
    // Retorna valor do buffer de output
  }
}
```

#### 3. Facade Pattern

```dart
class Connection {
  OutputParameterPlugin? _outputPlugin;

  /// Registra plugin para output parameters (driver-specific)
  void registerOutputPlugin(OutputParameterPlugin plugin) {
    if (!plugin.isSupported) {
      throw UnsupportedException(
        'Output parameters not supported for this driver',
      );
    }
    _outputPlugin = plugin;
  }

  /// Executa stored procedure com output params
  Future<QueryResult> executeProcedure(
    String procedureName, {
    Map<String, Object?> inParams = const {},
    Map<String, OdbcDataType> outParams = const {},
  }) async {
    if (_outputPlugin == null) {
      throw UnsupportedException(
        'Output plugin not registered. Use registerOutputPlugin() first.',
      );
    }

    // Registra output parameters
    for (final entry in outParams.entries) {
      await _outputPlugin!.registerOutputParam(entry.key, entry.value);
    }

    // Executa procedure
    final result = await executeQuery(
      'CALL $procedureName(?, ?, ...)',
      params: [...inParams.values, ...outParams.keys],
    );

    return result;
  }

  /// Obtém valor de output parameter
  Object? getOutputParam(String paramName) {
    return _outputPlugin?.getOutputParam(paramName);
  }
}
```

**Exemplo de Uso**:

```dart
// Registrar plugin (SQL Server)
final plugin = SqlServerOutputPlugin();
connection.registerOutputPlugin(plugin);

// Executar procedure com output params
await connection.executeProcedure(
  'GetUserStats',
  inParams: {'userId': 123},
  outParams: {
    'totalOrders': OdbcDataType.integer,
    'lastOrderDate': OdbcDataType.timestamp,
  },
);

// Obter valores de output
final totalOrders = connection.getOutputParam('totalOrders') as int;
final lastOrderDate = connection.getOutputParam('lastOrderDate') as DateTime;

print('Total orders: $totalOrders');
print('Last order: $lastOrderDate');
```

#### 4. Drivers Suportados

Drivers conhecidos por suportar output parameters:

| Driver     | Suporte    | Observações                                                      |
| ---------- | ---------- | ---------------------------------------------------------------- |
| SQL Server | ✅ Sim     | `SQLBindParameter` com `SQL_PARAM_OUTPUT`                        |
| PostgreSQL | ⚠️ Parcial | Apenas via function returns ( Procedures não usam output params) |
| Oracle     | ✅ Sim     | Via `OCI` ou `ODBC` com bind parameters                          |
| MySQL      | ❌ Não     | Usa workaround com `SELECT` ou `OUTFILE`                         |
| SQLite     | ❌ Não     | Não suporta stored procedures nativas                            |

**Limitações**:

- **Universal Support**: Não é possível suportar output params genericamente para todos os drivers
- **Fallback**: Para drivers sem suporte, documentar workaround alternativo
- **Complexidade**: Requer gerenciamento manual de buffers de output
- **Type Mapping**: Output params requerem type mapping correto (INPUT_OUTPUT vs. OUTPUT_ONLY)

**Criterios de Aceitação**:

- ✅ Core continua multi-driver (sem quebrar compatibilidade)
- ✅ Plugin funciona como extensão opcional
- ✅ Drivers suportados documentados
- ✅ Erro claro quando driver não suporta output params
- ✅ Testes de integração para SQL Server (primary target)
- ✅ Documentação de workarounds para drivers sem suporte
- ✅ API pública para registrar/obter output params

---

## Implementation Notes

_When implementing items from this file, create GitHub issues using `.github/ISSUE_TEMPLATE.md`_

---

## Fora de escopo (core)

- Output params genéricos para todos os drivers (impossível devido a limitações de ODBC API)
- TVP (Table-Valued Parameters) e recursos procedure-specific como requisito universal
- Suporte a REF CURSOR (Oracle-specific) no core
