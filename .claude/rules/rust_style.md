---
paths:
  - "native/**/*.rs"
  - "native/**/Cargo.toml"
---

# Rust Style and Quality (Native)

## Formatting and Linting

- Always run `cargo fmt`.
- Run `cargo clippy --all-targets --all-features`.
- Prefer fixing lint warnings over suppressing them.
- Keep suppressions narrow and justified.

## API and Naming

- Follow idiomatic Rust naming conventions.
- Keep visibility as narrow as possible.
- Favor explicit, small, well-scoped public APIs.
- Prefer strong domain types over loosely typed strings/blobs.

## Error Handling

- Use `Result<T, E>` for fallible paths.
- Use domain-specific errors for API boundaries.
- Avoid `unwrap()`/`expect()` in runtime library code.
- Add contextual information when propagating errors.

## FFI Safety

- Use `#[repr(C)]` for C-facing data types.
- Validate pointers and lengths at boundaries.
- Prevent panics from crossing FFI boundaries.
- Document ownership/lifetime expectations clearly.

## Checklist

- [ ] `fmt` and `clippy` pass cleanly.
- [ ] Public API remains minimal and explicit.
- [ ] FFI boundaries validate all unsafe inputs.
- [ ] Error paths are explicit and contextual.
