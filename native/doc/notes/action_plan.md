# Plano de Ação - Próximas Implementações

> **Guia prático step-by-step** para implementar features pendentes  
> **Complementa**: `roadmap.md` (visão estratégica)  
> **Foco**: Ações concretas e checklist executável

---

## 🎯 Visão Geral Rápida

### Status Atual
- ✅ Core engine: 100% completo
- ✅ 48 funções FFI expostas
- ✅ 8 fases do plano original concluídas
- ⚠️ 3 refinamentos pendentes (não-bloqueantes)
- 🔒 8 funcionalidades implementadas mas não expostas

### Próximos Milestones

| Milestone | Prazo | Features | Esforço |
|-----------|-------|----------|---------|
| **M1: Enterprise Ready** | Q1 2026 | ✅ Audit + Capabilities + Tests | Concluído |
| **M2: Async API** | Q2 2026 | Async execute/stream/cancel | 2-3 semanas |
| **M3: Performance Boost** | Q2-Q3 2026 | Cache + Benchmarks + Reuse | Contínuo |
| **M4: Multi-Database** | Q3-Q4 2026 | BCP + Multi-DB testing | 3-4 semanas |

---

## 📋 Milestone 1: Enterprise Ready (Prioridade ALTA)

**Meta**: Expor funcionalidades críticas para deployments enterprise.

### Feature 1.1: Audit Logger

**Status atual**: ✅ MVP entregue (FFI + Dart sync/async tipado + docs principais)

#### Checklist de Implementação

- [x] **Etapa 1: FFI Layer** (4-6 horas)
  - [x] Adicionar `AuditLogger` global em `GlobalState`
  - [x] Implementar `odbc_audit_enable(c_int enabled) -> c_int`
  - [x] Implementar `odbc_audit_get_events(buffer, len, out_written, limit) -> c_int`
  - [x] Implementar `odbc_audit_clear() -> c_int`
  - [x] Implementar `odbc_audit_get_status(buffer, len, out_written) -> c_int`
  - [x] Adicionar exports em `odbc_exports.def`
  - [x] Atualizar `cbindgen.toml` se necessário

- [x] **Etapa 2: Serialization** (2-3 horas)
  - [x] Criar `AuditEvent::to_json()` → JSON string
  - [x] Criar `serialize_audit_events(Vec<AuditEvent>) -> Vec<u8>`
  - [x] Criar `serialize_audit_status() -> Vec<u8>`
  - [x] Testes de serialization

- [x] **Etapa 3: Integration** (2-3 horas)
  - [x] Integrar audit em `odbc_connect()` → log connection
  - [x] Integrar audit em `odbc_exec_query()` → log query
  - [x] Integrar audit em error paths → log error
  - [x] Adicionar flag `audit_enabled` em `GlobalState`

- [x] **Etapa 4: Bindings Dart** (3-4 horas)
  - [x] Gerar bindings: `dart run ffigen`
  - [x] Criar `lib/infrastructure/native/audit/odbc_audit_logger.dart`
  - [x] Criar models: `AuditEvent`, `AuditStatus`
  - [x] Parser JSON → Dart objects
  - [x] Wrapper de alto nível
  - [x] Wrapper async tipado: `AsyncOdbcAuditLogger`

- [x] **Etapa 5: Testes** (4-5 horas)
  - [x] Unit tests Rust (audit.rs)
  - [x] Integration tests FFI (ffi/mod.rs)
  - [x] Unit tests Dart
  - [x] Widget tests (N/A: sem UI de audit)
  - [x] E2E test: full audit cycle

- [x] **Etapa 6: Documentação** (1-2 horas)
  - [x] Atualizar `ffi_api.md` com novas funções
  - [x] Criar exemplo em `example/audit_example.dart`
  - [x] Atualizar README com feature audit
  - [x] Adicionar docstrings em Dart

**Arquivos a Modificar**:
```
native/odbc_engine/src/ffi/mod.rs                     # +150 linhas
native/odbc_engine/src/security/audit.rs              # +50 linhas (serialization)
native/odbc_engine/odbc_exports.def                   # +4 linhas
lib/infrastructure/native/audit/odbc_audit_logger.dart # Novo arquivo
lib/infrastructure/native/audit/async_odbc_audit_logger.dart # Novo arquivo
test/infrastructure/native/audit/                     # Testes
native/doc/ffi_api.md                                 # Atualizar
example/audit_example.dart                            # Novo arquivo
```

**Estimativa Total**: 16-23 horas (~2-3 dias)

