# Template - Checklist de Fechamento de Plano

Use este template ao criar qualquer novo plano em `native/doc` ou
`native/doc/notes`.

---

## Identificação do Plano

- **Nome do plano**:
- **Arquivo**:
- **Owner**:
- **Data de criação**:
- **Data alvo de conclusão**:
- **Status**: `draft` | `in_progress` | `blocked` | `done`

---

## Escopo e DoD

- [ ] Escopo `in` e `out` definido no documento.
- [ ] Critérios de aceite (DoD) claros e testáveis.
- [ ] Dependências e riscos documentados.
- [ ] Gate de qualidade definido (lint/tests/bench quando aplicável).

---

## Execução Técnica

- [ ] Implementação Rust concluída.
- [ ] Implementação Dart/FFI concluída (se aplicável).
- [ ] Feature flags/configs alinhadas com a proposta.
- [ ] Migração/backward compatibility validada.

---

## Validação

- [ ] `cargo fmt` limpo.
- [ ] `cargo clippy --all-targets --all-features` sem warnings novos.
- [ ] Testes unit passando.
- [ ] Testes integration passando.
- [ ] Testes E2E passando (quando aplicável).
- [ ] Benchmarks executados e comparados (quando aplicável).
- [ ] Sem regressão funcional/performance relevante.

---

## Documentação

- [ ] `ffi_api.md` atualizado (se contrato FFI mudou).
- [ ] `ffi_conventions.md` atualizado (se convenções mudaram).
- [ ] Docs de uso/exemplos atualizados.
- [ ] `notes/roadmap.md` atualizado com resumo final (1-2 parágrafos).

---

## Fechamento Automático do Plano

> Só marcar `done` quando todos os itens acima estiverem concluídos.

- [ ] Plano marcado como `done` no próprio arquivo.
- [ ] Arquivo do plano removido de `native/doc/` ou `native/doc/notes/`.
- [ ] Links/referências atualizados após remoção em:
  - [ ] `native/doc/README.md`
  - [ ] `native/doc/notes/roadmap.md`
  - [ ] `native/doc/getting_started_with_implementation.md`
  - [ ] Outros documentos que citavam o plano
- [ ] Nenhum link quebrado restante para o plano removido.

---

## Registro Final (para histórico curto)

- **Resumo da entrega**:
- **Principais riscos mitigados**:
- **Testes executados**:
- **Pendências explícitas (se houver)**:
- **Data de encerramento**:
