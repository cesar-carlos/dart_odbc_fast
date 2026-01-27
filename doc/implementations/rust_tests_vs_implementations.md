# Verificação: Testes Rust vs Implementações (doc/implementations)

**Data**: 2026-01-27  
**Objetivo**: Conferir se o código Rust possui testes para as implementações descritas em `doc/implementations`.

---

## 1. Implementações da pasta doc/implementations

Os documentos em `doc/implementations` descrevem:

| Documento | Conteúdo |
|-----------|----------|
| **README.md** | Roadmap: Async API, Connection Timeouts, Automatic Retry, Savepoints, Backpressure, etc. |
| **roadmap_improvements.md** | Especificação detalhada de cada melhoria + testes esperados (Dart e Rust) |
| **test_analysis_report.md** | Análise dos testes Rust (FFI + E2E async) |
| **dart_tests_status.md** | Status dos testes Dart (timeouts em testes async) |

---

## 2. DESCOBERTA: Features Implementadas mas Não Expostas

**Análise profunda do código Rust revelou**: várias features do roadmap JÁ ESTÃO implementadas em Rust, mas não estão expostas via FFI ou documentadas.

### 2.1 Matriz de Status Real vs Roadmap

| Feature | Rust Implementation | FFI Exposure | Dart Usage | Tests | Status Real |
|---------|---------------------|--------------|------------|-------|-------------|
| **1. Async API** | ✅ Completo | ✅ Completo | ✅ Completo | ✅ Sim | **✅ IMPLEMENTADO E EXPOSTO** |
| **2. Connection Timeouts** | ⚠️ Parcial | ⚠️ Parcial | ❌ Não | ⚠️ Parcial | **⚠️ PARCIAL (só query timeout)** |
| **3. Savepoints** | ✅ Completo | ❌ Não | ❌ Não | ⚠️ Rust only | **⚠️ IMPLEMENTADO MAS NÃO EXPOSTO** |
| **4. Schema Reflection (PK/FK/Idx)** | ⚠️ Básico | ⚠️ Básico | ⚠️ Básico | ⚠️ Parcial | **⚠️ PARCIAL (só tables/columns)** |
| **5. Automatic Retry** | ⚠️ Parcial | ❌ Não | ⚠️ Parcial | ⚠️ Parcial | **⚠️ PARCIAL (só is_retryable)** |
| **6. Backpressure** | ⚠️ Parcial | ✅ Sim | ⚠️ Parcial | ❌ Não | **⚠️ PARCIAL (pause/resume existe)** |
| **7. Connection String Builder** | ⚠️ Helper | ❌ N/A | ❌ Não | ❌ Não | **❌ NÃO IMPLEMENTADO** |

---

## 3. Detalhamento por Feature

### 3.1 ✅ Async API — **IMPLEMENTADO COMPLETO**

**Rust**: Worker isolate pattern, message protocol  
**FFI**: Todas as funções sync usadas pelo worker  
**Dart**: `AsyncNativeOdbcConnection`, `worker_isolate.dart`, `message_protocol.dart`  
**Testes Rust**: `e2e_async_api_test.rs` (4 testes), 73 testes FFI  
**Testes Dart**: `async_native_odbc_connection_test.dart`, `async_api_integration_test.dart`

**Veredicto**: ✅ Completo e testado.

---

### 3.2 ⚠️ Connection Timeouts — **PARCIALMENTE IMPLEMENTADO**

#### O que JÁ existe:

**Rust**:
- `execute_query_with_params_and_timeout()` em `engine/query.rs:23-29`
- Pool com `connection_timeout(Duration::from_secs(30))` hardcoded (`pool/mod.rs:63`)

**FFI**:
- `odbc_prepare()` aceita `timeout_ms` (`ffi/mod.rs:1185-1214`)

**Testes**:
- `ffi/mod.rs:3147` — teste de prepare timeout

#### O que FALTA:

❌ **Connection/login timeout configurável**
- Sem `odbc_connect_with_timeout()` no FFI
- Sem `ConnectionOptions` no Dart
- Timeout de pool é hardcoded (30s), não configurável

❌ **Query timeout genérico**
- Só funciona via prepared statements
- `executeQuery()` direto não tem timeout

❌ **Testes E2E**
- Sem `e2e_timeout_test.rs`
- Sem testes Dart para connection/login timeout

**Para completar**:
1. Adicionar `odbc_connect_with_timeout(conn_str, timeout_ms)` no FFI
2. Criar `ConnectionOptions` no Dart
3. Criar `e2e_timeout_test.rs`
4. Documentar

