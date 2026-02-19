# FUTURE_IMPLEMENTATIONS.md - Technical Backlog

Consolidated backlog of items not yet included in implemented scope.

> Note: this file is in `doc/notes/` and intentionally documents pending
> implementation work.

## Summary

| Item                               | Status               | Priority |
| ---------------------------------- | -------------------- | -------- |
| Schema reflection (PK/FK/Indexes)  | Open                 | High     |
| Output parameters by driver/plugin | Out of current scope | Medium   |

## 1. Schema reflection (PK/FK/Indexes)

### Current state

- Basic catalog support exists (tables/columns/types)
- Domain entities for PK/FK/Indexes already exist

### Missing implementation

1. Rust functions to list PK/FK/Indexes
2. Matching FFI exposure
3. Dart repository/service methods
4. Integration tests with real database

## 2. Output parameters by driver/plugin

### Current state

- No public API for output parameters
- Engine/plugin extension points exist, but no stable Dart contract yet

### Current decision

- Out of immediate scope
- Revisit when there is a concrete driver-specific requirement (for example: SQL Server OUTPUT, Oracle REF CURSOR)

## Criteria to move from open to implemented

1. Public API defined and documented
2. Unit and integration tests covering main flow
3. Working example in `example/` (when applicable)
4. Entry in `CHANGELOG.md`


