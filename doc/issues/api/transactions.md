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

Objetivo:

- fornecer estrategia de retry fora do core SQL.

Criterios:

- guia e exemplo documentados.
- sem retry silencioso no core.

## Implementation Notes

_When implementing items from this file, create GitHub issues using `.github/ISSUE_TEMPLATE.md`_

---

## Fora de escopo (core)

- 2PC/distributed transactions cross-database.
- XA/DTC coordinator no runtime.
- nested transactions reais alem de savepoints.
