# Contributing Guidelines

This document describes how to properly contribute to `dart_odbc_fast` development.

## Development Workflow

We maintain two parallel workflows:

1. **`doc/issues/`** - Planning documentation (Portuguese, internal)
   - Used for brainstorming, organizing, and tracking development tasks
   - Updated frequently during implementation
   - **Source of truth** for what needs to be done

2. **GitHub Issues** - Execution tracking (English, public)
   - Used for public issue tracking, discussions, and PR management
   - Created from `doc/issues/` entries when implementation begins
   - Follows market-standard practices (mssql, node-postgres, etc.)

## Workflow Steps

### For Implementing New Features

1. **Plan in `doc/issues/`**
   - Create/update the relevant issue file (connections.md, requests.md, etc.)
   - Define clear acceptance criteria
   - Mark as **Fase 0**, **Fase 1**, or **Fase 2**
   - Define scope as **Core** or **Plugin**

2. **Create GitHub Issue**
   - Use `.github/ISSUE_TEMPLATE.md`
   - Reference the `doc/issues/` file
   - Add proper labels: `phase-X`, `core`/`plugin`, `enhancement`/`bug`
   - Set appropriate priority: `P0`, `P1`, or `P2`

3. **Implement**
   - Follow Clean Architecture principles
   - Write tests for new functionality
   - Update related `doc/issues/` file with implementation notes

4. **Update `doc/issues/`**
   - Add "Implementation complete" section at the end
   - Document any deviations from original plan
   - Link to the GitHub issue and PR

5. **Create PR**
   - Reference the GitHub issue in title/description
   - Include tests in the PR
   - Ensure all existing tests pass
   - Update ROADMAP.md if needed

### For Bug Fixes

Same as feature implementation, but:

- Type: `Bug`
- Priority: `P0` or `P1` depending on severity
- Include regression tests

### For Documentation Updates

1. Update the relevant `.md` files directly
2. No need for GitHub issue unless major restructuring

## Issue Lifecycle

```
doc/issues/api/X.md (Plan)
        ↓
[Create GitHub Issue] (Track)
        ↓
[Implementation] (Code + Tests)
        ↓
[Update doc/issues/] (Document completion)
        ↓
[Create PR] (Merge to main/master)
        ↓
[Close GitHub Issue] (Archive)
```

## Code Standards

Follow project rules defined in `.cursor/rules/`:

- **Clean Architecture**: Maintain layer separation
- **General Rules**: Code conciseness, no magic numbers, self-documenting
- **Coding Style**: Dart 2026 conventions with modern features

## Testing Standards

- Write unit tests for all new functionality
- Write integration tests for database operations
- Use descriptive test names following the pattern: `test_<feature>_<scenario>`
- Include edge cases and error conditions
- Maintain test coverage above 80%

## Documentation Standards

When updating `doc/issues/` files:

- Keep descriptions concise and focused
- Use clear acceptance criteria
- Reference similar packages (mssql, node-postgres) for context
- Mark items as completed when done
- Add "Implementation Notes" section for technical decisions

---

**Last updated**: 2026-02-11
