# Cursor Rules - Usage Guide

This directory contains the rules used by Cursor to keep consistency and engineering quality across the project.

## Structure

```text
.cursor/rules/
├── README.md
├── rules_index.mdc
├── general_rules.mdc
├── clean_architecture.mdc
├── solid_principles.mdc
├── coding_style.mdc
├── null_safety.mdc
├── testing.mdc
├── flutter_widgets.mdc
├── ui_ux_design.mdc
├── rust_style.mdc
└── error_handling.mdc
```

## Cursor Defaults

- Rules are defined in `.cursor/rules/*.mdc`
- File scope is controlled via frontmatter `globs`
- With broad globs (or no narrowing), a rule can apply to most files in the repo

Example:

```yaml
---
description: Dart application rules
globs: ["lib/**/*.dart", "test/**/*.dart"]
alwaysApply: true
---
```

## Rule Origin

- These rules are designed as reusable engineering standards.
- Topic coverage includes Clean Architecture, SOLID, style, null safety, testing, UI/UX, Rust native practices, and error handling.

## References

- https://docs.cursor.com/context/rules
- https://dart.dev/guides/language/effective-dart
- https://doc.rust-lang.org/style-guide/
- https://rust-lang.github.io/rustfmt/
- https://doc.rust-lang.org/clippy/
