# Cursor Rules - Usage Guide

This directory is the single source of truth for coding rules used by this
repository.

`rules_index.mdc` defines the categories, ownership, and file boundaries for
the rule set. Read it first.

## Rule Set

```text
.cursor/rules/
|-- README.md
|-- rules_index.mdc
|-- general_rules.mdc
|-- clean_architecture.mdc
|-- coding_style.mdc
|-- null_safety.mdc
|-- testing.mdc
|-- rust_style.mdc
|-- rust_ffi.mdc
|-- rust_cargo.mdc
|-- rust_testing.mdc
|-- sql_odbc_safety.mdc
|-- generated_artifacts.mdc
|-- error_handling.mdc
`-- project_specifics.mdc
```

## Scope of Each File

- `rules_index.mdc`: entry point, guardrails, and rule map.
- `general_rules.mdc`: cross-cutting engineering principles and refactoring
  hygiene.
- `clean_architecture.mdc`: layer boundaries and dependency direction.
- `coding_style.mdc`: Dart language, naming, imports, collections, modern
  features, logging, and tooling.
- `null_safety.mdc`: nullable contracts and safe Dart modeling patterns.
- `testing.mdc`: unit, service, integration, and E2E testing expectations.
- `rust_style.mdc`: Rust style, ownership, module design, and API shape.
- `rust_ffi.mdc`: Rust unsafe code, ABI layout, resource ownership, and FFI
  boundary safety.
- `rust_cargo.mdc`: Rust Cargo manifests, dependencies, optional dependencies,
  and feature gates.
- `rust_testing.mdc`: Rust native tooling, features, and regression testing.
- `sql_odbc_safety.mdc`: SQL construction, ODBC behavior, dialect differences,
  driver boundaries, and live database tests.
- `generated_artifacts.mdc`: generated bindings, headers, artifacts, and build
  outputs.
- `error_handling.mdc`: error propagation and suppression policy.
- `project_specifics.mdc`: `odbc_fast`-specific package, FFI, public API, and
  environment rules.

## Maintenance Rules

- Keep one concern per file. If a rule belongs to a specialized file, remove it
  from broader files instead of repeating it.
- Keep generic guidance in thematic files and repository deltas in
  `project_specifics.mdc`.
- Cross-reference related rules instead of duplicating paragraphs.
- Prefer narrow `globs` when a rule applies only to one part of the repo.
- Keep examples short, idiomatic, and aligned with the real codebase.
- Use ASCII text to avoid encoding noise in diffs and editor output.

## Cursor Defaults

- Rules are defined in `.cursor/rules/*.mdc`.
- File scope is controlled via frontmatter `globs`.
- `alwaysApply: true` should be used only when the rule is intentionally broad.

## References

- https://docs.cursor.com/context/rules
- https://dart.dev/effective-dart
- https://dart.dev/language
- https://doc.rust-lang.org/style-guide/
- https://rust-lang.github.io/api-guidelines/
- https://doc.rust-lang.org/reference/unsafe-keyword.html
- https://doc.rust-lang.org/nomicon/ffi.html
- https://doc.rust-lang.org/cargo/
