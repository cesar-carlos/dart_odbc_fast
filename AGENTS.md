# AGENTS.md

Project memory for `dart_odbc_fast`.

This file is an index only. Do not duplicate detailed coding rules here.

## Source of truth

- All coding and engineering rules live in `.cursor/rules/`.
- Start with `.cursor/rules/rules_index.mdc` to see the available rule set,
  guardrails, and ownership map.
- Use `.cursor/rules/README.md` for directory structure and maintenance
  guidance.

## Rule map

- `.cursor/rules/general_rules.mdc`: cross-cutting engineering rules.
- `.cursor/rules/clean_architecture.mdc`: layers, boundaries, and dependency
  direction.
- `.cursor/rules/coding_style.mdc`: Dart style, naming, imports, formatting,
  logging, and language features.
- `.cursor/rules/null_safety.mdc`: nullable contracts and safe null handling.
- `.cursor/rules/testing.mdc`: unit, integration, and E2E test expectations.
- `.cursor/rules/rust_style.mdc`: Rust native style, ownership, and API design.
- `.cursor/rules/rust_ffi.mdc`: Rust unsafe, ABI, and FFI boundary safety.
- `.cursor/rules/rust_cargo.mdc`: Rust Cargo manifests, dependencies, and
  feature gates.
- `.cursor/rules/rust_testing.mdc`: Rust native tooling, features, and
  regression tests.
- `.cursor/rules/sql_odbc_safety.mdc`: SQL construction, ODBC, driver, dialect,
  and live database safety.
- `.cursor/rules/generated_artifacts.mdc`: generated bindings, headers,
  artifacts, and build outputs.
- `.cursor/rules/error_handling.mdc`: error propagation and diagnostics
  suppression policy.
- `.cursor/rules/project_specifics.mdc`: package-specific public API, FFI,
  native assets, and environment rules.

## How to apply the rules

- Apply the Dart rules when working in `lib/`, `test/`, `example/`, and other
  Dart areas.
- Apply the Rust-native rules when working in `native/` and related Rust code.
- Apply the SQL/ODBC safety rules when touching query construction, dialects,
  drivers, transactions, wire formats, or live database tests.
- Apply generated artifact rules when touching bindings, headers, exported
  symbols, cbindgen output, or build artifacts.
- Follow the error-handling policy in `.cursor/rules/error_handling.mdc`.
- Never duplicate rule content in this file; update the files in `.cursor/rules/` instead.