---

### Feature 1.2: Driver Capabilities Complete

#### Checklist de Implementação

- [x] **Etapa 1: Expandir Detection** (3-4 horas)
  - [x] Implementar detecção inicial de capabilities por driver (heurística via connection string)
  - [x] Adicionar detection para PostgreSQL, MySQL
  - [x] Testar detection em SQL Server
  - [x] Adicionar `to_json()` em `DriverCapabilities`

- [x] **Etapa 2: FFI Function** (2-3 horas)
  - [x] Implementar `odbc_get_driver_capabilities(conn_str, buffer, len, out) -> c_int`
  - [x] Serializar `DriverCapabilities` → JSON
  - [x] Validação de ponteiros e buffers
  - [x] Adicionar export

- [x] **Etapa 3: Bindings Dart** (2-3 horas)
  - [x] Gerar bindings FFI
  - [x] Criar `lib/infrastructure/native/driver_capabilities.dart`
  - [x] Parser JSON → `DriverCapabilities` object
  - [ ] Enum `DatabaseType` (opcional, pode ser string)

- [x] **Etapa 4: Testes** (3-4 horas)
  - [x] Unit tests: Detection logic
  - [x] Integration tests: JSON serialization
  - [x] E2E tests: SQL Server, PostgreSQL (se disponível)
  - [x] Test: Unknown driver → defaults

- [x] **Etapa 5: Documentação** (1 hora)
  - [x] Atualizar `ffi_api.md`
  - [x] Exemplo de uso adaptativo
  - [x] Tabela de capabilities por database

**Estimativa Total**: 11-15 horas (~1.5-2 dias)

---

### Feature 1.3: Testes Regressão Structured Error

#### Checklist de Implementação

- [x] **Etapa 1: Testes de Formato** (2-3 horas)
  - [x] `test_structured_error_format_stability()`
  - [x] `test_structured_error_sqlstate_mapping()`
  - [x] `test_structured_error_native_code_preservation()`
  - [x] `test_structured_error_serialization_roundtrip()`

- [x] **Etapa 2: Testes de Isolamento** (2-3 horas)
  - [x] `test_structured_error_per_connection_isolation()` (FFI `odbc_get_structured_error_for_connection`)
  - [x] `test_structured_error_concurrent_access()`
  - [x] `test_structured_error_message_sanitization()`
  - [x] Resolver flakiness em parallel runs (testes em `structured_error_regression_test.rs`)

- [x] **Etapa 3: Testes de Edge Cases** (2 horas)
  - [x] `test_structured_error_buffer_too_small()` (em ffi/mod.rs)
  - [x] `test_structured_error_null_pointers()` (em ffi/mod.rs)
  - [x] `test_structured_error_empty_message()`
  - [x] `test_structured_error_very_long_message()`

- [x] **Etapa 4: CI/CD** (1 hora)
  - [x] Adicionar step de teste de structured error (`cargo test --workspace`)
  - [ ] Configurar `--test-threads=1` se necessário (não necessário por ora)
  - [ ] Badge de coverage (opcional)

**Arquivos**:
```
native/odbc_engine/tests/structured_error_regression_test.rs  # Novo
native/odbc_engine/src/error/mod.rs                           # Testes adicionais
.github/workflows/ci.yml                                      # Run Rust tests
lib/infrastructure/native/bindings/odbc_bindings.dart         # odbc_get_structured_error_for_connection
lib/infrastructure/native/native_odbc_connection.dart         # getStructuredErrorForConnection
```

**Estimativa Total**: 7-9 horas (~1 dia)

---

## 📋 Milestone 2: API Assíncrona (Prioridade ALTA)

**Meta**: Prover API não-bloqueante para operações de longa duração.

### Feature 2.1: Async Execute

#### Checklist de Implementação

- [x] **Etapa 1: Design da API** (4-6 horas)
  - [x] Definir tipos C (poll-based, sem callbacks)
  - [x] Definir lifecycle de async requests
  - [x] Documento `native/doc/async_api_design.md`
  - [x] Protótipo (implementado diretamente em `ffi/mod.rs`)

- [x] **Etapa 2: Request Management** (6-8 horas)
  - [x] Criar `AsyncRequest` struct (slot/outcome)
  - [x] Criar `AsyncRequestManager` em `GlobalState`
  - [x] Implementar `allocate_async_request_id()`
  - [x] Implementar tracking de requests ativas

