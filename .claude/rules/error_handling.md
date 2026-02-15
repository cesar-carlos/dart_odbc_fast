---
paths:
  - "lib/**/*.dart"
  - "test/**/*.dart"
  - "native/**/*.rs"
  - "native/**/Cargo.toml"
---

# Error Handling and Suppression Policy

## Core Policy

- Treat recoverable failures as values (`Result` in Rust, typed exceptions/results in Dart).
- Propagate errors with context at boundaries.
- Preserve stack traces and source chains when rethrowing.
- Never swallow errors silently.
- Never suppress diagnostics unless allowlisted.

## Dart Guidance

- Prefer typed catches (`on SomeException`) over broad catches.
- Use `rethrow` when preserving stack trace is required.
- Avoid empty `catch` blocks.
- Validate external input and fail fast with clear errors.

## Rust Guidance

- Return `Result<T, E>` for fallible operations.
- Prefer domain-specific errors (`thiserror`) at boundaries.
- Avoid `unwrap()` and `expect()` in runtime/library code.
- Add context when converting or propagating errors.

## Suppression Rules

- Use the smallest possible scope for any suppression.
- Always document the reason for suppression.
- Remove suppressions when no longer needed.
- Do not use broad file-level suppressions without explicit justification.

## Checklist

- [ ] Errors carry actionable context.
- [ ] No silent failure paths were introduced.
- [ ] Suppressions are minimal and justified.
- [ ] Runtime code avoids unsafe panic shortcuts.
