# CHANGELOG_TEMPLATE.md - Changelog Template

Recommended template for `CHANGELOG.md`, based on Keep a Changelog.

## Base structure

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

## [0.3.2] - 2026-02-15

### Added

- Example item.

### Fixed

- Example item.

[0.3.2]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.3.1...v0.3.2
```

## How to write good entries

1. Describe user impact, not only internal details
2. Use affected component name in bold
3. For breaking changes, include short migration note
4. Avoid generic text like "various improvements"

## Breaking-change example

```markdown
### Breaking Changes

- **IOdbcService.execute**: renamed to `executeQuery`.
  - Migration: replace `execute(...)` calls with `executeQuery(...)`.
```

## Update flow

1. During development, add entries under `[Unreleased]`
2. At release time, create `## [X.Y.Z] - YYYY-MM-DD`
3. Move `[Unreleased]` entries into new section
4. Update comparison links at end of file

## Pre-tag checklist

- [ ] `pubspec.yaml` updated with new version
- [ ] `CHANGELOG.md` updated
- [ ] breaking changes include migration note
- [ ] comparison links updated