- [x] **Etapa 3: FFI Functions** (8-10 horas)
  - [x] `odbc_execute_async(conn_id, sql) -> request_id` (poll-based)
  - [x] `odbc_async_poll(request_id, out_status) -> c_int`
  - [x] `odbc_async_cancel(request_id) -> c_int`
  - [x] `odbc_async_get_result(request_id, buffer, len, out) -> c_int`
  - [x] `odbc_async_free(request_id) -> c_int`
  - [x] Adicionar exports

- [ ] **Etapa 4: Background Execution** (6-8 horas)
  - [x] Integrar com `async_bridge` (`spawn_blocking_task`)
  - [x] Implementar spawn de tasks Tokio
  - [x] Handle panics em async context
  - [ ] Callback invocation via FFI (N/A no design poll-based)

- [ ] **Etapa 5: Bindings Dart** (8-10 horas)
  - [x] Gerar bindings FFI (manual update em `odbc_bindings.dart`)
  - [x] Wiring em `AsyncNativeOdbcConnection` (start/poll/get/cancel/free)
  - [x] Implementar `Future<T> executeAsync(String sql)` (alto nível, poll-based)
  - [ ] Implementar `Stream<T> streamAsync(String sql)`
  - [ ] Gerenciar callbacks via `NativeCallable` (N/A no design poll-based)

- [ ] **Etapa 6: Testes Completos** (10-12 horas)
  - [x] Unit Rust: validações FFI básicas (invalid ID/null pointers)
  - [x] Integration (Dart isolate fake worker): execute async + poll + get/free
  - [ ] Integration: Execute async + callback (N/A no design poll-based)
  - [x] E2E: 10+ ops async simultâneas
  - [x] E2E: Cancel async operation
  - [x] E2E: Error handling async (invalid DSN / status error path)
  - [x] E2E: Execute async + poll + get_result
  - [x] Performance: Async vs sync overhead

- [ ] **Etapa 7: Documentação** (3-4 horas)
  - [ ] Atualizar `ffi_api.md`
  - [ ] Criar `async_api_guide.md`
  - [ ] 3+ exemplos práticos
  - [ ] Migration guide (sync → async)

**Estimativa Total**: 45-58 horas (~1.5-2 semanas)

---

### Feature 2.2: Async Stream

#### Checklist de Implementação

- [x] **Etapa 1: Async Stream State** (4-6 horas)
  - [x] Estender `StreamKind` para async
  - [x] Implementar `AsyncStreamState`
  - [x] Background fetch de batches

- [x] **Etapa 2: FFI Functions** (6-8 horas)
  - [x] `odbc_stream_start_async(conn_id, sql, fetch_size, chunk_size) -> stream_id` (poll-based, sem callback)
  - [x] `odbc_stream_poll_async(stream_id, out_status) -> c_int`
  - [x] Reutilizar `odbc_stream_fetch()` (compatível)
  - [x] Reutilizar `odbc_stream_close()` (compatível)

- [ ] **Etapa 3: Bindings e Testes** (8-10 horas)
  - [x] Bindings Dart
  - [x] `Stream<T> streamAsync()`
  - [x] Testes completos
  - [x] Documentação

**Estimativa Total**: 18-24 horas (~3-4 dias)

---

## 📋 Milestone 3: Optimization & Polish (Contínuo)

### Feature 3.1: Metadata Cache

#### Checklist de Implementação

- [x] **Etapa 1: Instanciar Cache** (2-3 horas)
  - [x] Adicionar `MetadataCache` em `GlobalState`
  - [x] Configurar via env `ODBC_METADATA_CACHE_SIZE` (default: 100)
  - [x] Configurar TTL via env `ODBC_METADATA_CACHE_TTL_SECS` (default: 300)

- [x] **Etapa 2: Integrar em Catalog** (3-4 horas)
  - [x] Modificar `odbc_catalog_columns()` para usar cache
  - [x] Cache key: `{conn_id}:{table_name}`
  - [x] Hit → retornar cached
  - [x] Miss → query + cache result

- [ ] **Etapa 3: FFI Management** (3-4 horas)
  - [ ] `odbc_metadata_cache_enable(max_size, ttl_secs) -> c_int`
  - [ ] `odbc_metadata_cache_stats(buffer, len, out) -> c_int`
  - [ ] `odbc_metadata_cache_clear() -> c_int`

- [ ] **Etapa 4: Testes e Benchmark** (4-5 horas)
  - [x] Test: Cache hit/miss
  - [x] Test: TTL expiration
  - [ ] Test: LRU eviction
  - [ ] Benchmark: 80%+ redução em queries repetitivos

