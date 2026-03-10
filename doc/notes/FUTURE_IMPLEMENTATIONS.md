# FUTURE_IMPLEMENTATIONS.md - Technical Backlog

Consolidated backlog of items not yet included in implemented scope.

**Last verified against code:** 2026-03-10

> Note: this file is in `doc/notes/` and intentionally documents pending
> implementation work.

## Summary

| Item                               | Status               | Priority |
| ---------------------------------- | -------------------- | -------- |
| ~~Schema reflection (PK/FK/Indexes)~~ | ✅ **Implemented (2026-03-10)** | ~~High~~ |
| Explicit SQL typing API (`SqlDataType`) | Planned (not started) | Medium |
| Output parameters by driver/plugin | Out of current scope | Medium   |

## ~~1. Schema reflection (PK/FK/Indexes)~~ — ✅ IMPLEMENTED

**Implemented on**: 2026-03-10

### Implementation summary

- ✅ Rust: `list_primary_keys`, `list_foreign_keys`, `list_indexes` in `catalog.rs`
- ✅ FFI: `odbc_catalog_primary_keys`, `odbc_catalog_foreign_keys`, `odbc_catalog_indexes`
- ✅ Dart: Full binding → Repository → Service chain
- ✅ Example: `example/catalog_reflection_demo.dart`

## 1. Output parameters by driver/plugin

### Current state

- No public API for output parameters
- Engine/plugin extension points exist, but no stable Dart contract yet

### Current decision

- Out of immediate scope
- Revisit when there is a concrete driver-specific requirement (for example: SQL Server OUTPUT, Oracle REF CURSOR)

## 2. Explicit SQL typing API (`SqlDataType`)

### Current state

- Public parameter contract is `ParamValue` (stable)
- No explicit public `SqlDataType` API yet

### Current decision

- Keep as planned non-breaking evolution
- Revisit when there is a clear driver-aware typing requirement

## Criteria to move from open to implemented

1. Public API defined and documented
2. Unit and integration tests covering main flow
3. Working example in `example/` (when applicable)
4. Entry in `CHANGELOG.md`


