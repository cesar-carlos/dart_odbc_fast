# Roadmap de Melhorias - ODBC Fast

**Versão**: 0.1.6
**Data**: 2026-01-26
**Status**: Production-Ready (4.5/5 estrelas)

Este documento detalha todas as melhorias identificadas através de análise comparativa com projetos similares e melhores práticas da indústria.

---

## 📊 Sumário Executivo

### Avaliação Atual
- **Status**: ✅ Production-Ready
- **Pontuação**: ⭐⭐⭐⭐½ (4.5/5)
- **Código**: ~15.000+ linhas (Dart + Rust)
- **Features**: 16/16 marcos principais implementados

### Categorias de Melhorias
- 🔴 **Alta Prioridade**: 3 melhorias (críticas para produção em escala)
- 🟡 **Média Prioridade**: 4 melhorias (melhorias de funcionalidade)
- 🟢 **Baixa Prioridade**: 3 melhorias (avançadas/futuras)

---

## 🔴 ALTA PRIORIDADE

### 1. Async Dart API

#### Status: IMPLEMENTADO (v0.2.0)

- **Worker isolate** de longa vida (não Isolate.run)
- **Protocolo de mensagens** SendPort/ReceivePort
- **Lifecycle** spawn, initialize, shutdown
- **Error handling** e WorkerCrashRecovery
- **Testes** unit, integration, stress; README, CHANGELOG, MIGRATION_ASYNC, example

#### Status Atual (pré-implementação)
- **Problema (resolvido)**: Chamadas FFI eram síncronas; agora executam em worker isolate
- **Localização**:
  - `lib/infrastructure/native/async_native_odbc_connection.dart`
  - `lib/infrastructure/native/isolate/worker_isolate.dart`
  - `lib/infrastructure/native/isolate/message_protocol.dart`
  - `lib/infrastructure/repositories/odbc_repository_impl.dart`

#### Solução Proposta

Envolver todas as chamadas FFI bloqueantes em `Isolate.run()` para executar em background thread.

**Implementação**:

```dart
// lib/infrastructure/native/async_native_odbc_connection.dart

import 'dart:isolate';
import 'dart:typed_data';

class AsyncNativeOdbcConnection {
  final NativeOdbcConnection _native;

  AsyncNativeOdbcConnection(this._native);

  /// Executa operação blocking em isolate separado
  Future<T> _executeInIsolate<T>(
    T Function() operation,
  ) async {
    return await Isolate.run(() => operation());
  }

  // Connect (async)
  Future<bool> initialize() async {
    return await _executeInIsolate(() => _native.initialize());
  }

  // Query (async)
  Future<Uint8List> executeQuery(
    String connectionString,
    String sql,
  ) async {
    return await _executeInIsolate(
      () => _native.executeQuery(connectionString, sql),
    );
  }

  // Todos os outros métodos seguindo o mesmo padrão...
}
```

**Benefícios**:
- ✅ Non-blocking UI em Flutter
- ✅ Melhor responsividade
- ✅ Padrão usado por `sqflite` e outros packages Dart

**Similar**: `sqflite` (SQLite para Flutter), `package:sqlite3`

**Esforço**: 2-3 dias
**Risco**: Baixo (padrão bem estabelecido)

---

### 2. Connection Timeouts

#### Status Atual
- **Problema**: Conexões podem travar indefinidamente se servidor não responder
- **Impacto**: Aplicação congela; sem forma de abortar conexão travada
- **Localização**: `native/odbc_engine/src/ffi/mod.rs` (odbc_connect)

#### Solução Proposta

Adicionar suporte para connection timeout e query timeout a nível de ODBC.

**Implementação Rust**:

```rust
// native/odbc_engine/src/ffi/mod.rs

#[repr(C)]
pub struct ConnectionOptions {
    pub login_timeout_secs: u32,
    pub query_timeout_secs: u32,
    pub connection_timeout_secs: u32,
}

impl Default for ConnectionOptions {
    fn default() -> Self {
        Self {
            login_timeout_secs: 30,     // 30 segundos
            query_timeout_secs: 0,      // 0 = infinito
            connection_timeout_secs: 15, // 15 segundos
        }
    }
}

// Na função odbc_connect:
#[no_mangle]
pub extern "C" fn odbc_connect_with_timeout(
    conn_str: *const c_char,
    options: *const ConnectionOptions,
) -> u32 {
    let conn_str = unsafe { CStr::from_ptr(conn_str) }.to_string_lossy();
    let opts = unsafe { &*options };

    // Configurar timeouts antes de conectar
    // SQLSetConnectAttr(SQL_LOGIN_TIMEOUT, opts.login_timeout_secs)
    // SQLSetConnectAttr(SQL_CONNECTION_TIMEOUT, opts.connection_timeout_secs)

    // ... resto da implementação
}
```

**Implementação Dart**:

```dart
// lib/domain/entities/connection_options.dart

class ConnectionOptions {
  final Duration loginTimeout;
  final Duration queryTimeout;
  final Duration connectionTimeout;

  const ConnectionOptions({
    this.loginTimeout = const Duration(seconds: 30),
    this.queryTimeout = Duration.zero, // infinite
    this.connectionTimeout = const Duration(seconds: 15),
  });

  static const defaultOptions = ConnectionOptions();
}

// Em OdbcService.connect():
Future<Result<Connection>> connect(
  String connectionString, {
  ConnectionOptions options = ConnectionOptions.defaultOptions,
}) async {
  // ... usar options
}
```

**Benefícios**:
- ✅ Prevenção de deadlocks
- ✅ Fail-fast em problemas de rede
- ✅ Controle de recursos

**Similar**: `node-postgres`, `pymysql`, `psycopg2` (Python PostgreSQL)

**Esforço**: 3-4 dias
**Risco**: Baixo (API ODBC suporta nativamente)

---

### 3. Automatic Retry com Exponential Backoff

#### Status Atual
- **Problema**: Você tem `is_retryable()` mas não tem mecanismo automático
- **Impacto**: Erros transitórios de rede requerem retry manual do usuário
- **Localização**: `lib/domain/errors/odbc_error.dart` (ErrorCategory.transient)

#### Solução Proposta

Implementar retry automático para erros categorizados como `Transient`.

**Implementação**:

```dart
// lib/application/retries/retry_policy.dart

enum RetryStrategy {
  exponentialBackoff,
  fixedDelay,
  none,
}

class RetryOptions {
  final int maxAttempts;
  final Duration initialDelay;
  final Duration maxDelay;
  final double backoffMultiplier;
  final RetryStrategy strategy;

  const RetryOptions({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(milliseconds: 100),
    this.maxDelay = const Duration(seconds: 30),
    this.backoffMultiplier = 2.0,
    this.strategy = RetryStrategy.exponentialBackoff,
  });

  static const defaultOptions = RetryOptions();
}

// Lib/infrastructure/retries/retry_helper.dart

class RetryHelper {
  static Future<T> executeWithRetry<T>(
    Future<T> Function() operation, {
    required RetryOptions options,
    bool Function(OdbcError)? shouldRetry,
  }) async {
    OdbcError? lastError;
    Duration delay = options.initialDelay;

    for (int attempt = 0; attempt < options.maxAttempts; attempt++) {
      try {
        return await operation();
      } on OdbcError catch (e) {
        lastError = e;

        // Verificar se deve retry
        final shouldRetryError = shouldRetry?.call(e)
            ?? (e.category == ErrorCategory.transient);

        if (!shouldRetryError || attempt >= options.maxAttempts - 1) {
          rethrow;
        }

        // Calcular delay baseado na estratégia
        switch (options.strategy) {
          case RetryStrategy.exponentialBackoff:
            await Future.delayed(delay);
            delay = Duration(
              microseconds: (delay.inMicroseconds * options.backoffMultiplier)
                  .clamp(0, options.maxDelay.inMicroseconds)
            );
          case RetryStrategy.fixedDelay:
            await Future.delayed(options.initialDelay);
          case RetryStrategy.none:
            rethrow;
        }
      }
    }

    throw lastError!;
  }
}

// Em OdbcService:
Future<Result<QueryResult>> executeQuery(
  String connectionId,
  String sql, {
  RetryOptions? retryOptions,
}) async {
  return await RetryHelper.executeWithRetry(
    () => _repository.executeQuery(connectionId, sql),
    options: retryOptions ?? RetryOptions.defaultOptions,
  );
}
```