**Estimativa Total**: 12-16 horas (~2 dias)

---

### Feature 3.2: Benchmarks Comparativos

#### Checklist de Implementação

- [ ] **Etapa 1: Scripts de Benchmark** (4-6 horas)
  - [ ] Criar `native/odbc_engine/benches/comparative_bench.rs`
  - [ ] Single-row insert benchmark
  - [ ] Bulk insert: array vs parallel vs BCP
  - [ ] SELECT: cold vs warm vs streaming
  - [ ] Rodar contra SQL Server local

- [ ] **Etapa 2: Documentação** (3-4 horas)
  - [ ] Criar `native/doc/performance_comparison.md`
  - [ ] Tabelas comparativas
  - [ ] Gráficos (se possível)
  - [ ] Recomendações de uso

- [ ] **Etapa 3: CI/CD** (2-3 horas)
  - [ ] Integrar benchmarks em CI
  - [ ] Alertar em regressions > 10%
  - [ ] Publish benchmark results

**Estimativa Total**: 9-13 horas (~1.5-2 dias)

---

### Feature 3.3: Timeout Override e Statement Reuse Opt-in

#### Checklist de Implementação

- [ ] **Etapa 1 (M1): Timeout Override Fechado** (4-6 horas)
  - [ ] Aplicar `timeout_override_ms` em `odbc_execute()` com precedência clara
  - [ ] Regra: `override > 0` usa override, senão usa timeout do statement
  - [ ] Aplicar timeout via `SQLSetStmtAttr` antes da execução
  - [ ] Backward compatible (`timeout_override_ms = 0` mantém legado)
  - [ ] Atualizar `native/doc/ffi_api.md` com precedência e exemplos

- [ ] **Etapa 2 (M2): Statement Handle Reuse Opt-in** (8-12 horas)
  - [ ] Adicionar feature flag `statement-handle-reuse` (default off)
  - [ ] Implementar pool/reuse por conexão
  - [ ] LRU eviction com cleanup defensivo
  - [ ] Cobrir erro/cleanup sem leak

- [ ] **Etapa 3: Testes e Benchmark** (4-5 horas)
  - [ ] Test: Timeout enforcement (query longa com timeout curto)
  - [ ] Test: Timeout success (mesma query com timeout suficiente)
  - [ ] Test: Statement reuse (quando feature flag ativa)
  - [ ] Test: Pool eviction
  - [ ] Benchmark: 10%+ melhoria em carga repetitiva (feature flag)

**Estimativa Total**: 16-23 horas (~2-3 dias)

---

## 📋 Milestone 4: Multi-Database Support

### Feature 4.1: BCP Nativo SQL Server

#### Checklist de Implementação

- [ ] **Etapa 1: Research** (4-6 horas)
  - [ ] Estudar SQL Server BCP API
  - [ ] Verificar disponibilidade em `odbc-api`
  - [ ] Prototipar binding direto se necessário
  - [ ] Definir fallback strategy

- [ ] **Etapa 2: Implementação** (12-16 horas)
  - [ ] Implementar `BulkCopyExecutor::bulk_copy_native()`
  - [ ] Integrar com `bcp.dll` ou SQL Server API
  - [ ] Fallback automático para ArrayBinding
  - [ ] Error handling robusto

- [ ] **Etapa 3: Feature Flag** (2-3 horas)
  - [ ] Garantir `sqlserver-bcp` feature funciona
  - [ ] Documentar build com feature
  - [ ] CI/CD com e sem feature

- [ ] **Etapa 4: Testes e Benchmark** (6-8 horas)
  - [ ] E2E: 100k rows via BCP
  - [ ] E2E: Fallback funciona
  - [ ] Benchmark: BCP vs ArrayBinding
  - [ ] Meta: 2-5x speedup

**Estimativa Total**: 24-33 horas (~3-4 dias)

---

### Feature 4.2: Multi-Database Testing

#### Checklist de Implementação

- [ ] **Etapa 1: Docker Setup** (8-10 horas)
  - [ ] Criar `docker-compose.yml`
  - [ ] PostgreSQL + schema setup
  - [ ] MySQL + schema setup
  - [ ] Oracle (opcional)
  - [ ] Sybase SQL Anywhere (opcional)

- [ ] **Etapa 2: Connection Helpers** (4-6 horas)
  - [ ] Estender `helpers/env.rs`
  - [ ] `get_postgresql_test_dsn()`
  - [ ] `get_mysql_test_dsn()`
  - [ ] Auto-detect via env vars

