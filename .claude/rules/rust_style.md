---
paths:
  - "native/**/*.rs"
  - "native/**/Cargo.toml"
---

# Rust Style and Quality (Native)

**Based on**: Rust Style Guide, rustfmt, Clippy, and Rust API Guidelines.

## Formatting and Linting

- âœ… Always format with `cargo fmt` (rustfmt is the source of truth for formatting)
- âœ… Run `cargo clippy --all-targets --all-features` before merging touched Rust code
- âœ… Prefer fixing Clippy warnings instead of silencing them
- âŒ Avoid broad `#[allow(...)]` at module/crate level without a clear reason
- âŒ Never suppress Rust diagnostics unless explicitly allowlisted in `error_handling.md`

## API and Naming

- âœ… Follow idiomatic Rust naming (`snake_case`, `UpperCamelCase`, `SCREAMING_SNAKE_CASE`)
- âœ… Keep visibility minimal (`pub(crate)`/private by default, `pub` only when required)
- âœ… Keep public APIs small and explicit
- âœ… Prefer strong types over loose `String`/`Vec<u8>` in domain contracts

## Error Handling

- âœ… Return `Result<T, E>` for fallible paths
- âœ… Use domain-specific errors (`thiserror`) for library boundaries
- âœ… Add actionable context when propagating errors
- âŒ Avoid `unwrap()`/`expect()` in library/runtime code (acceptable in tests and controlled bootstrap code)

## Comments and Docs

- âœ… Use comments for intent, invariants, and safety rationale
- âœ… Prefer self-explanatory code over comment-heavy code
- âŒ Do not add comments that only restate the line below
- âœ… Document public APIs when behavior/contracts are not obvious

## FFI Safety (relevant to this repo)

- âœ… Use `#[repr(C)]` for FFI-facing structs/enums exposed to C
- âœ… Validate pointers and lengths at FFI boundaries
- âœ… Ensure panics do not cross FFI boundaries
- âœ… Clearly document ownership/lifetime rules for pointers crossing FFI

## References

- https://doc.rust-lang.org/style-guide/
- https://rust-lang.github.io/rustfmt/
- https://doc.rust-lang.org/clippy/
- https://rust-lang.github.io/api-guidelines/