**Exemplo de uso**:

```dart
// Retry padrão (3 tentativas, exponential backoff)
final result = await service.executeQuery(
  connId,
  sql,
);

// Retry customizado
final result = await service.executeQuery(
  connId,
  sql,
  retryOptions: RetryOptions(
    maxAttempts: 5,
    initialDelay: Duration(milliseconds: 50),
    maxDelay: Duration(seconds: 10),
  ),
);
```

**Benefícios**:
- ✅ Resiliência automática contra falhas transitórias
- ✅ Melhor experiência do usuário (não precisa manualmente retry)
- ✅ Reduz carga de suporte

**Similar**: `tokio-retry` (Rust), `aws-sdk-retry` (AWS SDK), `tenacity` (Python)

**Esforço**: 2-3 dias
**Risco**: Baixo (padrão bem estabelecido)

---

## 🟡 MÉDIA PRIORIDADE

### 4. Savepoints (Nested Transactions)

#### Status Atual
- **Problema**: Apenas transações top-level (begin/commit/rollback)
- **Impacto**: Não é possível rollback parcial em transações complexas
- **Use case**: Operações que precisam de rollback granular

#### Solução Proposta

Adicionar suporte a savepoints (nested transactions).

**Implementação Rust**:

```rust
// native/odbc_engine/src/engine/transaction.rs

pub struct Savepoint {
    name: String,
    connection_id: u32,
}

impl Savepoint {
    pub fn create(handles: SharedHandleManager, conn_id: u32, name: &str) -> Result<Self> {
        // SQL command: SAVEPOINT <name>
        let sql = format!("SAVEPOINT {}", name);
        let mut handles = handles.lock().map_err(|_| OdbcError::MutexError)?;

        let stmt = handles.create_statement(conn_id)?;
        handles.exec_direct(stmt, &sql)?;
        handles.close_statement(stmt)?;

        Ok(Self {
            name: name.to_string(),
            connection_id: conn_id,
        })
    }

    pub fn release(&self, handles: SharedHandleManager) -> Result<()> {
        // SQL command: RELEASE SAVEPOINT <name>
        let sql = format!("RELEASE SAVEPOINT {}", self.name);
        let mut handles = handles.lock().map_err(|_| OdbcError::MutexError)?;

        let stmt = handles.create_statement(self.connection_id)?;
        handles.exec_direct(stmt, &sql)?;
        handles.close_statement(stmt)?;

        Ok(())
    }

    pub fn rollback_to(&self, handles: SharedHandleManager) -> Result<()> {
        // SQL command: ROLLBACK TO SAVEPOINT <name>
        let sql = format!("ROLLBACK TO SAVEPOINT {}", self.name);
        let mut handles = handles.lock().map_err(|_| OdbcError::MutexError)?;

        let stmt = handles.create_statement(self.connection_id)?;
        handles.exec_direct(stmt, &sql)?;
        handles.close_statement(stmt)?;

        Ok(())
    }
}
```

**Implementação FFI**:

```rust
#[no_mangle]
pub extern "C" fn odbc_savepoint(
    conn_id: u32,
    name: *const c_char,
) -> u32 {
    // Retorna savepoint_id
}

#[no_mangle]
pub extern "C" fn odbc_rollback_to_savepoint(
    savepoint_id: u32,
) -> i32 {
    // 0 = sucesso, -1 = erro
}

#[no_mangle]
pub extern "C" fn odbc_release_savepoint(
    savepoint_id: u32,
) -> i32 {
    // 0 = sucesso, -1 = erro
}
```

**Implementação Dart**:

```dart
// lib/domain/entities/savepoint.dart

class Savepoint {
  final String id;
  final String name;
  final String connectionId;

  const Savepoint({
    required this.id,
    required this.name,
    required this.connectionId,
  });
}

// Em OdbcService:
Future<Result<int>> createSavepoint(
  String connectionId,
  String name,
) async {
  // ...
}

Future<Result<Unit>> rollbackToSavepoint(
  String connectionId,
  int savepointId,
) async {
  // ...
}

Future<Result<Unit>> releaseSavepoint(
  String connectionId,
  int savepointId,
) async {
  // ...
}
```

**Exemplo de uso**:

```dart
await service.beginTransaction(connId, IsolationLevel.ReadCommitted);

// Primeira operação
await service.executeQuery(connId, "INSERT INTO users ...");

// Criar savepoint
final spId = await service.createSavepoint(connId, "after_users");

// Segunda operação
await service.executeQuery(connId, "INSERT INTO orders ...");

// Erro ocorreu - rollback apenas orders
await service.rollbackToSavepoint(connId, spId);

// Commit (users inserido, orders não)
await service.commitTransaction(connId, txnId);
```

**Benefícios**:
- ✅ Rollback granular em transações complexas
- ✅ Maior flexibilidade em operações multi-step

**Similar**: JDBC `Savepoint`, SQLAlchemy `nested`

**Esforço**: 3-4 dias
**Risco**: Baixo (SQL padrão suporta)

---

### 5. Schema Reflection Expandido

#### Status Atual
- **Problema**: Apenas catalog básico (tables, columns, typeInfo)
- **Impacto**: Não é possível obter PK, FK, Indexes via API
- **Use case**: ORMs, ferramentas de schema migration

#### Solução Proposta

Expandir catalog queries para incluir Primary Keys, Foreign Keys e Indexes.

**Implementação**:

```dart
// lib/domain/entities/schema_info.dart

class PrimaryKeyInfo {
  final String tableName;
  final String columnName;
  final int position;
  final String constraintName;
}

class ForeignKeyInfo {
  final String constraintName;
  final String fromTable;
  final String fromColumn;
  final String toTable;
  final String toColumn;
  final String onUpdate;
  final String onDelete;
}

class IndexInfo {
  final String indexName;
  final String tableName;
  final String columnName;
  final bool isUnique;
  final bool isPrimaryKey;
  final int? ordinalPosition;
}

// Em OdbcService:
Future<Result<List<PrimaryKeyInfo>>> getPrimaryKeys(
  String connectionId,
  String tableName,
) async {
  // SELECT * FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS
  // WHERE TABLE_NAME = ? AND CONSTRAINT_TYPE = 'PRIMARY KEY'
  // + INFORMATION_SCHEMA.KEY_COLUMN_USAGE
}

Future<Result<List<ForeignKeyInfo>>> getForeignKeys(
  String connectionId,
  String tableName,
) async {
  // SELECT * FROM INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS
  // + INFORMATION_SCHEMA.KEY_COLUMN_USAGE
}

Future<Result<List<IndexInfo>>> getIndexes(
  String connectionId,
  String tableName,
) async {
  // SQL Server: sp_helpindex
  // PostgreSQL: pg_indexes
  // MySQL: SHOW INDEX
  // (Via plugin system)
}
```

