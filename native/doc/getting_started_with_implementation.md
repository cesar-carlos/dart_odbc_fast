# Getting Started - Native Implementation

Practical playbook for implementing new features in the Rust native layer.

## 1) Local setup

```bash
git clone <repo-url>
cd dart_odbc_fast/native

# Rust checks
cargo fmt --all
cargo clippy --all-targets --all-features -D warnings
cargo test
```

Optional E2E (database required):

```bash
cd native
ENABLE_E2E_TESTS=1 cargo test e2e_multi_db -- --nocapture
```

Use `native/doc/cross_database.md` for DSN and per-database setup.

## 2) Feature workflow

1. Define API contract first:
   - If FFI changes, update `ffi_api.md`.
   - If behavior contracts change, update `ffi_conventions.md`.
2. Implement in Rust under `native/odbc_engine/src`.
3. Add/adjust tests in `native/odbc_engine/tests`.
4. Run quality gates:
   - `cargo fmt --all`
   - `cargo clippy --all-targets --all-features -D warnings`
   - targeted tests + affected E2E.
5. Update docs affected by behavior changes.

## 3) Quality gates (required)

- Formatting clean (`cargo fmt`).
- No new clippy warnings.
- Relevant unit/integration/E2E tests passing.
- No performance regression for touched hot paths.

When performance-sensitive paths are changed:

```bash
cd native
cargo bench --bench comparative_bench
```

## 4) Where to implement

- `src/ffi/mod.rs`: `odbc_*` C ABI entry points.
- `src/engine/*`: query execution, streaming, transactions, pooling helpers.
- `src/protocol/*`: binary protocol encode/decode.
- `src/pool/*`: pooled connection lifecycle.
- `src/observability/*`: metrics/tracing.
- `src/security/*`: sanitization, secure buffers, audit.

See `odbc_engine_overview.md` for a full map.

## 5) Documentation map

- `ffi_api.md`: FFI reference and signatures.
- `ffi_conventions.md`: return codes, pointer/out contracts, ID rules.
- `data_paths.md`: execution and data flow internals.
- `async_api_guide.md`: async usage model from Dart.
- `cross_database.md`: compatibility matrix and SQL quirks.

## 6) Before merge checklist

- [ ] Scope is clear and limited.
- [ ] Contracts updated (`ffi_api.md` / `ffi_conventions.md`) when needed.
- [ ] Tests added/updated for changed behavior.
- [ ] Lints and tests pass locally.
- [ ] Docs updated for user-visible or operational changes.

## 7) Current priority

Track active priorities in the project issue tracker or open PR checklist.
This document intentionally stays implementation-agnostic.
