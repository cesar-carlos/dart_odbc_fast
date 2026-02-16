# STATEMENT_CANCELLATION_IMPLEMENTATION_CHECKLIST.md

Execution checklist for GAP 5 (statement cancellation contract).

## Objective

Remove ambiguity between Dart-exposed cancellation API and current Rust capability.

## Current baseline

- Dart exposes cancellation entry points.
- Rust marks cancellation path as unsupported in current runtime contract.

## Decision gate

- [ ] D1. Confirm product decision:
  - Option A: implement true cancellation end to end.
  - Option B: keep unsupported and expose capability explicitly.

Acceptance gate:

- Single approved decision recorded in docs/changelog notes.

## Phase 1 - Contract alignment

- [ ] P1.1 Align public Dart API docs with current capability.
- [ ] P1.2 Standardize error classification for unsupported cancellation.
- [ ] P1.3 Ensure sync and async paths return equivalent behavior.
- [ ] P1.4 Update examples to avoid implying unsupported behavior works.

Acceptance gate:

- API behavior is explicit and consistent across all layers.

## Phase 2A - If Option A is approved (implement real cancellation)

- [ ] P2A.1 Define Rust FFI/native contract and lifecycle constraints.
- [ ] P2A.2 Implement native cancellation behavior with robust error handling.
- [ ] P2A.3 Wire Dart bindings/wrappers/repository/service to real contract.
- [ ] P2A.4 Add capability detection/fallback when driver does not support cancellation.

Acceptance gate:

- Real cancellation is functional where supported and safe fallback exists where unsupported.

## Phase 2B - If Option B is approved (keep unsupported)

- [ ] P2B.1 Return explicit unsupported error in all code paths.
- [ ] P2B.2 Add troubleshooting guidance for cancellation alternatives.
- [ ] P2B.3 Mark unsupported status in canonical docs and release notes.

Acceptance gate:

- No hidden behavior or silent no-op remains.

## Phase 3 - Test hardening

- [ ] P3.1 Unit tests for sync cancellation behavior.
- [ ] P3.2 Unit tests for async cancellation behavior.
- [ ] P3.3 Regression tests for error code/message consistency.
- [ ] P3.4 Integration test (where environment permits) for selected decision path.

Acceptance gate:

- Cancellation contract is fully covered by tests for the chosen decision path.

## Validation commands

1. `dart analyze`
2. `dart test`
3. `cd native && cargo test -p odbc_engine --lib`

## References

- `doc/notes/GAPS_IMPLEMENTATION_MASTER_PLAN.md` (GAP 5)
- `doc/TROUBLESHOOTING.md`