**Benefícios**:
- ✅ Suporte a ORMs
- ✅ Schema migration tools
- ✅ Metadata completo

**Similar**: Hibernate, SQLAlchemy, Entity Framework

**Esforço**: 2-3 dias
**Risco**: Baixo (queries SQL padrão)

---

### 6. Connection String Builder (Fluent API)

#### Status Atual
- **Problema**: Connection strings são raw, propensas a erros
- **Impacto**: Difícil de construir strings complexas corretamente
- **Use case**: Melhor experiência do desenvolvedor

#### Solução Proposta

Criar fluent builder para connection strings.

**Implementação**:

```dart
// lib/infrastructure/native/connection_string_builder.dart

class ConnectionStringBuilder {
  String _driver = '';
  String _server = '';
  int? _port;
  String _database = '';
  String _username = '';
  String _password = '';
  Map<String, String> _options = {};

  ConnectionStringBuilder driver(String driver) {
    _driver = driver;
    return this;
  }

  ConnectionStringBuilder server(String server) {
    _server = server;
    return this;
  }

  ConnectionStringBuilder port(int port) {
    _port = port;
    return this;
  }

  ConnectionStringBuilder database(String database) {
    _database = database;
    return this;
  }

  ConnectionStringBuilder username(String username) {
    _username = username;
    return this;
  }

  ConnectionStringBuilder password(String password) {
    _password = password;
    return this;
  }

  ConnectionStringBuilder option(String key, String value) {
    _options[key] = value;
    return this;
  }

  String build() {
    final buffer = StringBuffer();

    // Driver={...}
    if (_driver.isNotEmpty) {
      buffer.write('Driver={$_driver};');
    }

    // Server=... ou Server=...;Port=...
    if (_server.isNotEmpty) {
      buffer.write('Server=$_server');
      if (_port != null) {
        buffer.write(',$_port');
      }
      buffer.write(';');
    }

    // Database=...
    if (_database.isNotEmpty) {
      buffer.write('Database=$_database;');
    }

    // UID=...;PWD=...
    if (_username.isNotEmpty) {
      buffer.write('UID=$_username;');
      if (_password.isNotEmpty) {
        buffer.write('PWD=$_password;');
      }
    }

    // Opções adicionais
    _options.forEach((key, value) {
      buffer.write('$key=$value;');
    });

    return buffer.toString();
  }
}

// Helpers para drivers específicos
class ConnectionString {
  static ConnectionStringBuilder sqlServer() {
    return ConnectionStringBuilder()
        .driver('ODBC Driver 17 for SQL Server');
  }

  static ConnectionStringBuilder postgres() {
    return ConnectionStringBuilder()
        .driver('PostgreSQL Unicode');
  }

  static ConnectionStringBuilder mysql() {
    return ConnectionStringBuilder()
        .driver('MySQL ODBC Driver');
  }
}
```

**Exemplo de uso**:

```dart
// Antes (raw string):
final connStr = 'Driver={ODBC Driver 17 for SQL Server};Server=localhost,1433;Database=mydb;UID=sa;PWD=pass;';

// Depois (fluent builder):
final connStr = ConnectionString
    .sqlServer()
    .server('localhost')
    .port(1433)
    .database('mydb')
    .username('sa')
    .password('pass')
    .option('TrustServerCertificate', 'yes')
    .build();

print(connStr);
// "Driver={ODBC Driver 17 for SQL Server};Server=localhost,1433;Database=mydb;UID=sa;PWD=pass;TrustServerCertificate=yes;"
```

**Benefícios**:
- ✅ Type-safe
- ✅ Auto-complete em IDEs
- ✅ Menos propenso a erros
- ✅ Documentation via code

**Similar**: JDBC `ConnectionStringBuilder`, SQLAlchemy `create_engine`

**Esforço**: 1-2 dias
**Risco**: Muito baixo

---

### 7. Backpressure em Streaming

#### Status Atual
- **Problema**: `pause/resume` existe mas não há flow control
- **Impacto**: OOM em queries muito rápidas quando consumer não acompanha
- **Use case**: Large datasets com processamento lento

#### Solução Proposta

Implementar backpressure para controlar velocidade de produção.

**Implementação**:

```dart
// lib/infrastructure/native/streaming/backpressure_stream.dart

class BackpressureStream {
  final StreamController<ParsedRowBuffer> _controller;
  final int _maxBufferSize;
  bool _isPaused = false;
  int _bufferSize = 0;

  BackpressureStream({
    required int maxBufferSize,
  }) : _maxBufferSize = maxBufferSize,
       _controller = StreamController(onCancel: cancel);

  bool get isPaused => _isPaused;

  void pause() {
    _isPaused = true;
  }

  void resume() {
    _isPaused = false;
  }

  Future<void> add(ParsedRowBuffer chunk) async {
    // Wait se paused
    while (_isPaused) {
      await Future.delayed(Duration(milliseconds: 10));
    }

    // Backpressure: wait se buffer cheio
    while (_bufferSize >= _maxBufferSize) {
      await Future.delayed(Duration(milliseconds: 10));
    }

    if (!_controller.isClosed) {
      _controller.add(chunk);
      _bufferSize += chunk.rowCount;
    }
  }

  void clearBuffer(int rowsProcessed) {
    _bufferSize -= rowsProcessed;
    if (_bufferSize < 0) _bufferSize = 0;
  }

  void cancel() {
    _controller.close();
  }

  Stream<ParsedRowBuffer> get stream => _controller.stream;
}

// Em NativeOdbcConnection.streamQuery():
Future<Stream<ParsedRowBuffer>> streamQuery(
  String connectionId,
  String sql, {
  int maxBufferSize = 10000, // máximo de 10k rows em memória
}) async {
  final stream = BackpressureStream(maxBufferSize: maxBufferSize);

  // Em background, consumir do native e adicionar ao stream
  // ... respeitando pause/resume e backpressure

  return stream.stream;
}
```

**Exemplo de uso**:

```dart
final stream = await service.streamQuery(connId, sql);

await for (final chunk in stream) {
  // Processar chunk
  for (final row in chunk.rows) {
    // Processamento demorado...
    await Future.delayed(Duration(milliseconds: 100));
  }

  // Notificar stream que processou rows
  // (permite next chunk)
  stream.clearBuffer(chunk.rowCount);
}
```

**Benefícios**:
- ✅ Previne OOM em queries grandes
- ✅ Controle de memória
- ✅ Processamento controlado

**Similar**: Reactive Streams, Akka Streams

**Esforço**: 3-4 dias
**Risco**: Médio (requer coordenação Dart/Rust)

---

## 🟢 BAIXA PRIORIDADE (Futuro)

### 8. Query Builder DSL (Type-Safe Queries)

**Status**: Não implementado
**Impacto**: SQL injection em tempo de compilação
**Similar**: Diesel (Rust), sqlx (Rust), Ktorm (Kotlin)

**Implementação futura**:

```dart
final query = Query.select(['id', 'name', 'email'])
    .from('users')
    .where('age', '>', 18)
    .where('status', '=', 'active')
    .orderBy('name')
    .limit(100);

// Gera SQL type-safe:
// SELECT id, name, email FROM users WHERE age > ? AND status = ? ORDER BY name LIMIT 100
```

**Esforço**: 2-3 semanas
**Risco**: Alto (complexo, requer macros/geração de código)

---

### 9. Reactive Streams

**Status**: Não implementado
**Impacto**: Push-based results (observabilidade)
**Similar**: R2DBC, RxDBC, ReactiveX

**Implementação futura**:

```dart
final query = Query.select('*').from('users');

// Stream reativo de updates
query.changes().listen((users) {
  print('Users updated: ${users.length}');
});
```

