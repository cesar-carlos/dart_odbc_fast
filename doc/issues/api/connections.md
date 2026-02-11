# Connections - Fase e Escopo

Last updated: 2026-02-11

## Estado atual

- connect/disconnect com login timeout.
- pool create/get/release/health/state/close.
- backend async por worker isolate.

## Escopo por fase

| Fase        | Escopo                                       | Issues             |
| ----------- | -------------------------------------------- | ------------------ |
| Fase 0 (P0) | sem mudanca estrutural em connections        | -                  |
| Fase 1 (P1) | padronizacao de contrato e telemetria basica | CONN-001, CONN-002 |
| Fase 2 (P2) | estrategia explicita de reuse                | CONN-003           |

## Fase 1 (P1)

### CONN-001 - Contrato unico de lifecycle

Objetivo:

- alinhar comportamento sync/async para os mesmos cenarios de erro.

Criterios:

- mesmos codigos de erro para falhas equivalentes.
- testes de integracao para timeout, invalid DSN e disconnect.

### CONN-002 - Pool telemetry minima

Objetivo:

- expor metricas operacionais basicas de pool.

Criterios:

- API sem quebra retroativa.
- teste para pool vazio, ocupado e fechado.

## Fase 2 (P2)

### CONN-003 - Politica de reutilizacao explicita

Objetivo:

- definir e documentar chave/politica de reuse no Dart.

Criterios:

- regra de reuse documentada com tradeoffs.
- teste de nao regressao em paralelo.

## Fora de escopo (core)

- router cross-database com failover automatico.
- federacao de query entre bancos no mesmo request.