---

### 3.3 ⚠️ **Savepoints — IMPLEMENTADO MAS NÃO EXPOSTO**

#### O que JÁ existe:

**Rust** (`engine/transaction.rs:202-226`):
```rust
pub struct Savepoint<'t> {
    transaction: &'t Transaction,
    name: String,
}

impl<'t> Savepoint<'t> {
    pub fn create(transaction: &'t Transaction, name: &str) -> Result<Self> { }
    pub fn rollback_to(&self) -> Result<()> { }
    pub fn release(self) -> Result<()> { }
}
```

**Testes Rust**:
- `transaction_test.rs:175-227` (teste ignored)

#### O que FALTA:

❌ **Sem exposição FFI**
- Sem `odbc_savepoint_create(conn_id, tx_id, name)`
- Sem `odbc_savepoint_rollback_to(conn_id, tx_id, name)`
- Sem `odbc_savepoint_release(conn_id, tx_id, name)`

❌ **Sem wrapper Dart**
- Sem `createSavepoint()` em `OdbcService`
- Sem testes Dart

❌ **Teste ignored**
- `transaction_test.rs` tem teste de savepoint mas está `#[ignore]`

**Para completar**:
1. Criar 3 funções FFI (`odbc_savepoint_*`)
2. Adicionar métodos no Dart (`createSavepoint`, `rollbackToSavepoint`, `releaseSavepoint`)
3. Criar `e2e_savepoint_test.rs` e testes Dart
4. Remover `#[ignore]` do teste existente
5. Documentar

**Prioridade**: **ALTA** — implementação Rust pronta, precisa só FFI + Dart wrapper (1-2 dias).

---

### 3.4 ⚠️ Schema Reflection — **PARCIAL (só catalog básico)**

#### O que JÁ existe:

**Rust** (`engine/catalog.rs`):
- `list_tables()`, `list_columns()`, `get_type_info()`

**FFI**:
- `odbc_catalog_tables`, `odbc_catalog_columns`, `odbc_catalog_type_info`

**Dart**:
- `catalogTables()`, `catalogColumns()`, `typeInfo()`

**Testes**:
- E2E catalog em `e2e_catalog_test.rs`

#### O que FALTA (expansão):

❌ **Primary Keys**
- Sem `list_primary_keys()` no Rust
- Sem `odbc_catalog_primary_keys()` no FFI
- Sem `getPrimaryKeys()` no Dart

❌ **Foreign Keys**
- Sem `list_foreign_keys()`

❌ **Indexes**
- Sem `list_indexes()`

**Para completar**:
1. Implementar `list_primary_keys()`, `list_foreign_keys()`, `list_indexes()` no Rust
2. Expor via FFI
3. Wrapper Dart
4. Criar `e2e_schema_test.rs`
5. Testes Dart

---

### 3.5 ⚠️ Automatic Retry — **PARCIAL (só categorização)**

#### O que JÁ existe:

**Rust** (`error/mod.rs:112-120`):
```rust
pub fn is_retryable(&self) -> bool {
    matches!(
        self,
        OdbcError::ConnectionLost(_)
            | OdbcError::Timeout
            | OdbcError::PoolError(_)
    )
}
```

**Dart** (`odbc_error.dart:53`):
```dart
bool get isRetryable => /* ... */;
```

**Testes**:
- `error/mod.rs:347-376` — testes de `is_retryable()`

#### O que FALTA:

❌ **Retry execution logic**
- Sem `RetryHelper` no Rust
- Sem exponential backoff implementation

❌ **FFI exposure**
- Sem funções FFI de retry

❌ **Dart helper**
- Sem `RetryHelper` class
- Sem `RetryOptions`

**Para completar**:
1. Criar `RetryHelper` no Dart (não precisa FFI — pode ser só wrapper)
2. Implementar exponential backoff
3. Testes de retry execution
4. Documentar

**Nota**: Pode ser implementado **só no Dart** (não precisa Rust) já que `is_retryable()` existe.

---

### 3.6 ⚠️ Backpressure — **PARCIAL (pause/resume existe)**

#### O que JÁ existe:

**Dart** (`streaming_query.dart:17-18`):
```dart
/// Initializes the stream controller with pause/resume handlers.
```

**FFI**: Streaming functions existem

#### O que FALTA:

❌ **Buffer size control**
- Sem `maxBufferSize` parameter
- Sem `clearBuffer()` method
- Sem buffer management logic

**Para completar**:
1. Adicionar `maxBufferSize` em `StreamingQuery`
2. Implementar buffer management (pause quando cheio)
3. Testes de backpressure
4. Documentar