**Esforço**: 2-3 semanas
**Risco**: Alto (mudança arquitetural significativa)

---

### 10. Multi-Host Failover

**Status**: Não implementado
**Impacto**: Alta disponibilidade
**Similar**: MongoDB drivers, HA JDBC

**Implementação futura**:

```dart
final pool = ConnectionPool.builder()
    .primaryHost('db1.example.com')
    .replicaHosts(['db2.example.com', 'db3.example.com'])
    .failoverStrategy(FailoverStrategy.roundRobin)
    .healthCheckInterval(Duration(seconds: 30))
    .build();
```

**Esforço**: 2-3 semanas
**Risco**: Alto (complexo, muitos edge cases)

---

## 🧪 Testes e Validação

### Estratégia Geral de Testes

O projeto já possui uma estrutura de testes robusta com **3 camadas**:
1. **Unit Tests** (Dart + Rust): Testam lógica isolada, rápido, sem dependências externas
2. **Integration Tests**: Validam comunicação Dart/Rust via FFI
3. **E2E Tests**: Testam cenários reais com banco de dados (auto-skip se DB não configurado)

**Meta de Cobertura:**
- Unit Tests: > 80% coverage
- Integration Tests: 100% das APIs públicas
- E2E Tests: Todos os cenários de uso principais

---

### Definition of Done (Critérios de Aceite)

Uma melhoria SÓ é considerada **"completa"** quando:

✅ **Código implementado** segue padrões arquiteturais (Clean Architecture, Result Pattern)
✅ **Testes unitários** cobrem lógica core com > 80% coverage
✅ **Testes integração** validam comunicação Dart ↔ Rust
✅ **Testes E2E** validam cenário real com banco de dados
✅ **Documentação atualizada** (README, API docs, exemplos)
✅ **CHANGELOG.md** atualizado com novas features/breaking changes
✅ **Exemplo prático** em `example/` demonstrando uso
✅ **CI/CD passando** (quando implementado)

---

## 🔴 FASE 1: Testes de Resiliência

### 1. Async Dart API

#### Testes Necessários

**Unit Tests** (`test/infrastructure/native/async_native_odbc_connection_test.dart`):
```dart
group('AsyncNativeOdbcConnection', () {
  test('should execute operation in isolate', () async {
    // Verify: Isolate.run() is called
    // Expect: Operation completes in background thread
  });

  test('should handle isolate spawn failure', () async {
    // Simulate: Isolate.spawn throws
    // Expect: Error propagated as OdbcError
  });

  test('should not block main thread', () async {
    final stopwatch = Stopwatch()..start();
    await asyncConnection.connect(slowConnectionString);
    stopwatch.stop();

    // Main thread should respond within 50ms even if connect takes 5s
    expect(stopwatch.elapsedMilliseconds, lessThan(50));
  });
});
```

**Integration Tests** (`test/integration/async_api_integration_test.dart`):
```dart
test('should query without blocking UI', () async {
  final uiResponder = Completer<void>();

  // Simulate UI thread
  Timer(Duration(milliseconds: 100), () {
    uiResponder.complete(); // Should fire even if query is slow
  });

  // Run slow query (5+ seconds)
  await service.executeQuery(connId, 'WAITFOR DELAY "00:00:05"');

  // UI should have responded
  expect(uiResponder.future, completes);
});
```

**E2E Tests** (`native/odbc_engine/tests/e2e_async_api_test.rs`):
```rust
#[test]
#[ignore]
fn test_async_query_completes() {
    // Verify: Async query returns same result as sync
    // Compare: Binary protocol output identical
}
```

**Performance Tests:**
- Isolate overhead: < 5ms por chamada
- Memory overhead: < 1MB por isolate ativo

#### Documentação Necessária
- [ ] Atualizar `README.md` com seção "Async API"
- [ ] Adicionar exemplo `example/async_demo.dart` com UI Flutter responsiva
- [ ] Migration guide: "Migrando de Síncrono para Assíncrono"
- [ ] Documentar `AsyncNativeOdbcConnection` na API reference

#### Exemplo Prático
```dart
// example/async_demo.dart
import 'package:odbc_fast/odbc_fast.dart';

Future<void> main() async {
  final service = OdbcService();
  await service.initialize();

  // Non-blocking query - UI remains responsive
  final result = await service.executeQueryAsync(connId, '''
    SELECT * FROM large_table -- 1 million rows
  ''');

  result.fold(
    (data) => print('Got ${data.rows.length} rows'),
    (error) => print('Error: ${error.message}'),
  );
}
```

---

### 2. Connection Timeouts

#### Testes Necessários

**Unit Tests** (`test/domain/entities/connection_options_test.dart`):
```dart
group('ConnectionOptions', () {
  test('should validate timeout values', () {
    expect(() => ConnectionOptions(loginTimeout: Duration(seconds: -1)),
        throwsA(isA<ValidationError>()));
  });

  test('should use default timeouts', () {
    final opts = ConnectionOptions.defaultOptions;
    expect(opts.loginTimeout, equals(Duration(seconds: 30)));
    expect(opts.queryTimeout, equals(Duration.zero));
  });

  test('should serialize to FFI struct', () {
    final opts = ConnectionOptions(
      loginTimeout: Duration(seconds: 45),
      queryTimeout: Duration(seconds: 300),
    );
    final ffi = opts.toFfiStruct();
    expect(ffi.login_timeout_secs, equals(45));
  });
});
```

**Integration Tests** (`test/integration/timeout_integration_test.dart`):
```dart
test('should timeout on invalid host', () async {
  final result = await service.connect(
    'Driver={SQL Server};Server=invalid.host,9999;',
    options: ConnectionOptions(
      loginTimeout: Duration(seconds: 2),
    ),
  );

  expect(result.isSuccess(), isFalse);
  result.fold(
    (_) => fail('Should timeout'),
    (error) {
      expect(error, isA<ConnectionError>());
      expect(error.category, equals(ErrorCategory.transient));
    },
  );
});

test('should query timeout respects setting', () async {
  await service.connect(connStr);

  final result = await service.executeQuery(
    connId,
    'WAITFOR DELAY "00:01:00"', // 1 minute
    options: ConnectionOptions(
      queryTimeout: Duration(seconds: 2), // Timeout after 2s
    ),
  );

  expect(result.isSuccess(), isFalse);
});
```

**E2E Tests** (`native/odbc_engine/tests/e2e_timeout_test.rs`):
```rust
#[test]
#[ignore]
fn test_login_timeout_works() {
    let opts = ConnectionOptions {
        login_timeout_secs: 2,
        ..Default::default()
    };

    // Try to connect to non-routable IP (should timeout)
    let result = OdbcConnection::connect_with_timeout(
        handles,
        "Driver={SQL Server};Server=10.255.255.1;",
        &opts
    );

    assert!(result.is_err());
    assert!(matches!(result.unwrap_err(), OdbcError::Timeout { .. }));
}

#[test]
#[ignore]
fn test_query_timeout_works() {
    let conn = connect_with_default_opts();

    let opts = ConnectionOptions {
        query_timeout_secs: 2,
        ..Default::default()
    };

    // Execute query that takes 1 minute (should timeout in 2s)
    let result = conn.execute_with_timeout(
        "WAITFOR DELAY '00:01:00'",
        &opts
    );

    assert!(result.is_err());
}
```

**Edge Cases:**
- Timeout durante query em progresso (cancelamento)
- Timeout zero = infinito (nunca expira)
- Timeout negativo = ValidationError