- [ ] **Etapa 3: Test Matrix** (12-16 horas)
  - [ ] Port E2E tests para multi-DB
  - [ ] Skip tests incompatíveis
  - [ ] Validar quirks por banco
  - [ ] 80%+ tests passam em todos

- [ ] **Etapa 4: CI/CD** (6-8 horas)
  - [ ] Matrix testing em GitHub Actions
  - [ ] Test contra todos os bancos
  - [ ] Badge de compatibility

**Estimativa Total**: 30-40 horas (~4-5 dias)

---

## 🗓️ Calendário de Execução

### Q1 2026 (Jan-Mar)

**Semanas 1-2**: Milestone 1 (Enterprise Ready)
- Semana 1: Audit Logger (F1.1)
- Semana 2: Capabilities (F1.2) + Tests (F1.3)

**Milestone 1 Complete**: ✅ Enterprise features expostas

---

### Q2 2026 (Abr-Jun)

**Semanas 3-5**: Milestone 2 (Async API)
- Semanas 3-4: Async Execute (F2.1)
- Semana 5: Async Stream (F2.2)

**Semanas 6-8**: Milestone 3 (Optimization) - Parte 1
- Semana 6: Metadata Cache (F3.1)
- Semana 7: Benchmarks (F3.2)
- Semana 8: Timeout Override (M1) + kickoff do Reuse opt-in (F3.3)

**Milestone 2 Complete**: ✅ API assíncrona funcional  
**Milestone 3 Parte 1 Complete**: ✅ Optimizations implementadas

---

### Q3 2026 (Jul-Set)

**Semanas 9-10**: Milestone 3 (Optimization) - Parte 2
- Contínuo: Refinamentos baseados em feedback

**Semanas 11-13**: Milestone 4 (Multi-Database) - Parte 1
- Semanas 11-12: BCP Nativo (F4.1)
- Semana 13: Setup multi-database

**Milestone 4 Parte 1**: ⚠️ BCP em progresso

---

### Q4 2026 (Out-Dez)

**Semanas 14-17**: Milestone 4 (Multi-Database) - Parte 2
- Semanas 14-16: Multi-DB testing (F4.2)
- Semana 17: Polimento e estabilização

**Semanas 18-20**: Buffer e documentação final
- Refinamentos finais
- Documentação completa
- Preparação para v1.0

**Milestone 4 Complete**: ✅ Multi-database support

---

## 📊 Matriz de Dependências

```
┌──────────────────────────────────────────────────────┐
│                  MILESTONE 1                         │
│             Enterprise Ready (Q1)                    │
│                                                      │
│  F1.1 Audit Logger  ────┐                          │
│                         ├─→ Docs                    │
│  F1.2 Capabilities  ────┤                          │
│                         └─→ Examples                │
│  F1.3 Tests Regression ─┘                          │
└──────────────────────────┬───────────────────────────┘
                           │
                           ↓
┌──────────────────────────────────────────────────────┐
│                  MILESTONE 2                         │
│               Async API (Q2)                         │
│                                                      │
│  Async Bridge (já pronto)                           │
│       ↓                                              │
│  F2.1 Async Execute  ────┐                         │
│                          ├─→ F2.2 Async Stream      │
│  Request Manager     ────┘                          │
└──────────────────────────┬───────────────────────────┘
                           │
                           ↓
┌──────────────────────────────────────────────────────┐
│                  MILESTONE 3                         │
│            Optimization (Q2-Q3)                      │
│                                                      │
│  F3.1 Metadata Cache  ──┐                          │
│                         ├─→ Performance Review      │
│  F3.2 Benchmarks  ──────┤                          │
│                         │                            │
│  F3.3 Statement Reuse ──┘                          │
└──────────────────────────┬───────────────────────────┘
                           │
                           ↓ (independente)
┌──────────────────────────────────────────────────────┐
│                  MILESTONE 4                         │
│          Multi-Database (Q3-Q4)                      │
│                                                      │
│  F4.1 BCP Native ────────┐                         │
│  (SQL Server only)       │                          │
│                          ├─→ Cross-DB validation    │
│  F4.2 Multi-DB Testing ──┘                         │
│  (PostgreSQL, MySQL, etc)                           │
└──────────────────────────────────────────────────────┘
```

**Nota**: Milestone 1 é pré-requisito para M2. M3 e M4 podem ser desenvolvidos em paralelo.

---