---

### 3.7 ❌ Connection String Builder — **NÃO IMPLEMENTADO**

**Existe**: Helper em testes (`helpers/env.rs:13-30`) — uso interno  
**Falta**: API pública com builder fluente

**Para completar**: Criar `ConnectionStringBuilder` class no Dart (feature pura Dart).

---

## 4. Resumo

### Implementação vs Roadmap

| Status Roadmap | Status Real | Features |
|----------------|-------------|----------|
| 🟢 Completo (v0.2.0) | ✅ Completo | Async API |
| 🔴 Não iniciado | ⚠️ **Parcial** | Connection Timeouts (query timeout existe) |
| 🔴 Não iniciado | ⚠️ **Parcial** | Automatic Retry (categorização existe) |
| 🟡 Não iniciado | ⚠️ **Implementado mas não exposto** | **Savepoints** (código Rust pronto) |
| 🟡 Não iniciado | ⚠️ **Parcial** | Schema Reflection (catalog básico existe) |
| 🟡 Não iniciado | ⚠️ **Parcial** | Backpressure (pause/resume existe) |
| 🟡 Não iniciado | ❌ Não | Connection String Builder |

### Priorização Recomendada

**Quick wins** (features quase prontas, esforço < 2 dias):

1. **Savepoints** — Rust 100% pronto, precisa só FFI + Dart wrapper
2. **Automatic Retry** — `is_retryable()` existe, criar `RetryHelper` só no Dart
3. **Connection String Builder** — feature pura Dart, simples

**Médio esforço** (2-4 dias):

4. **Connection Timeouts** — completar connection/login timeout
5. **Backpressure** — adicionar buffer size control
6. **Schema Reflection** — PK/FK/Indexes via FFI

---

## 5. Conclusão

### Pergunta: "Ficou para trás"?

**Resposta**: **Sim e Não**

**Sim, ficou documentação/exposição para trás**:
- Savepoints **já funcionam em Rust** mas não são acessíveis do Dart
- Query timeout **existe** mas não é documentado
- Catalog **está exposto** mas o roadmap marca como "não iniciado" (confusão com PK/FK/Indexes)

**Não, não há "implementação completa escondida"**:
- Connection/login timeout: só pool hardcoded
- Retry execution: só categorização de erro
- PK/FK/Indexes: não implementado
- Buffer size control: não implementado
- Connection String Builder: helper de teste, não API pública

### Recomendação

**Atualizar o roadmap** para refletir status real:

| Feature | Status atual no roadmap | Status real | Ajuste necessário |
|---------|-------------------------|-------------|-------------------|
| Async API | 🟢 Completo | ✅ Completo | OK |
| Connection Timeouts | 🔴 Não iniciado | ⚠️ Parcial (query timeout) | Atualizar para "Parcial" |
| Automatic Retry | 🔴 Não iniciado | ⚠️ Parcial (categorização) | Atualizar para "Parcial" |
| Savepoints | 🟡 Não iniciado | ⚠️ **Implementado, não exposto** | Atualizar para "Needs FFI" |
| Schema Reflection | 🟡 Não iniciado | ⚠️ Parcial (tables/columns) | Atualizar para "Needs PK/FK/Indexes" |
| Backpressure | 🟡 Não iniciado | ⚠️ Parcial (pause/resume) | Atualizar para "Needs buffer control" |

**Próximos passos**:
1. Expor **Savepoints** via FFI (esforço: 1-2 dias, ROI: alto)
2. Implementar `RetryHelper` no Dart (esforço: 1 dia, ROI: alto)
3. Completar Connection Timeouts (connection/login) (esforço: 2-3 dias)
4. Adicionar PK/FK/Indexes (esforço: 3-4 dias)

---

## 6. Arquivos de Teste Rust E2E

### Arquivos existentes:

- ✅ `e2e_async_api_test.rs` — Async API (worker isolate)
- ✅ `e2e_basic_connection_test.rs` — Conexão básica
- ✅ `e2e_catalog_test.rs` — Catalog (tables, columns, typeInfo)
- ✅ `e2e_pool_test.rs` — Connection pooling
- ✅ `e2e_streaming_test.rs` — Streaming
- ✅ `e2e_bulk_operations_test.rs` — Bulk insert
- ✅ `e2e_batch_executor_test.rs` — Batch executor
- ✅ `e2e_execution_engine_test.rs` — Execution engine
- ✅ `e2e_sqlserver_test.rs` — SQL Server específico
- ✅ `e2e_structured_error_test.rs` — Structured errors
- ✅ `e2e_driver_capabilities_test.rs` — Driver capabilities
- ✅ `e2e_test.rs` — Genérico

