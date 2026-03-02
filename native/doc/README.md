# Native (Rust) documentation

This folder contains curated documentation for the Rust native layer in `native/`,
focused on **what is implemented today** (and how to use it).

## 📋 Index

### ✅ Active Documents (use for current work)

- 🗺️ **[Roadmap 2026](./notes/roadmap.md)** - Visão estratégica, priorização, cronograma
- ✅ **[Action Plan](./notes/action_plan.md)** - Checklist executável e plano de execução
- 🚀 **[Getting Started](./getting_started_with_implementation.md)** - Guia prático para implementação
- 🧩 **[Plan Checklist Template](./plan_checklist_template.md)** - Checklist reutilizável para fechar planos
- 🔌 **[FFI API Reference](./ffi_api.md)** - API C/FFI atual
- 📐 **[FFI Conventions](./ffi_conventions.md)** - Contratos e padrões da fronteira FFI
- ⚡ **[Data Paths](./data_paths.md)** - Fluxos internos de dados
- 🔒 **[Unexposed Features](./notes/unexposed_features.md)** - Funcionalidades prontas para exposição
- 🏗️ **[ODBC Engine Overview](./odbc_engine_overview.md)** - Arquitetura do engine

### 📚 Historical / Snapshot Documents (completed analyses)

- 📈 [Bulk Operations Benchmark](./bulk_operations_benchmark.md) - Resultado pontual de benchmark
- 🕒 [Statement Reuse and Timeout](./notes/statement_reuse_and_timeout.md) - Revisão técnica pontual
- 📌 [Doc Status](./DOC_STATUS.md) - Mapa rápido de status dos documentos

> Note: `implementation_plan.md` was removed after full completion.

## 🧹 Policy: Remove Completed Plans

To keep this folder lean, implementation plans must be removed after full
completion.

Use this rule for every plan document:

1. Mark plan as complete only when all DoD/checklists are done.
2. Validate with tests and docs updated in the same change.
3. Remove the completed plan file from `native/doc/`.
4. Update links in `README.md`, `roadmap.md`, `action_plan.md`, and related docs.

If historical context is needed, keep only a short summary in
`notes/roadmap.md` instead of preserving the full plan file.

For new plans, copy and use:
- `native/doc/plan_checklist_template.md`

### 🎯 Topics Covered

- ✅ Streaming (FFI chunked copy-out + true cursor batching)
- ✅ Batch execution (prepared statements + parameter binding)
- ✅ Array binding + parallel bulk insert
- ✅ Connection pooling (r2d2)
- ✅ Transactions (isolation levels + savepoints + RAII)
- ✅ Multi-result sets (SQLMoreResults)
- ✅ Spill-to-disk (large result sets)
- ✅ Caches (prepared statements, metadata)
- ✅ Protocol negotiation (binary protocol v2)
- ✅ Observability (metrics, tracing, OTLP)
- ✅ Security (sanitization, zeroize, audit)
- ✅ Runtime hardening (lock poisoning recovery)

## Quick Example: Audit Logger

```dart
final locator = ServiceLocator();
locator.initialize();

final audit = locator.auditLogger;
audit.enable();

final status = audit.getStatus();
final events = audit.getEvents(limit: 50);

// Optional cleanup after collection.
audit.clear();
```

## Quick Example: Audit Logger (Async Typed)

```dart
final locator = ServiceLocator();
locator.initialize(useAsync: true);

final audit = locator.asyncAuditLogger;
await audit.enable();

final status = await audit.getStatus();
final events = await audit.getEvents(limit: 50);

// Optional cleanup after collection.
await audit.clear();
```

Use cases:
- Validate query/activity flow during debugging.
- Capture minimal audit trail for support/compliance.

## Source of truth

The source of truth is always the Rust code under:

- `native/odbc_engine/src`
- `native/odbc_engine/tests`

Some additional docs live next to the crate:

- `native/odbc_engine/ARCHITECTURE.md`
- `native/odbc_engine/E2E_TESTS_ENV_CONFIG.md`
- `native/odbc_engine/MULTI_DATABASE_TESTING.md`
- `native/odbc_engine/TARPAULIN_COVERAGE_REPORT.md`