#### Documentação Necessária
- [ ] Documentar `ConnectionOptions` na API reference
- [ ] Adicionar seção "Configurando Timeouts" no README
- [ ] Exemplo: Timeouts para diferentes cenários (LAN, WAN, cloud)
- [ ] Troubleshooting: "Timeouts comuns e como resolver"

#### Exemplo Prático
```dart
// example/timeouts_demo.dart
// Local network - fast timeouts
final localOpts = ConnectionOptions(
  loginTimeout: Duration(seconds: 5),
  queryTimeout: Duration(seconds: 30),
);

// Cloud/remote - generous timeouts
final cloudOpts = ConnectionOptions(
  loginTimeout: Duration(seconds: 30),
  queryTimeout: Duration(minutes: 5),
);

// Batch jobs - no timeout
final batchOpts = ConnectionOptions(
  loginTimeout: Duration(seconds: 30),
  queryTimeout: Duration.zero, // infinite
);
```

---

### 3. Automatic Retry com Exponential Backoff

#### Testes Necessários

**Unit Tests** (`test/infrastructure/retries/retry_helper_test.dart`):
```dart
group('RetryHelper', () {
  test('should retry on transient error', () async {
    int attempts = 0;
    final result = await RetryHelper.executeWithRetry(
      () async {
        attempts++;
        if (attempts < 3) {
          throw OdbcError.transient('Network blip');
        }
        return 'success';
      },
      options: RetryOptions(maxAttempts: 3),
    );

    expect(result, equals('success'));
    expect(attempts, equals(3));
  });

  test('should use exponential backoff', () async {
    final delays = <Duration>[];
    final result = await RetryHelper.executeWithRetry(
      () async {
        if (delays.isEmpty) throw OdbcError.transient('Error');
        return 'success';
      },
      options: RetryOptions(
        maxAttempts: 3,
        initialDelay: Duration(milliseconds: 100),
        backoffMultiplier: 2.0,
        onRetry: (delay) => delays.add(delay),
      ),
    );

    expect(delays, equals([
      Duration(milliseconds: 100),
      Duration(milliseconds: 200),
    ]));
  });

  test('should not retry non-transient errors', () async {
    int attempts = 0;
    final result = await RetryHelper.executeWithRetry(
      () async {
        attempts++;
        throw OdbcError.validation('Invalid SQL');
      },
      options: RetryOptions(maxAttempts: 3),
    ).catchError((_) => 'failed');

    expect(attempts, equals(1)); // Only 1 attempt (no retry)
  });

  test('should respect maxAttempts', () async {
    int attempts = 0;
    await expectLater(
      () => RetryHelper.executeWithRetry(
        () async {
          attempts++;
          throw OdbcError.transient('Always fails');
        },
        options: RetryOptions(maxAttempts: 3),
      ),
      throwsA(isA<TransientError>()),
    );

    expect(attempts, equals(3)); // Stopped after 3 attempts
  });
});
```

**Integration Tests** (`test/integration/retry_integration_test.dart`):
```dart
test('should retry real transient failures', () async {
  // Simulate network blip by killing connection during query
  await service.connect(connId);

  int attempts = 0;
  final result = await service.executeQuery(
    connId,
    'SELECT * FROM table',
    retryOptions: RetryOptions(
      maxAttempts: 3,
      onRetry: (delay) {
        attempts++;
        // Simulate connection recovery
        if (attempts == 1) {
          reconnectToDatabase();
        }
      },
    ),
  );

  expect(result.isSuccess(), isTrue);
  expect(attempts, greaterThan(0));
});
```

**E2E Tests** (`native/odbc_engine/tests/e2e_retry_test.rs`):
```rust
#[test]
#[ignore]
fn test_retry_with_backoff() {
    // Simulate transient failures by using a special test DB
    // that fails the first 2 attempts, succeeds on 3rd

    let attempts = Arc::new(Mutex::new(0));
    let opts = RetryOptions {
        max_attempts: 3,
        initial_delay: Duration::from_millis(100),
        backoff_multiplier: 2.0,
        ..Default::default()
    };

    let result = retry_with_opts(
        || {
            let mut a = attempts.lock().unwrap();
            *a += 1;
            if *a < 3 {
                Err(OdbcError::transient("Simulated failure"))
            } else {
                Ok("Success")
            }
        },
        &opts
    );

    assert!(result.is_ok());
    assert_eq!(*attempts.lock().unwrap(), 3);
}
```

**Edge Cases:**
- Non-transient errors não devem retry
- Max attempts = 1 = sem retry
- Delay negativo = ValidationError

#### Documentação Necessária
- [ ] Documentar `RetryOptions` e `RetryStrategy` na API reference
- [ ] Guia: "Quais Errors São Retryables?"
- [ ] Exemplo: Custom retry policy para diferentes cenários
- [ ] Métricas: Como monitorar retry attempts

#### Exemplo Prático
```dart
// example/retry_demo.dart
// Padrão (3 tentativas, exponential backoff)
final result = await service.executeQuery(
  connId,
  sql,
);

// Agressivo (10 tentativas para redes instáveis)
final result = await service.executeQuery(
  connId,
  sql,
  retryOptions: RetryOptions(
    maxAttempts: 10,
    initialDelay: Duration(milliseconds: 50),
    backoffMultiplier: 1.5,
  ),
);

// Customizado (com callback)
final result = await service.executeQuery(
  connId,
  sql,
  retryOptions: RetryOptions(
    maxAttempts: 5,
    onRetry: (delay, attempt) {
      logger.warn('Attempt $attempt failed, retrying in ${delay.inMs}ms');
    },
  ),
);
```

---

## 🟡 FASE 2: Testes de Funcionalidade

### 4. Savepoints (Nested Transactions)

#### Testes Necessários

**Unit Tests** (`test/domain/entities/savepoint_test.dart`):
```dart
test('should create savepoint with unique name', () {
  final sp = Savepoint(
    id: 'sp_1',
    name: 'after_users_insert',
    connectionId: 'conn_1',
  );

  expect(sp.name, equals('after_users_insert'));
});

test('should validate savepoint state', () {
  final sp = Savepoint.active('conn_1', 'sp1');

  sp.release();
  expect(sp.isReleased, isTrue);

  expect(() => sp.rollback(), throwsA(isA<StateError>()));
});
```

**Integration Tests** (`test/integration/savepoint_integration_test.dart`):
```dart
test('should rollback to savepoint', () async {
  await service.beginTransaction(connId, IsolationLevel.readCommitted);

  // Insert users
  await service.executeQuery(connId, 'INSERT INTO users ...');

  // Create savepoint
  final spId = await service.createSavepoint(connId, 'after_users');

  // Insert orders (will be rolled back)
  await service.executeQuery(connId, 'INSERT INTO orders ...');

  // Rollback to savepoint
  await service.rollbackToSavepoint(connId, spId);

  // Users exist, orders don't
  final users = await service.executeQuery(connId, 'SELECT * FROM users');
  final orders = await service.executeQuery(connId, 'SELECT * FROM orders');

  expect(users.rows.length, greaterThan(0));
  expect(orders.rows.length, equals(0));

  await service.commitTransaction(connId);
});

test('should release savepoint', () async {
  await service.beginTransaction(connId);

  await service.executeQuery(connId, 'INSERT INTO users ...');
  final spId = await service.createSavepoint(connId, 'sp1');

  await service.executeQuery(connId, 'INSERT INTO orders ...');
  await service.releaseSavepoint(connId, spId);

  // Both users and orders committed
  await service.commitTransaction(connId);

  final users = await service.executeQuery(connId, 'SELECT * FROM users');
  final orders = await service.executeQuery(connId, 'SELECT * FROM orders');

  expect(users.rows.length, greaterThan(0));
  expect(orders.rows.length, greaterThan(0));
});

test('should handle nested savepoints', () async {
  await service.beginTransaction(connId);

  await service.executeQuery(connId, 'INSERT INTO table1 ...');
  final sp1 = await service.createSavepoint(connId, 'sp1');

  await service.executeQuery(connId, 'INSERT INTO table2 ...');
  final sp2 = await service.createSavepoint(connId, 'sp2');

  await service.executeQuery(connId, 'INSERT INTO table3 ...');

  // Rollback to sp2 (table3 removed, table2 kept)
  await service.rollbackToSavepoint(connId, sp2);

  // Rollback to sp1 (table2 also removed)
  await service.rollbackToSavepoint(connId, sp1);

  await service.commitTransaction(connId);

  // Only table1 exists
});
```