### Arquivos faltando (previstos no roadmap):

- ❌ `e2e_timeout_test.rs` — Testar connection/login/query timeout
- ❌ `e2e_retry_test.rs` — Testar retry execution
- ❌ `e2e_savepoint_test.rs` — Testar savepoint via FFI (quando exposto)
- ❌ `e2e_schema_test.rs` — Testar PK/FK/Indexes (quando implementado)

---

## 7. Evidências de Código

### Savepoint (Rust implementation complete)

**Arquivo**: `native/odbc_engine/src/engine/transaction.rs:202-226`

```rust
pub struct Savepoint<'t> {
    transaction: &'t Transaction,
    name: String,
}

impl<'t> Savepoint<'t> {
    pub fn create(transaction: &'t Transaction, name: &str) -> Result<Self> {
        let sql = format!("SAVEPOINT {}", name);
        transaction.execute_sql(&sql)?;
        Ok(Self { transaction, name: name.to_string() })
    }

    pub fn rollback_to(&self) -> Result<()> {
        let sql = format!("ROLLBACK TO SAVEPOINT {}", self.name);
        self.transaction.execute_sql(&sql)
    }

    pub fn release(self) -> Result<()> {
        let sql = format!("RELEASE SAVEPOINT {}", self.name);
        self.transaction.execute_sql(&sql)
    }
}
```

**Teste existente** (ignored): `native/odbc_engine/tests/transaction_test.rs:175-227`

**Conclusão**: Implementação pronta, precisa só FFI wrapper.

---

### Query Timeout (Rust implementation exists)

**Arquivo**: `native/odbc_engine/src/engine/query.rs:23-29`

```rust
pub fn execute_query_with_params_and_timeout(
    handles: SharedHandleManager,
    conn_id: u32,
    sql: &str,
    params: &[ParamValue],
    timeout_ms: Option<u32>,
) -> Result<Vec<u8>> {
    // ... implementation
}
```

**FFI**: `odbc_prepare()` aceita `timeout_ms`

**Conclusão**: Funciona via prepared statements, falta direct query timeout.

---

### Catalog (já exposto e funcionando)

**FFI**:
- `odbc_catalog_tables` (`ffi/mod.rs:874`)
- `odbc_catalog_columns` (`ffi/mod.rs:976`)
- `odbc_catalog_type_info` (`ffi/mod.rs:1076`)

**Dart**:
- `catalogTables()`, `catalogColumns()`, `typeInfo()` em `OdbcService`

**Testes**:
- `e2e_catalog_test.rs`

**Conclusão**: Catalog básico está completo. Roadmap pede **expansão** (PK/FK/Indexes).

---

### Error Retry Categorization (exists)

**Rust** (`error/mod.rs:112-120`):
```rust
pub fn is_retryable(&self) -> bool {
    matches!(
        self,
        OdbcError::ConnectionLost(_) | OdbcError::Timeout | OdbcError::PoolError(_)
    )
}
```

**Dart** (`odbc_error.dart:53`):
```dart
bool get isRetryable => /* ... */;
```

**Testes**: `error/mod.rs:347-376`

**Conclusão**: Categorização existe, falta retry execution (`RetryHelper`).

---

## 8. Recomendação Final

### Status correto:

1. **Async API**: ✅ Implementado, testado, documentado
2. **Savepoints**: ⚠️ **Implementado em Rust, precisa FFI + Dart**
3. **Connection Timeouts**: ⚠️ Parcial (query timeout via prepare)
4. **Automatic Retry**: ⚠️ Parcial (categorização de erro)
5. **Schema Reflection**: ⚠️ Parcial (tables/columns, falta PK/FK/Idx)
6. **Backpressure**: ⚠️ Parcial (pause/resume, falta buffer control)
7. **Connection String Builder**: ❌ Não implementado

### O que "ficou para trás"?

**Sim**, várias features ficaram **parcialmente implementadas** ou **implementadas mas não expostas**:

- **Savepoints**: código Rust completo desde quando? Não está no roadmap como "implementado"
- **Query timeout**: existe mas não documentado/exposto corretamente
- **Catalog**: funciona mas roadmap não reflete isso (confunde com PK/FK)

**Ação necessária**:
1. Atualizar matriz de rastreabilidade do roadmap com status real
2. Priorizar exposição de Savepoints (quick win)
3. Documentar query timeout existente
4. Implementar features restantes (PK/FK, retry execution, buffer control)
