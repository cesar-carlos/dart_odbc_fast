# Documentation (`doc/`)

Index for package documentation. Prefer the linked source of truth for each
topic; avoid duplicating matrices across files.

## Core

| Document | Owns |
| -------- | ---- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Dart layers, barrels (`odbc_fast` / `odbc_fast_native`), `ServiceLocator`, sub-interfaces, runners, events |
| [API_SURFACE.md](API_SURFACE.md) | FFI exports, ABI notes, Dart ↔ FFI mapping |
| [CAPABILITIES_v3.md](CAPABILITIES_v3.md) | Engine × capability matrix (XA, BCP, upsert, …) |
| [BUILD.md](BUILD.md) | Build prerequisites, scripts, related-doc links |
| [TESTING.md](TESTING.md) | Test scopes and canonical opt-in env flags |
| [PERFORMANCE.md](PERFORMANCE.md) | Defaults, concurrency, BCP notes, open perf work |

## Features & backlog

| Document | Owns |
| -------- | ---- |
| [Features/README.md](Features/README.md) | Feature-doc index + release checklist |
| [Features/PENDING_IMPLEMENTATIONS.md](Features/PENDING_IMPLEMENTATIONS.md) | **SoT** for open / deferred product work |
| [notes/ROADMAP_PENDENTES.md](notes/ROADMAP_PENDENTES.md) | Short priority pointer → PENDING only |

## Notes (contracts & deep dives)

| Document | Owns |
| -------- | ---- |
| [notes/TYPE_MAPPING.md](notes/TYPE_MAPPING.md) | Type / DRT1 / OUT1 / MULT / ref-cursor wire contracts |
| [notes/columnar_protocol_sketch.md](notes/columnar_protocol_sketch.md) | Columnar v2 wire layout |
| [notes/TVP_DESIGN_GATE.md](notes/TVP_DESIGN_GATE.md) | TVP product gate |
| [notes/REF_CURSOR_ORACLE_ROADMAP.md](notes/REF_CURSOR_ORACLE_ROADMAP.md) | Oracle engine path notes (contracts live in TYPE_MAPPING) |

## Development & versioning

| Document | Owns |
| -------- | ---- |
| [development/docker-test-stack.md](development/docker-test-stack.md) | Docker compose / multi-engine test stack |
| [development/msdtc-recovery.md](development/msdtc-recovery.md) | MSDTC recovery runbook |
| [version/](version/) | Versioning strategy, quick reference, release automation |

## Also see

- Consumer overview: [`README.md`](../README.md)
- Examples: [`example/README.md`](../example/README.md)
- Native engine docs: [`native/doc/README.md`](../native/doc/README.md)
- Release history: [`CHANGELOG.md`](../CHANGELOG.md)
