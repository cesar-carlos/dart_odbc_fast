# Funcionalidades Implementadas Nao Expostas via FFI

Documento de plano para decidir, priorizar e entregar exposicao de features
Rust ja implementadas no `odbc_engine` e ainda nao disponiveis no cliente Dart.

## Objetivo

Definir um plano executavel para exposicao incremental de funcionalidades
internas, mantendo compatibilidade, seguranca e estabilidade do contrato FFI.

## Escopo

### Incluido neste plano

- Priorizar features com maior valor de produto.
- Definir estrategia `Now / Later / Not now`.
- Definir criterios de aceite (DoD) por feature priorizada.
- Definir testes minimos obrigatorios por entrega.

### Fora de escopo (neste ciclo)

- Reescrever subsistemas internos sem impacto direto no contrato FFI.
- Expor APIs experimentais sem gate por feature flag quando houver risco.
- Alterar protocolo binario para alem do contrato v2 atual.

## Inventario Atual (Fonte Tecnica)

| Funcionalidade | Localizacao | Estado Interno | Exposicao FFI |
|----------------|-------------|----------------|---------------|
| Async Bridge | `src/async_bridge/mod.rs` | Implementada e usada internamente | Nao exposta |
| Metadata Cache | `src/engine/core/metadata_cache.rs` | Implementada, uso interno limitado | Nao exposta |
| Query Pipeline | `src/engine/core/pipeline.rs` | Implementada, sem uso ativo | Nao exposta |
| Audit Logger | `src/security/audit.rs` | Implementada, nao conectada ao FFI | Nao exposta |
| Driver Capabilities | `src/engine/core/driver_capabilities.rs` | Implementada | Parcial (`odbc_detect_driver` apenas nome) |
| Connection Manager | `src/engine/core/connection_manager.rs` | Legacy, substituida por `r2d2` | Nao aplicavel |
| Security Layer | `src/engine/core/security_layer.rs` | Implementada, uso interno | Nao exposta |
| Memory Engine | `src/engine/core/memory_engine.rs` | Implementada e usada internamente | Interno apenas |
| Protocol Negotiation | `src/engine/core/protocol_engine.rs` | Implementada, v2 hardcoded | Nao exposta |
| Feature `sqlserver-bcp` | `Cargo.toml` / bulk path | Parcial (fallback para array binding) | Feature flag |

## Priorizacao de Entrega

### Now (proxima release)

1. **Driver Capabilities (completar exposicao)**
2. **Audit Logger (exposicao basica)**

### Later (proximo ciclo)

3. **Metadata Cache (controles e estatisticas)**
4. **Async Bridge (primeira API async minimamente util)**

### Not now (manter interno)

5. Query Pipeline
6. Memory Engine
7. Security Layer
8. Protocol Negotiation
9. Connection Manager (avaliar remocao em vez de exposicao)

## Plano de Execucao

### Milestone M1 - Capabilities e Auditoria

**Objetivo**: entregar introspeccao do driver e trilha minima de auditoria.

**Escopo M1**:
- Expor capabilities reais por conexao.
- Expor enable/get/clear para auditoria.
- Atualizar bindings e wrappers Dart.

### Milestone M2 - Cache e Async Foundation

**Objetivo**: aumentar performance de metadata e preparar base async externa.

**Escopo M2**:
- Expor controle do metadata cache (enable/config/stats/clear).
- Entregar primeira operacao async (`execute_async` + poll/status).
- Gate por feature flag se risco operacional for alto.

## Definicao de Pronto (DoD)

### 1) Driver Capabilities

- FFI exposta: `odbc_get_driver_capabilities(conn_id, ...)`.
- Payload estavel (JSON ou binario documentado) com campos minimos:
  `supports_transactions`, `supports_savepoints`,
  `supports_multiple_result_sets`, `supports_bulk_operations`.
- Wrapper Dart com tipo forte e fallback seguro.
- Testes:
  - Unit Rust para serializacao do payload.
  - Integration Rust para `conn_id` invalido e buffer curto.
  - E2E com pelo menos 1 driver real.
- Doc atualizada em `native/doc/ffi_api.md`.

### 2) Audit Logger

