# CLAUDE.md

Project memory for `dart_odbc_fast`.

- Use the modular rules in `.claude/rules/` as the source of coding guardrails.
- Keep project-specific decisions in dedicated rule files inside `.claude/rules/` using `paths` when scoping is needed.
- Keep rule content aligned with `.cursor/rules/` when updating shared guidance.
- Apply both Dart/Flutter and Rust-native rules depending on the touched area.
- Never suppress diagnostics/errors unless explicitly allowed in `.claude/rules/error_handling.md`.

