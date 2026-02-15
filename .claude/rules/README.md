# Claude Rules - Usage Guide

This directory contains the rules used by Claude Code to maintain consistency and engineering quality in the project.

## Structure

```text
.claude/rules/
├── README.md
├── rules_index.md
├── general_rules.md
├── clean_architecture.md
├── solid_principles.md
├── coding_style.md
├── null_safety.md
├── testing.md
├── flutter_widgets.md
├── ui_ux_design.md
├── rust_style.md
└── error_handling.md
```

## Claude Defaults

- Rules live in `.claude/rules/*.md`
- Scope is controlled by frontmatter `paths`
- Without `paths`, the rule applies to the full project

Example:

```yaml
---
paths:
  - "lib/**/*.dart"
  - "test/**/*.dart"
---
```

## Rule Origin

- These rules were derived from `./.cursor/rules` and adapted to Claude frontmatter (`paths`).
- Core technical guidance was preserved: Clean Architecture, SOLID, style, null safety, testing, UI/UX, Rust native, and error handling.

## References

- https://docs.anthropic.com/en/docs/claude-code/memory
- https://docs.anthropic.com/en/docs/claude-code/settings
- https://doc.rust-lang.org/style-guide/
- https://rust-lang.github.io/rustfmt/
- https://doc.rust-lang.org/clippy/
- https://dart.dev/language/error-handling
- https://doc.rust-lang.org/std/error/
