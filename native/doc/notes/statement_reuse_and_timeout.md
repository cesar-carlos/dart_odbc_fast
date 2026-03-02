# Statement Reuse and Timeout - Plano Executavel

Documento de execucao para fechar Fase 2 em torno de timeout por execucao e
definir trilha segura para statement handle reuse.

## Objetivo

- Concluir timeout efetivo por execucao no contrato FFI atual.
- Definir rollout controlado para reuse real de statement handles.
- Garantir criterios de aceite testaveis para marcar Fase 2 como concluida.

## Escopo

### Incluido (Fase 2)

- Aplicar `timeout_override_ms` em `odbc_execute` com precedencia clara.
- Cobrir timeout por testes integration/e2e.
- Atualizar documentacao de contrato e comportamento.

### Fora de escopo (Fase 2)

- Reuse completo de handles sem feature flag.
- Mudanca de protocolo ou quebra de contrato FFI existente.
- Otimizacoes sem validacao por benchmark multi-driver.

## Estado Atual (Baseline)

### Ja implementado

- Cache de prepared statements em `src/engine/core/prepared_cache.rs`
  (foco atual em metricas e observabilidade).
- Timeout no connect (`odbc_connect_with_timeout`).
- Timeout no prepare (`odbc_prepare(..., timeout_ms)`).
- Campo de override por execucao em `odbc_execute(..., timeout_override_ms, ...)`.

### Limites atuais

- Reuse real de handle ainda nao ocorre (cache nao guarda handle ODBC ativo).
- Timeout override ainda nao e aplicado de ponta a ponta em todos os fluxos.
- Faltam testes de enforcement real de timeout (query lenta/longa).

## Decisao de Arquitetura

### Estrategia escolhida: Hibrida

1. **Agora (Fase 2)**: timeout override completo e testado.
2. **Depois (Fase 3)**: statement handle reuse opt-in por feature flag.
3. **Promocao para default**: apenas apos benchmark e compatibilidade entre
   drivers alvo.

## Milestones

### M1 - Timeout Override Fechado (Fase 2)

**Objetivo**: garantir timeout efetivo por execucao sem quebrar compatibilidade.

**Entregas**:
- Aplicar `effective_timeout` com regra:
  - se `timeout_override_ms > 0`, usar override;
  - senao, usar `stmt.timeout_ms`.
- Aplicar timeout no statement imediatamente antes da execucao.
- Documentar precedencia no `ffi_api.md`.
- Criar testes de timeout real em cenarios positivos e negativos.

### M2 - Statement Reuse Opt-in (Fase 3)

**Objetivo**: validar ganho de performance com risco controlado.

**Entregas**:
- Feature flag `statement-handle-reuse`.
- Ciclo completo de lifecycle: prepare miss, reuse hit, release em eviction.
- Validacao cross-driver (SQL Server, PostgreSQL, MySQL).
- Relatorio de benchmark e matriz de compatibilidade.

## Definicao de Pronto (DoD)

### 1) Timeout Override (obrigatorio para fechar Fase 2)

- [ ] `odbc_execute` usa timeout efetivo conforme precedencia documentada.
- [ ] `timeout_override_ms = 0` mantem comportamento legado.
- [ ] Timeout e aplicado no statement antes da chamada de execucao.
- [ ] Erros de timeout retornam codigo/estrutura consistente no contrato FFI.
- [ ] `ffi_api.md` atualizado com precedencia e exemplos.

**Testes minimos**:
- Unit: calculo de `effective_timeout`.
- Integration: buffer/ids invalidos + override valido.
- E2E: query longa com timeout curto falha como esperado.
- E2E: mesma query com timeout maior completa com sucesso.

### 2) Statement Handle Reuse (fora da Fase 2, mas com DoD definido)

- [ ] Feature flag funcional e default desligado.
- [ ] Reuse comprovado em hit de SQL equivalente.
- [ ] Eviction libera recursos sem leak.
- [ ] Sem regressao funcional nos testes existentes.
- [ ] Benchmark com ganho claro em carga repetitiva.

## Matriz de Testes por Entrega

| Entrega | Unit | Integration | E2E | Gate |
|--------|------|-------------|-----|------|
| Timeout Override (M1) | Obrigatorio | Obrigatorio | Obrigatorio | 100% verde no escopo |
| Reuse Opt-in (M2) | Obrigatorio | Obrigatorio | Obrigatorio | verde + benchmark aprovado |

## Riscos e Mitigacoes

| Risco | Impacto | Mitigacao |
|------|---------|-----------|
| Timeout nao aplicado em todos os fluxos | Alto | Centralizar aplicacao antes da execucao e testar caminhos principais |
| Divergencia de comportamento entre drivers | Medio | Validar matriz SQL Server/PostgreSQL/MySQL antes de promover default |
| Reuse gerar estado invalido em erro | Alto | Limpeza defensiva em erro e testes de lifecycle |
| Regressao de performance sem reuse | Baixo | M1 nao depende de reuse; medir baseline separado |

## Dependencias de Implementacao

- `native/odbc_engine/src/ffi/mod.rs`
- `native/odbc_engine/src/engine/core/prepared_cache.rs`
- `native/odbc_engine/src/engine/core/execution_engine.rs`
- `native/doc/ffi_api.md`
- `native/odbc_engine/tests/*` (integration/e2e relevantes)

## Criterio Objetivo de Conclusao da Fase 2

Fase 2 so pode ser marcada como concluida quando todos os itens abaixo
estiverem verdadeiros:

- [ ] Timeout override implementado e validado por testes de enforcement real.
- [ ] Documentacao FFI atualizada e revisada.
- [ ] Sem regressao nos testes existentes do escopo tocado.
- [ ] Limitacao de statement reuse mantida explicitamente documentada como
      "otimizacao de fase seguinte".

## Proximos Passos (apos Fase 2)

1. Implementar `statement-handle-reuse` atras de feature flag.
2. Rodar benchmark comparando prepare/execute repetitivos com e sem reuse.
3. Publicar matriz de compatibilidade por driver.
4. Decidir promocao para default com base em dados.

## Comandos de Verificacao

```bash
# Rust
cargo fmt
cargo clippy --all-targets --all-features
cargo test --lib
cargo test --tests

# E2E (quando DSN configurado)
ENABLE_E2E_TESTS=1 cargo test --tests -- --ignored
```

## Conclusao

O documento deixa de ser apenas review tecnico e passa a plano de execucao.
Fase 2 fica fechada com criterio objetivo (timeout override + testes), enquanto
statement reuse segue como melhoria controlada para fase posterior.