## 🎯 Quick Wins (< 1 dia cada)

Tarefas de **alto impacto, baixo esforço** que podem ser feitas a qualquer momento:

### QW1: Expor `odbc_get_version()` ⏱️ 2 horas

**O que**: Retornar versão da engine (API + ABI).

```c
c_int odbc_get_version(
    u8* buffer,  // JSON: {"api": "0.1.0", "abi": "1.0.0"}
    c_uint buffer_len,
    c_uint* out_written
);
```

**Por quê**: Cliente pode validar compatibilidade.

---

### QW2: Expor pool statistics detalhadas ⏱️ 3 horas

**O que**: Expandir `odbc_pool_get_state()` com métricas detalhadas.

```json
{
  "total_connections": 10,
  "idle_connections": 8,
  "active_connections": 2,
  "wait_count": 0,
  "wait_time_ms": 0,
  "max_wait_time_ms": 0,
  "avg_wait_time_ms": 0
}
```

**Por quê**: Monitoring e tuning de pool.

---

### QW3: Adicionar `odbc_pool_set_size()` ⏱️ 2 horas

**O que**: Permitir resize dinâmico de pool.

```c
c_int odbc_pool_set_size(c_uint pool_id, c_uint new_max_size);
```

**Por quê**: Ajustar pool sem recriar conexão.

---

### QW4: Logging level configurável ⏱️ 2 horas

**O que**: Configurar nível de log via FFI.

```c
c_int odbc_set_log_level(c_int level);  // 0=Off, 1=Error, 2=Warn, 3=Info, 4=Debug
```

**Por quê**: Debugging em produção.

---

### QW5: Connection string validation ⏱️ 3 horas

**O que**: Validar connection string sem conectar.

```c
c_int odbc_validate_connection_string(
    const char* conn_str,
    u8* error_buffer,
    c_uint error_buffer_len
);
```

**Por quê**: UX melhorada, feedback rápido.

---

## 📊 Tracking e Reporting

### Template de Status Report (Semanal)

```markdown
## Status Report - Semana X (Data)

### Progresso Geral
- Milestone: [Nome]
- Progresso: XX% (X de Y features completas)
- Bloqueios: [Lista ou Nenhum]

### Features Concluídas Esta Semana
- [x] Feature X.Y - [Nome]
  - Commits: [hash1, hash2]
  - PRs: #123
  - Testes: XXX passando

### Features Em Progresso
- [ ] Feature X.Y - [Nome]
  - Progresso: XX%
  - Bloqueio: [Se houver]
  - ETA: [Data]

### Métricas
- Testes: XXX/YYY passando (XX%)
- Coverage: XX%
- Build time: Xs
- Clippy warnings: X

### Próxima Semana
- [ ] Tarefa 1
- [ ] Tarefa 2
- [ ] Tarefa 3
```

---

## 🚨 Alertas e Thresholds

### Alertas Automáticos (CI/CD)

| Métrica | Threshold | Ação |
|---------|-----------|------|
| **Clippy warnings** | > 0 | ❌ Bloquear merge |
| **Test failures** | > 0 | ❌ Bloquear merge |
| **Coverage drop** | > 2% | ⚠️ Review requerido |
| **Performance regression** | > 10% | ⚠️ Review requerido |
| **Build time increase** | > 20% | ⚠️ Investigar |
| **Binary size increase** | > 15% | ⚠️ Review requerido |

---

## 🎯 Definição de "Done" por Feature

### Feature está "Done" quando:

- [x] **Código**:
  - Implementação completa
  - `cargo fmt` aplicado
  - `cargo clippy` sem warnings
  - Code review aprovado

- [x] **Testes**:
  - Unit tests (coverage > 80%)
  - Integration tests
  - E2E tests (se aplicável)
  - Todos os testes passando

- [x] **FFI** (se aplicável):
  - Funções FFI implementadas
  - Exports adicionados em `.def`
  - Bindings Dart gerados
  - Header C atualizado

- [x] **Documentação**:
  - `ffi_api.md` atualizado
  - Docstrings completas
  - 1+ exemplo de uso
  - CHANGELOG atualizado

- [x] **Quality Gates**:
  - Sem breaking changes (ou versioned)
  - Performance baseline mantida ou melhorada
  - Sem security issues
  - Backward compatible

---

## 📝 Templates de Implementação

### Template: Adicionar Nova Função FFI

**Arquivo**: `native/odbc_engine/src/ffi/mod.rs`

