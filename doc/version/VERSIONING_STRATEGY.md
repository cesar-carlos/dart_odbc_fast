# VERSIONING_STRATEGY.md - Versioning Strategy

## Objective

Define the canonical policy for package versions, tags, and breaking-change communication.

## Current phase

- This project is post-`1.0.0` and follows stable SemVer.
- Current package version must be read from `pubspec.yaml`.

## Canonical SemVer rule (post-1.0.0)

For `x.y.z`:

- Public API breaking change: bump **MAJOR** (`1.1.0` -> `2.0.0`)
- Backward-compatible feature: bump **MINOR** (`1.1.0` -> `1.2.0`)
- Bug fix/performance/docs/internal refactor: bump **PATCH** (`1.1.0` -> `1.1.1`)

## Legacy rule (pre-1.0.0)

For `0.x.y`:

- Breaking change: **MINOR**
- Backward-compatible feature: **PATCH**
- Bug fix/performance/docs: **PATCH**

## What counts as breaking

1. Removing public method/class/enum
2. Renaming public API
3. Changing public return type
4. Adding required parameter
5. Removing existing parameter
6. Contract behavior change without fallback/migration path

## What does not count as breaking

1. Adding new method
2. Adding optional parameter with default value
3. Internal improvements without signature/contract changes
4. Error/log/performance improvements without external functional changes

## Deprecation policy

1. First release: mark as `@Deprecated` and document alternative
2. Keep for at least 2 MINOR releases
3. Remove only in a breaking release

## Tags

Format:

- Stable: `vX.Y.Z`
- Release candidate: `vX.Y.Z-rc.N`
- Beta: `vX.Y.Z-beta.N`
- Dev: `vX.Y.Z-dev.N`

## Release bump checklist

1. Define change type (breaking, feature, patch)
2. Update `pubspec.yaml`
3. Update `CHANGELOG.md` with `## [X.Y.Z] - YYYY-MM-DD`
4. Validate tests/build
5. Create and push tag

Operational note:

- Release workflow automatically validates:
  - tag format
  - tag consistency with `pubspec.yaml`
  - matching section in `CHANGELOG.md`

## Related documents

- [VERSIONING_QUICK_REFERENCE.md](VERSIONING_QUICK_REFERENCE.md)
- [CHANGELOG_TEMPLATE.md](CHANGELOG_TEMPLATE.md)
- [RELEASE_AUTOMATION.md](RELEASE_AUTOMATION.md)
- [CHANGELOG.md](../../CHANGELOG.md)
