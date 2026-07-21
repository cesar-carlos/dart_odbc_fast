# Features (`doc/Features`)

This folder holds feature-oriented documentation: short indexes and summaries;
deeper type and protocol notes live under `doc/notes/`.

## Contents

| Document | Description |
| -------- | ----------- |
| [PENDING_IMPLEMENTATIONS.md](PENDING_IMPLEMENTATIONS.md) | PT-BR quick reference separating what is **delivered**, what remains **manual/opt-in**, and what is **product-gated** (MSDTC recovery, OCI XA shim, TVP, output capability matrix, columnar default, live E2E). |

## See also

- [`doc/README.md`](../README.md) — documentation index.
- [`CHANGELOG.md`](../../CHANGELOG.md) - deliveries and release history.
- [`doc/notes/TYPE_MAPPING.md`](../notes/TYPE_MAPPING.md) - type contract,
  directed parameters and columnar roadmap.
- [`doc/notes/TVP_DESIGN_GATE.md`](../notes/TVP_DESIGN_GATE.md) - decisions
  required before TVP becomes an implementation item.
- [`doc/CAPABILITIES_v3.md`](../CAPABILITIES_v3.md) - consolidated delivered
  capabilities, including DRT1 / `OUT1`, `MULT + OUT1`,
  `QueryResult.additionalResults`, `QueryResult.refCursorResults` and
  `ResultEncoding`.
- [`doc/API_SURFACE.md`](../API_SURFACE.md) - FFI surface.
- Repository overview: [`README.md`](../../README.md).

When an item listed in `PENDING_IMPLEMENTATIONS.md` closes, update
`CHANGELOG.md`, align `doc/CAPABILITIES_v3.md` / `doc/notes/TYPE_MAPPING.md`,
and remove or shorten the corresponding section here.

## Release docs checklist

- `CHANGELOG.md` has the user-visible change under `[Unreleased]` or the
  release version.
- `README.md` still reflects the supported public behavior.
- `doc/CAPABILITIES_v3.md` matches the engine/capability matrix.
- `doc/notes/TYPE_MAPPING.md` owns type, wire, DRT1/OUT1/MULT and columnar
  contracts.
- `doc/TESTING.md` lists stable and opt-in commands with the correct env flags.
- `doc/PERFORMANCE.md` keeps row-major/columnar defaults and benchmark guidance
  aligned with code.
- `example/README.md` lists any new or changed examples.
- `test/documentation` and `test/example` pass without DSN.