```rust
/// [Descrição breve da função]
/// [Detalhes dos parâmetros]
/// Returns: [descrição do retorno]
#[no_mangle]
pub extern "C" fn odbc_nova_funcao(
    param1: c_uint,
    param2: *const c_char,
    buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    // 1. Validar ponteiros
    if buffer.is_null() || out_written.is_null() {
        return -1;
    }

    // 2. Validar parâmetros
    if buffer_len == 0 {
        set_out_written_zero(out_written);
        return -1;
    }

    // 3. Lock global state
    let Some(mut state) = try_lock_global_state() else {
        set_out_written_zero(out_written);
        return -1;
    };

    // 4. Validar IDs
    if !state.connections.contains_key(&param1) {
        set_connection_error(&mut state, param1, format!("Invalid connection ID: {}", param1));
        set_out_written_zero(out_written);
        return -1;
    }

    // 5. Executar lógica
    let result_data = match realizar_operacao(&state, param1, param2) {
        Ok(data) => data,
        Err(e) => {
            set_connection_error(&mut state, param1, format!("Error: {}", e));
            set_out_written_zero(out_written);
            return -1;
        }
    };

    // 6. Verificar tamanho do buffer
    if result_data.len() > buffer_len as usize {
        set_out_written_zero(out_written);
        return -2; // Buffer too small
    }

    // 7. Copiar resultado
    unsafe {
        std::ptr::copy_nonoverlapping(result_data.as_ptr(), buffer, result_data.len());
        *out_written = result_data.len() as c_uint;
    }

    0 // Success
}
```

**Não esqueça**:
1. Adicionar em `odbc_exports.def`
2. Adicionar docstring
3. Criar testes
4. Atualizar `ffi_api.md`

---

### Template: Adicionar Binding Dart

**Arquivo**: `lib/infrastructure/native/[feature]/odbc_[feature].dart`

```dart
import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import '../bindings/odbc_bindings.dart';

class Odbc[Feature] {
  final OdbcBindings _bindings;

  Odbc[Feature](this._bindings);

  /// [Descrição da função]
  /// 
  /// Throws [OdbcException] em caso de erro.
  ResultType metodoPublico({
    required ParamType param1,
    ParamType? param2,
  }) {
    // 1. Preparar buffers
    final buffer = calloc<ffi.Uint8>(1024);
    final written = calloc<ffi.Uint32>();

    try {
      // 2. Chamar FFI
      final result = _bindings.odbc_funcao_ffi(
        param1.value,
        buffer,
        1024,
        written,
      );

      // 3. Validar retorno
      if (result != 0) {
        throw OdbcException('Erro ao executar: código $result');
      }

      // 4. Ler resultado
      final bytesWritten = written.value;
      if (bytesWritten == 0) {
        return ResultType.empty();
      }

      final data = buffer.asTypedList(bytesWritten);
      
      // 5. Parse resultado
      return _parseResult(data);

    } finally {
      // 6. Cleanup
      calloc.free(buffer);
      calloc.free(written);
    }
  }

  ResultType _parseResult(Uint8List data) {
    // Implementar parsing (JSON, binary protocol, etc)
  }
}
```

---

## 🔧 Ferramentas e Automação

### Scripts Úteis

#### 1. Rodar Todos os Testes com Benchmark

```bash
# native/scripts/full_test.sh
#!/bin/bash

echo "🧪 Running unit tests..."
cargo test --lib

echo "🧪 Running integration tests..."
cargo test --tests

echo "🧪 Running E2E tests..."
ENABLE_E2E_TESTS=1 cargo test --tests -- --ignored

echo "📊 Running benchmarks..."
cargo bench

echo "✅ All tests complete!"
```

#### 2. Validar Feature Completa

```bash
# native/scripts/validate_feature.sh <feature_name>
#!/bin/bash

FEATURE=$1

echo "📋 Validating feature: $FEATURE"

# Check code quality
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings

# Run tests
cargo test --lib "$FEATURE"
cargo test --tests "$FEATURE"

# Check documentation
if ! grep -q "$FEATURE" native/doc/ffi_api.md; then
    echo "❌ Documentation missing in ffi_api.md"
    exit 1
fi

echo "✅ Feature $FEATURE validated!"
```

#### 3. Gerar Bindings e Atualizar Docs

```bash
# scripts/update_ffi.sh
#!/bin/bash

cd native/odbc_engine

# Rebuild
cargo build --release

# Generate C header
cbindgen --config cbindgen.toml --output odbc_bindings.h

# Generate Dart bindings
cd ../..
dart run ffigen

echo "✅ FFI bindings updated!"
```

