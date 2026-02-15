---
paths:
  - "lib/**/*.dart"
  - "test/**/*.dart"
  - "native/**/*.rs"
  - "native/**/Cargo.toml"
---

# Error Handling and Suppression Policy

## Core Policy

- âœ… Treat recoverable failures as values ​​​​(`Result` in Rust, typed exceptions/results in Dart)
- âœ… Propagate errors with context at each boundary
- âœ… Preserve original error chain/stack trace when rethrowing/forwarding
- âŒ Never swallow errors silently
- âŒ Never suppress diagnostics unless the suppression is in the allowlist below

## Suppression Allowlist (Only These Cases)

1. Generated files:
   - `**/*.g.dart`
   - `**/*.freezed.dart`
   - Generated Rust bindings/output (if committed)
2. Test-only negative-path scenarios under `test/**` where the code intentionally triggers analyzer/Clippy edge behavior.
3. Temporary suppression for third-party/tooling false positives, only if all conditions are met:
   - linked issue/ticket ID
   - short reason
   - removal target date/version

Anything else is forbidden.

## Dart Error Handling (Market Baseline)

- âœ… Prefer typed catches (`on SomeException`) over broad `catch`
- âœ… Use `rethrow` to preserve stack trace when propagating
- âœ… Throw only `Exception`/`Error` subtypes
- âŒ Do not catch `Error` unless there is a hard boundary reason
- âŒ Do not use empty `catch` blocks

## Rust Error Handling (Market Baseline)

- âœ… Return `Result<T, E>` for recoverable failures; use `panic!` for unrecoverable invariants
- âœ… Use `?` for propagation and preserving source chains
- âœ… Prefer meaningful custom error types implementing `std::error::Error`
- âœ… Add context when crossing abstraction boundaries
- âŒ Avoid `unwrap()`/`expect()` in runtime/library paths (tests/bootstrap are exceptions)
- âŒ Avoid blanket `#[allow(...)]` without scoped reason

## Suppression Hygiene

- âœ… Smallest scope possible (line > item > module > file)
- âœ… Add explicit reason metadata
- âœ… Revisit and remove suppressions quickly
- âŒ Never use `ignore_for_file: type=lint` outside allowlisted generated files

### Dart suppression template

```dart
// ignore: some_lint
// Reason: false positive with package_x vY, tracked in ISSUE-123, remove by 2026-06-30.
```

### Rust suppression template

```rust
#[allow(clippy::some_lint, reason = "False positive with crate_x 1.2; ISSUE-123; remove by 2026-06-30")]
```

## References

- https://dart.dev/language/error-handling
- https://dart.dev/tools/linter-rules/avoid_catches_without_on_clauses
- https://dart.dev/tools/linter-rules/empty_catches
- https://dart.dev/tools/linter-rules/use_rethrow_when_possible
- https://dart.dev/tools/linter-rules/only_throw_errors
- https://dart.dev/tools/linter-rules/unnecessary_ignore
- https://doc.rust-lang.org/book/ch09-03-to-panic-or-not-to-panic.html
- https://doc.rust-lang.org/std/error/
- https://rust-lang.github.io/api-guidelines/interoperability.html
- https://doc.rust-lang.org/rustc/lints/levels.html