**E2E Tests** (`native/odbc_engine/tests/e2e_savepoint_test.rs`):
```rust
#[test]
#[ignore]
fn test_savepoint_rollback() {
    let conn = connect();
    conn.begin_transaction().unwrap();

    conn.exec("INSERT INTO users VALUES (1, 'Alice')").unwrap();
    conn.savepoint("after_users").unwrap();

    conn.exec("INSERT INTO orders VALUES (1, 100)").unwrap();

    conn.rollback_to_savepoint("after_users").unwrap();
    conn.commit().unwrap();

    // Users exist, orders don't
    let user_count: i64 = conn.query_one("SELECT COUNT(*) FROM users").unwrap();
    let order_count: i64 = conn.query_one("SELECT COUNT(*) FROM orders").unwrap();

    assert_eq!(user_count, 1);
    assert_eq!(order_count, 0);
}
```

#### Documentação Necessária
- [ ] Documentar `Savepoint` API na referência
- [ ] Guia: "Quando Usar Savepoints vs Transações Separadas"
- [ ] Exemplo: Transação complexa com múltiplos savepoints
- [ ] Limitações: Suporte por database (SQL Server ✅, PostgreSQL ✅, MySQL ✅)

#### Exemplo Prático
```dart
// example/savepoints_demo.dart
await service.beginTransaction(connId);

// Step 1: Insert user
await service.executeQuery(connId, '''
  INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com')
''');

// Create savepoint
final sp = await service.createSavepoint(connId, 'after_user');

// Step 2: Insert orders (may fail if inventory insufficient)
try {
  await service.executeQuery(connId, '''
    INSERT INTO orders (user_id, total) VALUES (1, 100)
  ''');

  await service.commitTransaction(connId);
} catch (e) {
  // Rollback just the orders, keep the user
  await service.rollbackToSavepoint(connId, sp);

  // User remains in database for retry later
  await service.commitTransaction(connId);
}
```

---

### 5. Schema Reflection Expandido

#### Testes Necessários

**Unit Tests** (`test/domain/entities/schema_info_test.dart`):
```dart
test('should parse primary key info', () {
  final pk = PrimaryKeyInfo(
    tableName: 'users',
    columnName: 'id',
    position: 1,
    constraintName: 'PK_users',
  );

  expect(pk.tableName, equals('users'));
  expect(pk.isPrimary, isTrue);
});

test('should parse foreign key info', () {
  final fk = ForeignKeyInfo(
    constraintName: 'FK_orders_users',
    fromTable: 'orders',
    fromColumn: 'user_id',
    toTable: 'users',
    toColumn: 'id',
    onUpdate: 'CASCADE',
    onDelete: 'RESTRICT',
  );

  expect(fk.fromTable, equals('orders'));
  expect(fk.toTable, equals('users'));
  expect(fk.cascadeDelete, isFalse);
});
```

**Integration Tests** (`test/integration/schema_reflection_integration_test.dart`):
```dart
test('should get primary keys', () async {
  final pks = await service.getPrimaryKeys(connId, 'users');

  expect(pks.length, greaterThan(0));
  expect(pks.first.columnName, equals('id'));
  expect(pks.first.tableName, equals('users'));
});

test('should get foreign keys', () async {
  final fks = await service.getForeignKeys(connId, 'orders');

  final userFk = fks.firstWhere(
    (fk) => fk.toTable == 'users',
  );

  expect(userFk.fromColumn, equals('user_id'));
  expect(userFk.onDelete, equals('RESTRICT'));
});

test('should get indexes', () async {
  final indexes = await service.getIndexes(connId, 'users');

  final pkIndex = indexes.firstWhere(
    (idx) => idx.isPrimaryKey,
  );

  expect(pkIndex.isUnique, isTrue);
  expect(pkIndex.columnName, equals('id'));
});

test('should handle multi-column indexes', () async {
  final indexes = await service.getIndexes(connId, 'orders');

  final compositeIndex = indexes.where(
    (idx) => idx.indexName == 'idx_orders_date_status',
  );

  expect(compositeIndex.length, greaterThan(1));
  expect(compositeIndex.first.ordinalPosition, equals(1));
});
```

**E2E Tests** (`native/odbc_engine/tests/e2e_schema_test.rs`):
```rust
#[test]
#[ignore]
fn test_get_primary_keys() {
    let conn = connect();

    // Create test table
    conn.exec(r#"
        CREATE TABLE test_pk (
            id INT PRIMARY KEY,
            name VARCHAR(50)
        )
    "#).unwrap();

    let pks = conn.get_primary_keys("test_pk").unwrap();

    assert_eq!(pks.len(), 1);
    assert_eq!(pks[0].column_name, "id");
    assert_eq!(pks[0].position, 1);
}

#[test]
#[ignore]
fn test_get_foreign_keys() {
    let conn = connect();

    // Create tables with FK
    conn.exec(r#"
        CREATE TABLE users (id INT PRIMARY KEY)
        CREATE TABLE orders (
            id INT PRIMARY KEY,
            user_id INT,
            FOREIGN KEY (user_id) REFERENCES users(id)
        )
    "#).unwrap();

    let fks = conn.get_foreign_keys("orders").unwrap();

    assert_eq!(fks.len(), 1);
    assert_eq!(fks[0].from_column, "user_id");
    assert_eq!(fks[0].to_table, "users");
    assert_eq!(fks[0].to_column, "id");
}
```

#### Documentação Necessária
- [ ] Documentar `PrimaryKeyInfo`, `ForeignKeyInfo`, `IndexInfo`
- [ ] Guia: "Construindo ORMs com Schema Reflection"
- [ ] Matriz de compatibilidade: Quais databases suportam o quê
- [ ] Performance tips: Caching de schema metadata

#### Exemplo Prático
```dart
// example/schema_demo.dart
// Gerar código de ORM automaticamente
final pks = await service.getPrimaryKeys(connId, 'users');
final fks = await service.getForeignKeys(connId, 'orders');
final indexes = await service.getIndexes(connId, 'products');

// Gerar classe Dart com base no schema
final code = generateOrmClass(
  table: 'users',
  primaryKey: pks.first,
  foreignKeys: fks,
  indexes: indexes,
);

print(code);
// class User {
//   @PrimaryKey()
//   final int id;
//
//   @ForeignKey(references: 'profiles')
//   final String email;
// ...
// }
```

---

### 6. Connection String Builder (Fluent API)

#### Testes Necessários

