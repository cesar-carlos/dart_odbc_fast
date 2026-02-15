# VERSIONING_STRATEGY.md - Versioning Strategy

## Objective

Define a single policy for package versions, tags, and breaking-change communication.

## Current state

- Current package version: `0.3.1`
- Phase: pre-1.0.0 (API still evolving)

## Main rule (pre-1.0.0)

For `0.x.y`:

- Public API breaking change: bump **MINOR** (`0.3.1` -> `0.4.0`)
- Backward-compatible feature: bump **PATCH** (`0.3.1` -> `0.3.2`)
- Bug fix/performance/docs: bump **PATCH**

## Rule after 1.0.0

For `x.y.z`:

- Breaking change: **MAJOR**
- Backward-compatible feature: **MINOR**
- Bug fix/performance/docs: **PATCH**

## What counts as breaking

1. Removing public method/class/enum
2. Renaming public API
3. Changing public return type
4. Adding required parameter
5. Removing existing parameter
6. Contract behavior change without fallback

## What does not count as breaking

1. Adding new method
2. Adding optional parameter with default value
3. Internal improvements without signature/contract changes
4. Error/log/performance improvements without external functional changes

## Deprecation policy

1. First release: mark as `@Deprecated` and document alternative
2. Keep for at least 2 pre-1.0.0 releases (or 2 MINOR releases after 1.0.0)
3. Remove only in a breaking release

## Tags

Format:

- Stable: `vX.Y.Z`
- Release candidate: `vX.Y.Z-rc.N`
- Beta: `vX.Y.Z-beta.N`
- Dev: `vX.Y.Z-dev.N`

## Bump checklist

1. Define change type (breaking or not)
2. Update `pubspec.yaml`
3. Update `CHANGELOG.md` with correct sections
4. Validate tests/build
5. Create tag

Operational note:

- Release workflow automatically validates:
  - tag format
  - tag consistency with `pubspec.yaml`
  - matching section in `CHANGELOG.md`

## Decision examples

### Example A - new optional parameter

Change:

```dart
Future<QueryResult> execute(String sql, {Duration? timeout});
```

Decision at `0.3.1`: `0.3.2` (PATCH).

### Example B - rename public method

Change:

- `execute` -> `executeQuery`

Decision at `0.3.2`: `0.4.0` (MINOR).

## Related documents

- [VERSIONING_QUICK_REFERENCE.md](VERSIONING_QUICK_REFERENCE.md)
- [CHANGELOG_TEMPLATE.md](CHANGELOG_TEMPLATE.md)
- [RELEASE_AUTOMATION.md](RELEASE_AUTOMATION.md)
- [CHANGELOG.md](../CHANGELOG.md)
