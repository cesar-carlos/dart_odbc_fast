# Requests - Fase e Escopo

Last updated: 2026-02-11

## Estado atual

- `executeQuery` com stream/batched stream.
- `executeQueryParams` com parametros posicionais.
- `executeQueryMulti` exposto, mas sem parser Dart para payload multi-result.
- bulk insert array disponivel.

## Escopo por fase

| Fase        | Escopo                           | Issues                             |
| ----------- | -------------------------------- | ---------------------------------- |
| Fase 0 (P0) | estabilizacao de requests        | REQ-001, REQ-002, REQ-003, REQ-004 |
| Fase 1 (P1) | ergonomia de request por chamada | REQ-005                            |
| Fase 2 (P2) | sem item novo obrigatorio        | -                                  |

## Fase 0 (P0)

### REQ-001 - Multi-result end-to-end

Objetivo:

- implementar parser Dart para payload multi-result da FFI.

Criterios:

- suportar result set + row count no mesmo retorno.
- teste de integracao cobrindo caso real multi-result.

### REQ-002 - Remover limite de 5 parametros

Objetivo:

- suportar N parametros no fluxo parametrizado.

Criterios:

- query com >5 parametros em teste de integracao.
- sem regressao de performance para casos pequenos.

### REQ-003 - Suporte real a NULL

Objetivo:

- suportar parametro nulo sem fallback indevido.

Criterios:

- insert/update com null validado em teste.
- erro estruturado correto quando driver nao aceitar o tipo.

### REQ-004 - Contrato de cancelamento

Objetivo:

- implementar cancel real ou erro typed `UnsupportedFeature`.

Criterios:

- comportamento documentado e testado.
- sem falso sucesso em `cancel`.

## Fase 1 (P1)

### REQ-005 - Request options por chamada

Objetivo:

- timeout e buffer max por request.

Criterios:

- API com options opcionais sem quebra retroativa.
- teste de timeout com query longa.

## Fora de escopo (core)

- SQL auto-correction.
- query builder semantico completo no core.
- output params genericos sem evolucao de protocolo.
