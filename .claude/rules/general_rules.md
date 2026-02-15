---
paths:
  - "lib/**/*.dart"
  - "test/**/*.dart"
---

# General Project Rules

## Core Principles

- Write concise, technical code with accurate examples.
- Prefer composition over inheritance.
- Use functional and declarative patterns when they improve clarity.
- Use clear naming (`isLoading`, `hasError`, `canRetry`).
- Keep source files organized and easy to scan.
- Keep identifiers in English.

## Documentation and Comments

- Do not generate documentation files unless explicitly requested.
- Do not add comments that only restate obvious code.
- Explain intent, trade-offs, constraints, and non-obvious behavior.
- Keep comments and docs in sync with implementation.
- Keep user-facing text localizable when applicable.

## Clean Code Rules

- Avoid magic numbers; use named constants.
- Extract repeated UI and logic patterns into reusable components.
- Keep functions focused and single-purpose.
- Prefer explicit, typed contracts over loose dynamic structures.

## Error and Lint Policy

- Do not suppress diagnostics without a clear reason.
- Keep suppression scope minimal and documented.
- Follow the dedicated error handling rule file for allowed suppressions.

## Implementation Checklist

- [ ] Names are clear and intent-driven.
- [ ] Duplication was reduced where practical.
- [ ] Comments explain the why, not the what.
- [ ] Constants replace unexplained literals.
- [ ] No unnecessary suppressions were introduced.