- FFI exposta: `odbc_audit_enable`, `odbc_audit_get_events`,
  `odbc_audit_clear`.
- Sanitizacao obrigatoria de dados sensiveis no evento.
- Limite de memoria/eventos definido e documentado.
- Testes:
  - Unit Rust para redacao/sanitizacao.
  - Integration Rust para ciclo enable/get/clear.
  - E2E de uma operacao de conexao + query + erro.
- Wrapper Dart com leitura paginada ou por limite.

### 3) Metadata Cache (M2)

- FFI exposta para configuracao minima:
  `odbc_metadata_cache_enable`, `odbc_metadata_cache_configure`,
  `odbc_metadata_cache_stats`, `odbc_metadata_cache_clear`.
- TTL e max_size validam limites e valores invalidos.
- Testes:
  - Unit para hit/miss/expiry.
  - Integration para concorrencia basica.
  - E2E para repeticao de consulta de schema.

### 4) Async Bridge (M2)

- FFI inicial:
  `odbc_execute_async`, `odbc_async_poll`, `odbc_async_cancel`.
- Contrato de estado claro: pending/running/completed/failed/canceled.
- Timeout e cancelamento comportando-se de forma deterministica.
- Testes:
  - Unit para maquina de estados.
  - Integration para cancel e timeout.
  - E2E com 10+ operacoes simultaneas.

## Dependencias e Impacto

- `src/ffi/mod.rs`: novos endpoints e validacao de ponteiros/buffers.
- `native/odbc_engine/odbc_exports.def`: export symbols.
- `ffigen.yaml` + `lib/infrastructure/native/bindings/`: regeracao de binding.
- Wrappers Dart em `lib/infrastructure/native/wrappers/`.
- Testes Rust em `native/odbc_engine/tests/` e Dart em `test/infrastructure`.

## Riscos e Mitigacoes

| Risco | Impacto | Mitigacao |
|------|---------|-----------|
| Quebra de contrato FFI | Alto | Versionar payload, manter backward compatibility |
| Exposicao de dados sensiveis no audit | Alto | Sanitizacao obrigatoria e testes de redacao |
| Divergencia entre drivers em capabilities | Medio | Fallback por default seguro + matriz E2E |
| Instabilidade na API async inicial | Medio | Entrega incremental com feature flag |
| Regressao de performance | Medio | Bench antes/depois em cenarios alvo |

## Matriz de Testes Minima por Milestone

| Milestone | Unit | Integration | E2E | Gate de release |
|----------|------|-------------|-----|-----------------|
| M1 | Obrigatorio | Obrigatorio | Obrigatorio | Todos verdes + sem regressao critica |
| M2 | Obrigatorio | Obrigatorio | Obrigatorio | Todos verdes + benchmark dentro da meta |

## Criterios para Marcar "Completo"

Este plano so pode ser marcado como completo quando:

- [ ] M1 entregue com APIs FFI publicadas e wrappers Dart.
- [ ] M2 entregue (ou formalmente replanejado) com aprovacao registrada.
- [ ] `ffi_api.md` e docs de uso atualizados.
- [ ] Suite de testes (Rust e Dart) sem regressao nas features tocadas.
- [ ] Riscos de seguranca revisados para auditoria e async.

## Backlog Tecnico (Nao Prioritario)

- Query Pipeline: manter interno ate existir caso real de uso.
- Memory Engine: manter interno, apenas observabilidade opcional.
- Protocol Negotiation: reavaliar quando houver v3.
- Connection Manager legacy: avaliar remocao controlada.
- `sqlserver-bcp`: manter como feature opcional ate implementacao nativa real.

## Comandos de Verificacao (Operacional)

```bash
# Rust
cargo fmt
cargo clippy --all-targets --all-features
cargo test --lib
cargo test --tests

# E2E (quando DSN configurado)
ENABLE_E2E_TESTS=1 cargo test --tests -- --ignored

# Dart bindings e testes
dart run ffigen
dart test
```

## Conclusao

O inventario estava tecnicamente bom, mas faltava fechamento de execucao.
Com este plano, o documento passa a ser acionavel, com prioridade clara,
DoD verificavel, risco mapeado e criterio objetivo de conclusao.