**Unit Tests** (`test/infrastructure/native/connection_string_builder_test.dart`):
```dart
test('should build SQL Server connection string', () {
  final connStr = ConnectionString
      .sqlServer()
      .server('localhost')
      .port(1433)
      .database('mydb')
      .username('sa')
      .password('pass')
      .build();

  expect(
    connStr,
    equals(
      'Driver={ODBC Driver 17 for SQL Server};'
      'Server=localhost,1433;'
      'Database=mydb;'
      'UID=sa;'
      'PWD=pass;',
    ),
  );
});

test('should build PostgreSQL connection string', () {
  final connStr = ConnectionString
      .postgres()
      .server('db.example.com')
      .database('production')
      .username('app_user')
      .build();

  expect(
    connStr,
    contains('Driver={PostgreSQL Unicode}'),
  );
  expect(connStr, contains('Server=db.example.com'));
});

test('should handle custom options', () {
  final connStr = ConnectionString
      .sqlServer()
      .server('localhost')
      .option('TrustServerCertificate', 'yes')
      .option('Encrypt', 'false')
      .build();

  expect(connStr, contains('TrustServerCertificate=yes'));
  expect(connStr, contains('Encrypt=false'));
});

test('should validate required fields', () {
  expect(
    () => ConnectionString.sqlServer().build(),
    throwsA(isA<ValidationError>()),
  );
});

test('should escape special characters', () {
  final connStr = ConnectionString
      .sqlServer()
      .server('localhost')
      .password('p@ss;w"rd')
      .build();

  expect(connStr, contains('PWD=p@ss;w"rd'));
});
```

**Integration Tests** (testar com driver real):
```dart
test('should connect using built connection string', () async {
  final connStr = ConnectionString
      .sqlServer()
      .server('localhost')
      .port(1433)
      .database('testdb')
      .username('sa')
      .password('TestPass123!')
      .option('TrustServerCertificate', 'yes')
      .build();

  final result = await service.connect(connStr);

  expect(result.isSuccess(), isTrue);
});
```

#### Documentação Necessária
- [ ] Documentar `ConnectionStringBuilder` na API reference
- [ ] Referência de options por database (SQL Server, PostgreSQL, MySQL)
- [ ] Guia: "Connection Strings Best Practices"
- [ ] Exemplos para todos os drivers suportados

#### Exemplo Prático
```dart
// example/connection_string_demo.dart
// SQL Server
final sqlServer = ConnectionString
    .sqlServer()
    .server('localhost')
    .port(1433)
    .database('production')
    .username('app_user')
    .password('SecurePass123!')
    .option('TrustServerCertificate', 'yes')
    .option('Encrypt', 'false')
    .build();

// PostgreSQL
final postgres = ConnectionString
    .postgres()
    .server('db.example.com')
    .port(5432)
    .database('myapp')
    .username('dbuser')
    .password('dbpass')
    .option('sslmode', 'require')
    .build();

// MySQL
final mysql = ConnectionString
    .mysql()
    .server('localhost')
    .database('wordpress')
    .username('wp_user')
    .password('wp_pass')
    .option('charset', 'utf8mb4')
    .build();
```

---

### 7. Backpressure em Streaming

#### Testes Necessários

**Unit Tests** (`test/infrastructure/streaming/backpressure_stream_test.dart`):
```dart
test('should pause when buffer full', () async {
  final stream = BackpressureStream(maxBufferSize: 100);

  // Producer adds 200 rows rapidly
  final producer = Future(() async {
    for (var i = 0; i < 200; i++) {
      await stream.add(createRowBuffer(rows: 1));
    }
  });

  // Consumer processes slowly
  final consumer = Future(() async {
    await for (final chunk in stream.stream) {
      await Future.delayed(Duration(milliseconds: 10));
      stream.clearBuffer(chunk.rowCount);
    }
  });

  await producer;
  await consumer;

  // Buffer should never exceed 100 rows
  expect(stream.maxBufferSize, equals(100));
});

test('should respect pause/resume', () async {
  final stream = BackpressureStream(maxBufferSize: 1000);

  stream.pause();

  var addedRows = 0;
  // Add while paused
  final producer = Future(() async {
    for (var i = 0; i < 100; i++) {
      await stream.add(createRowBuffer(rows: 10));
      addedRows += 10;
    }
  });

  // Wait a bit
  await Future.delayed(Duration(milliseconds: 100));

  // Should still be paused
  expect(stream.isPaused, isTrue);

  // Resume
  stream.resume();

  await producer;
  expect(addedRows, equals(1000));
});

test('should prevent OOM', () async {
  final stream = BackpressureStream(maxBufferSize: 1000);

  // Simulate query returning 1M rows
  final producer = Future(() async {
    for (var i = 0; i < 1000000; i++) {
      await stream.add(createRowBuffer(rows: 1));
    }
  });

  // Consumer processes slowly
  final consumer = Future(() async {
    var processed = 0;
    await for (final chunk in stream.stream) {
      processed += chunk.rowCount;
      await Future.delayed(Duration(milliseconds: 1));
      stream.clearBuffer(chunk.rowCount);

      if (processed >= 100) break; // Only process 100 rows
    }
  });

  await producer.timeout(Duration(seconds: 5));
  await consumer;

  // Memory should stay bounded
  expect(stream.bufferSize, lessThan(1000));
});
```

**Integration Tests** (`test/integration/backpressure_integration_test.dart`):
```dart
test('should handle slow consumer', () async {
  final stream = await service.streamQuery(
    connId,
    'SELECT * FROM large_table', -- 1M rows
    maxBufferSize: 1000,
  );

  var processed = 0;
  final stopwatch = Stopwatch()..start();

  await for (final chunk in stream) {
    // Simulate slow processing
    await Future.delayed(Duration(milliseconds: 100));

    processed += chunk.rowCount;

    if (processed >= 100) break; // Stop after 100 rows
  }

  stopwatch.stop();

  // Should process without OOM
  expect(processed, equals(100));
  expect(stopwatch.elapsedMilliseconds, lessThan(20000)); // < 20s
});
```

**E2E Tests** (`native/odbc_engine/tests/e2e_backpressure_test.rs`):
```rust
#[test]
#[ignore]
fn test_backpressure_limits_memory() {
    let conn = connect();

    // Create table with 1M rows
    conn.exec("CREATE TABLE large_table (id INT, data VARCHAR(100))").unwrap();
    for i in 0..1_000_000 {
        conn.exec(&format!("INSERT INTO large_table VALUES ({}, 'data{}')", i, i)).unwrap();
    }

    // Stream with backpressure (max 10K rows in buffer)
    let stream = conn.stream_query_with_backpressure(
        "SELECT * FROM large_table",
        10_000
    );

    let mut processed = 0;
    let mut max_buffer_size = 0;

    for chunk in stream {
        let buffer_size = chunk.buffer_size();
        if buffer_size > max_buffer_size {
            max_buffer_size = buffer_size;
        }

        // Slow processing
        std::thread::sleep(Duration::from_millis(10));
        processed += chunk.row_count();

        if processed >= 100 {
            break;
        }
    }

    // Buffer should never exceed 10K rows
    assert!(max_buffer_size <= 10_000);
    assert_eq!(processed, 100);
}
```

**Performance Tests:**
- Memory usage: Deve permanecer constante mesmo com queries grandes
- Buffer size: Nunca exceder `maxBufferSize`
- Latency: < 10ms overhead por chunk

#### Documentação Necessária
- [ ] Documentar `BackpressureStream` e `maxBufferSize`
- [ ] Guia: "Prevenindo OOM em Queries Grandes"
- [ ] Exemplo: Processamento de 1M rows sem OOM
- [ ] Métricas: Como monitorar buffer usage

