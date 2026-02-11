# Issues - dart_odbc_fast

Status: organizado  
Last updated: 2026-02-11

## Objetivo

Centralizar planejamento em formato executavel por **fase** e **escopo** para
o driver ODBC nativo (Rust + Dart FFI).

## Estrutura

```text
doc/issues/
|-- README.md
|-- ROADMAP.md
`-- api/
    |-- connections.md
    |-- requests.md
    |-- transactions.md
    `-- prepared-statements.md
```

## Organizacao por fase e escopo

| Fase   | Prioridade | Escopo principal                              | Documentos                                                                |
| ------ | ---------- | --------------------------------------------- | ------------------------------------------------------------------------- |
| Fase 0 | P0         | estabilizacao de core (bugs e contratos)      | `ROADMAP.md`, `api/requests.md`                                           |
| Fase 1 | P1         | paridade util de API com benchmark de mercado | `api/connections.md`, `api/transactions.md`, `api/prepared-statements.md` |
| Fase 2 | P2         | extensoes ODBC-first e melhorias de produto   | todos os `api/*.md`                                                       |

## Definicao de escopo

| Escopo             | Definicao                                                            |
| ------------------ | -------------------------------------------------------------------- |
| Core (in-scope)    | funcionalidade portavel entre drivers ODBC e sem quebra de API       |
| Plugin (candidate) | funcionalidade especifica de banco que nao deve contaminar o core    |
| Fora de escopo     | alto acoplamento, alto risco ou baixa portabilidade no runtime atual |

## Ordem de leitura

1. `ROADMAP.md`
2. `api/connections.md`
3. `api/requests.md`
4. `api/transactions.md`
5. `api/prepared-statements.md`