---

## 📚 Checklist de Release

### Pre-Release (1 semana antes)

- [ ] **Code Freeze**
  - [ ] Merge de todas as features
  - [ ] Branch `release/vX.Y.Z` criada

- [ ] **Quality Assurance**
  - [ ] Todos os testes passando
  - [ ] Zero clippy warnings
  - [ ] Coverage > 80%
  - [ ] Performance baselines mantidos

- [ ] **Documentation Review**
  - [ ] Todos os docs atualizados
  - [ ] CHANGELOG completo
  - [ ] Migration guide (se breaking changes)
  - [ ] API docs revisados
  - [ ] Planos 100% concluídos removidos de `native/doc/`
  - [ ] Índices/referências atualizados após remoção dos planos

- [ ] **Testing Completo**
  - [ ] E2E em SQL Server
  - [ ] E2E em PostgreSQL (se suportado)
  - [ ] E2E em MySQL (se suportado)
  - [ ] Stress tests (24h+ run)
  - [ ] Memory leak tests

### Release Day

- [ ] **Tag e Build**
  - [ ] Git tag `vX.Y.Z`
  - [ ] Build release binaries (Windows, Linux, macOS)
  - [ ] Checksums gerados

- [ ] **Publish**
  - [ ] Pub.dev (se público)
  - [ ] GitHub Release
  - [ ] Release notes
  - [ ] Binary artifacts

- [ ] **Communication**
  - [ ] Announcement (se público)
  - [ ] Update README badges
  - [ ] Update documentation site

### Post-Release (1 semana depois)

- [ ] **Monitoring**
  - [ ] Monitor crash reports
  - [ ] Monitor performance metrics
  - [ ] Coletar feedback

- [ ] **Hotfix Ready**
  - [ ] Branch `hotfix/vX.Y.Z` pronta
  - [ ] Processo de hotfix documentado

---

## 🔄 Processo de Desenvolvimento

### Workflow de Feature

```
1. Planning
   ↓
2. Design Review
   ↓
3. Implementation (branch feature/xxx)
   ↓
4. Self-Test (local)
   ↓
5. Code Review (PR)
   ↓
6. CI/CD Validation
   ↓
7. Merge to main
   ↓
8. Deploy to staging
   ↓
9. E2E Testing
   ↓
10. Deploy to production
```

### Branch Strategy

- `main` - Stable, sempre deployable
- `develop` - Integration branch (opcional)
- `feature/xxx` - Feature branches
- `hotfix/xxx` - Hotfixes para produção
- `release/vX.Y.Z` - Release preparation

---

## 📞 Pontos de Decisão

### Quando Implementar?

**Use esta tabela para decidir prioridade de cada feature:**

| Se o cliente precisa de... | Implemente | Prioridade |
|----------------------------|------------|------------|
| Compliance/audit trail | Audit Logger (F1.1) | 🔴 Alta |
| Adaptar código por database | Capabilities (F1.2) | 🔴 Alta |
| Operações não-bloqueantes | Async API (F2) | 🔴 Alta |
| Performance extrema (SQL Server) | BCP Nativo (F4.1) | 🟡 Média |
| Suporte PostgreSQL/MySQL | Multi-DB (F4.2) | 🟡 Média |
| Cache de schemas | Metadata Cache (F3.1) | 🟢 Baixa |
| Otimização micro | Statement Reuse opt-in (F3.3) | 🟢 Baixa |

---

## ✅ Conclusão

Este plano de ação fornece:

1. ✅ **Roadmap claro** com 4 milestones (Q1-Q4 2026)
2. ✅ **Checklist executável** para cada feature
3. ✅ **Estimativas realistas** de esforço
4. ✅ **Priorização baseada em valor** (Quick Wins + Matriz)
5. ✅ **Templates prontos** para implementação
6. ✅ **Processo documentado** de desenvolvimento
7. ✅ **Critérios de sucesso** claros

### Próxima Ação Recomendada

**Comece por Milestone 1** (Enterprise Ready):
1. Implemente Audit Logger (F1.1) - Maior impacto
2. Depois Capabilities (F1.2) - Complementar
3. Finalize com Tests (F1.3) - Consolidar qualidade

**ETA**: 1-2 semanas para M1 completo.

---

**Última atualização**: 2026-03-02  
**Versão do documento**: 1.0  
**Manutenção**: Revisar mensalmente e após cada milestone