#### Exemplo Prático
```dart
// example/backpressure_demo.dart
final stream = await service.streamQuery(
  connId,
  'SELECT * FROM huge_table', -- 10M rows
  maxBufferSize: 10000, // Máximo 10K rows em memória
);

await for (final chunk in stream) {
  // Processar chunk
  for (final row in chunk.rows) {
    // Processamento demorado
    await heavyComputation(row);
  }

  // Notificar stream que processou rows (libera buffer)
  stream.clearBuffer(chunk.rowCount);

  // Se não chamar clearBuffer, stream pause quando buffer encher
}
```

---

## 🟢 FASE 3: Testes Avançados (Futuro)

**Nota:** Fase 3 requer arquitetura significativamente mais complexa. Testes a serem definidos quando do início da implementação.

### 8. Query Builder DSL
- [ ] Type-safe SQL generation tests
- [ ] AST validation tests
- [ ] SQL injection prevention tests
- [ ] Cross-database SQL compatibility tests

### 9. Reactive Streams
- [ ] Push-based result propagation tests
- [ ] Stream subscription lifecycle tests
- [ ] Backpressure reactive tests
- [ ] Cancellation propagation tests

### 10. Multi-Host Failover
- [ ] Failover logic tests
- [ ] Health check tests
- [ ] Round-robin distribution tests
- [ ] Split-brain prevention tests

---

## 📦 Checklist de Documentação (Para Cada Melhoria)

### Obrigatório
- [ ] **API Documentation**: Comentários DartDoc em todas as APIs públicas
- [ ] **README Section**: Seção nova ou atualizada no README principal
- [ ] **CHANGELOG.md**: Entrada descrevendo a nova funcionalidade
- [ ] **Example Code**: Exemplo prático em `example/`

### Recomendado
- [ ] **Migration Guide**: Se há breaking changes, guia de migração
- [ ] **Troubleshooting**: Seção de problemas comuns e soluções
- [ ] **Performance Guide**: Dicas de performance da nova feature
- [ ] **Architecture Decision Record (ADR)**: Se é mudança arquitetural significativa

---

## 🚀 CI/CD Pipeline (Proposta Futura)

### GitHub Actions Workflow: `.github/workflows/test.yml`

```yaml
name: Test

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main, develop]

jobs:
  test-dart:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
      - run: dart pub get
      - run: dart test --coverage=coverage
      - uses: codecov/codecov-action@v3
        with:
          files: coverage/lcov.info

  test-rust-unit:
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest]
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo test --lib --all-features
        working-directory: native/odbc_engine

  test-rust-e2e:
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest]
        db: [sqlserver, postgresql]
    if: github.event_name == 'push' || github.event.pull_request.head.repo.full_name == github.repository
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - name: Start Database
        run: docker-compose up -d ${{ matrix.db }}
      - run: cargo test --test e2e_* -- --ignored
        working-directory: native/odbc_engine
        env:
          ODBC_TEST_DSN: ${{ secrets.ODBC_TEST_DSN }}
```

---

## 📈 Matriz de Rastreabilidade

| Melhoria | Unit Tests | Integration Tests | E2E Tests | Performance Tests | Doc | Example | CHANGELOG | Status |
|----------|-----------|------------------|-----------|-------------------|-----|---------|-----------|--------|
| Async API | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 🟢 Completo (v0.2.0) |
| Savepoints | ✅ | ✅ | ✅ | ⬜ | ✅ | ✅ | ✅ | 🟢 Completo (v0.3.0) |
| Automatic Retry | ✅ | ✅ | ⬜ | ⬜ | ✅ | ✅ | ✅ | 🟢 Completo (v0.3.0) |
| Connection Timeouts | ✅ | ✅ | ⬜ | ⬜ | ✅ | ⬜ | ✅ | 🟢 Completo (v0.3.0) |
| Connection String Builder | ✅ | ⬜ | ⬜ | ⬜ | ✅ | ✅ | ✅ | 🟢 Completo (v0.3.0) |
| Backpressure | ⬜ | ✅ | ⬜ | ⬜ | ✅ | ⬜ | ✅ | 🟢 Completo (v0.3.0) |
| Schema Reflection | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ✅ | 🟡 Parcial (entities v0.3.0) |
| Query Builder DSL | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | 🟢 Futuro |
| Reactive Streams | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | 🟢 Futuro |
| Multi-Host Failover | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | 🟢 Futuro |

**Legenda:**
- ✅ Completo
- ⬜ Não iniciado
- 🔴 Alta prioridade
- 🟡 Média prioridade
- 🟢 Baixa prioridade/futuro

---

## 📊 Cronograma de Implementação

### Fase 1: Resiliência (Semanas 1-2)
- [x] Async API (worker isolate, v0.2.0)
- [ ] Connection Timeouts
- [ ] Automatic Retry com Exponential Backoff

**Impacto**: Melhor usabilidade e confiabilidade

### Fase 2: Funcionalidade (Semanas 3-4)
- [ ] Savepoints (Nested Transactions)
- [ ] Schema Reflection Expandido (PK, FK, Indexes)
- [ ] Connection String Builder
- [ ] Backpressure em Streaming

**Impacto**: Mais features e melhor DX

### Fase 3: Avançado (Mês 2+)
- [ ] Query Builder DSL
- [ ] Reactive Streams
- [ ] Multi-Host Failover

**Impacto**: Diferenciação competitiva

---

## 🎯 Priorização por Valor

| Melhoria | Valor | Esforço | ROI | Ordem |
|----------|-------|---------|-----|-------|
| Async API | Alta | 2-3 dias | Alto | 1 |
| Connection Timeouts | Alta | 3-4 dias | Alto | 2 |
| Automatic Retry | Alta | 2-3 dias | Alto | 3 |
| Savepoints | Média | 3-4 dias | Médio | 4 |
| Schema Reflection | Média | 2-3 dias | Médio | 5 |
| Connection String Builder | Média | 1-2 dias | Alto | 6 |
| Backpressure | Média | 3-4 dias | Médio | 7 |
| Query Builder | Baixa | 2-3 sem | Baixo | 8 |
| Reactive Streams | Baixa | 2-3 sem | Baixo | 9 |
| Multi-Host Failover | Baixa | 2-3 sem | Médio | 10 |

---

## 📚 Referências

### Projetos Similares Estudados
- **sqflite** - SQLite para Flutter (async pattern)
- **sqlx** - Rust SQL com compile-time checks
- **postgres** - Dart PostgreSQL package
- **Diesel** - Rust ORM (query builder)
- **node-postgres** - Node.js PostgreSQL driver
- **pymysql** - Python MySQL driver

### Padrões e Melhores Práticas
- Retry with Exponential Backoff: `tokio-retry`, `aws-sdk-retry`
- Connection Pooling: `r2d2`, `deadpool`, `HikariCP`
- Async Patterns: `Isolate.run()`, `async/await`
- Error Handling: Result types, structured errors

### Documentação
- ODBC API Reference: https://docs.microsoft.com/en-us/sql/odbc/reference/syntax/odbc-api-reference
- Rust FFI: https://doc.rust-lang.org/std/ffi/
- Dart Native Assets: https://dart.dev/guides/libraries/native-objects

---

## ✅ Conclusão

O projeto **ODBC Fast** já é **production-ready** com qualidade excepcional. As melhorias propostas elevariam o projeto de "excelente" para "excepcional", mas **não são impedimentos** para uso em produção hoje.

**Recomendação**: Implementar Fase 1 (Async API, Timeouts, Retry) para máximo impacto em mínimo tempo.

**Próximos passos imediatos**:
1. Criar issues no GitHub para cada melhoria
2. Priorizar Fase 1
3. Começar com Async API (maior benefício para usuários Flutter)

---

**Documento mantido por**: ODBC Fast Team
**Última atualização**: 2026-01-26
**Versão**: 1.0
