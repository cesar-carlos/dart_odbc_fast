# Prepared Statements - Fase e Escopo

Last updated: 2026-02-11

## Estado atual

- `prepare(connectionId, sql, timeoutMs)` implementado.
- `executePrepared(stmtId, params)` com parametros posicionais.
- `closeStatement(stmtId)` implementado.
- `cancel(stmtId)` ainda sem execucao real no core.

## Escopo por fase

| Fase        | Escopo                                              | Issues             |
| ----------- | --------------------------------------------------- | ------------------ |
| Fase 0 (P0) | estabilizacao compartilhada com requests (`cancel`) | REQ-004            |
| Fase 1 (P1) | lifecycle e options de prepared                     | PREP-001, PREP-002 |
| Fase 2 (P2) | named param facade e extensao plugin                | PREP-003, PREP-004 |

## Fase 1 (P1)

### PREP-001 - Lifecycle explicito prepare/execute/unprepare

Objetivo:

- expor `unprepare` como alias claro de close statement.

Criterios:

- API publica sem ambiguidade.
- teste para id invalido e double-close.

### PREP-002 - Options por statement

Objetivo:

- consolidar timeout e limites por statement.

Criterios:

- integracao sem quebra retroativa.
- teste de timeout por statement.

## Fase 2 (P2)

### PREP-003 - Named param facade no Dart

Objetivo:

- converter named params para positional no facade Dart.

Criterios:

- ordem de bind deterministica.
- erro claro para placeholder faltante.

### PREP-004 - Output params via plugin

Objetivo:

- suportar output params como extensao opcional por driver.

Criterios:

- core continua multi-driver.
- drivers suportados documentados.

## Implementation Notes

_When implementing items from this file, create GitHub issues using `.github/ISSUE_TEMPLATE.md`_

---

## Fora de escopo (core)

- output params genericos para todos os drivers.
- TVP e recursos procedure-specific como requisito universal.
