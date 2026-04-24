# Features (`doc/Features`)

This folder holds **feature-oriented documentation**: short indexes and summaries; deeper type and protocol notes live under `doc/notes/`.

## Contents

| Document | Description |
| -------- | ----------- |
| [PENDING_IMPLEMENTATIONS.md](PENDING_IMPLEMENTATIONS.md) | PT-BR quick reference of work still **open** or **partially** implemented (XA MSDTC optional hardening, OCI path deferred, maturação de `OUT` / `REF CURSOR`, columnar v2, infra E2E), with links to `TYPE_MAPPING` and `columnar_protocol_sketch` where relevant. |

## See also

- [`CHANGELOG.md`](../../CHANGELOG.md) — entregas e histórico.
- [`doc/notes/TYPE_MAPPING.md`](../notes/TYPE_MAPPING.md) — contrato de tipos e roadmap §3.
- [`doc/CAPABILITIES_v3.md`](../CAPABILITIES_v3.md) — visão consolidada do que já está entregue, incluindo DRT1 / `OUT1`, `MULT` + `OUT1`, `QueryResult.additionalResults` e `QueryResult.refCursorResults`.
- Repository overview: [`README.md`](../../README.md).

Quando um item listado em `PENDING_IMPLEMENTATIONS.md` fechar, actualizar o `CHANGELOG.md`, alinhar `doc/CAPABILITIES_v3.md` / `doc/notes/TYPE_MAPPING.md`, e remover ou encurtar a secção correspondente aqui.
