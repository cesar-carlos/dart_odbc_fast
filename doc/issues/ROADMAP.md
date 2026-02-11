# ROADMAP - Fase e Escopo

Status: em execucao  
Last updated: 2026-02-11

## Objetivo

Organizar evolucao do `dart_odbc_fast` em backlog orientado por fase e escopo,
mantendo foco em ODBC portavel.

## Matriz de fase x escopo

| Fase        | Escopo                   | Resultado esperado                              |
| ----------- | ------------------------ | ----------------------------------------------- |
| Fase 0 (P0) | Core obrigatorio         | estabilidade de requests e contratos essenciais |
| Fase 1 (P1) | Core de paridade         | ergonomia de API e robustez operacional         |
| Fase 2 (P2) | Core estendido + plugins | observabilidade e extensoes por driver          |

## Escopo global

### Core (in-scope)

- Conexao e pool basicos.
- Requests SQL com parametros posicionais.
- Transacoes locais e savepoints.
- Prepared statements basicos.
- Bulk insert por array binding.

### Plugin (candidate)

- Recursos especificos de banco (ex.: output params por driver).
- Otimizacoes e mapeamentos SQL por vendor.

### Fora de escopo (neste ciclo)

- 2PC/distributed transactions no core.
- Router cross-database com failover automatico no core.
- SQL auto-correction no core.

## Fase 0 (P0) - Stabilization

Escopo:

- corrigir gaps funcionais que bloqueiam confiabilidade do core.

Itens:

- REQ-001: multi-result end-to-end.
- REQ-002: remover limite de 5 parametros.
- REQ-003: suporte real a parametro NULL.
- REQ-004: contrato de cancelamento (implementar ou unsupported explicito).

Criterio de saida:

- testes de integracao passando para os quatro itens.

## Fase 1 (P1) - Paridade util

Escopo:

- padronizar experiencia de uso sem acoplamento a um unico banco.

Itens:

- CONN-001, CONN-002.
- REQ-005.
- TXN-001, TXN-002.
- PREP-001, PREP-002.

Criterio de saida:

- contratos sync/async coerentes e documentados.

## Fase 2 (P2) - Expansao ODBC-first

Escopo:

- evolucao incremental com baixo risco de regressao.

Itens:

- CONN-003.
- TXN-003.
- PREP-003.
- PREP-004 (plugin candidate).
- observabilidade (metrics/tracing) consolidada.

Criterio de saida:

- backlog P2 pronto para execucao por lotes menores.

## Mapa por documento

- Connections: `doc/issues/api/connections.md`
- Requests: `doc/issues/api/requests.md`
- Transactions: `doc/issues/api/transactions.md`
- Prepared Statements: `doc/issues/api/prepared-statements.md`
