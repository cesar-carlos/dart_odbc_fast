# RELEASE_AUTOMATION.md - Release Process

This project uses `.github/workflows/release.yml` to generate native binaries when a `v*` tag is pushed.

Version-bump policy is canonical in `VERSIONING_STRATEGY.md`. This document focuses on release execution.

## Official flow

1. Update `pubspec.yaml` and `CHANGELOG.md`.
2. Run local validation.
3. Create and push tag `vX.Y.Z`.
4. Release workflow builds Linux/Windows binaries and creates GitHub Release.
5. Publish package to pub.dev.

## Workflow triggers

- `push` on tags `v*`
- `workflow_dispatch` with required `tag` input (example: `v1.1.0`)

Notes:

- For `workflow_dispatch`, provide a tag that already exists in the repository.
- Workflow validates `pubspec.yaml` and `CHANGELOG.md` against the provided tag.

## What the workflow does

### Job `verify`

- Checks out the release ref (tag) with full history
- Validates release metadata before build:
  - tag format (`vX.Y.Z` with optional `-rc.N/-beta.N/-dev.N`)
  - consistency `tag == v<pubspec.yaml version>`
  - existence of `## [X.Y.Z]` section in `CHANGELOG.md`
- Runs non-integration quality gate:
  - `cargo build --release`
  - `cargo fmt --all -- --check`
  - `dart analyze`
  - unit-only Dart tests (`test/application`, `test/domain`, `test/infrastructure`, `test/helpers/database_detection_test.dart`)
  - `cargo clippy --workspace --all-targets -- -D warnings`
  - `cargo test -p odbc_engine --lib`
- Forces `ENABLE_E2E_TESTS=0` and `RUN_SKIPPED_TESTS=0`

### Job `build-binaries`

- Depends on `verify`
- Checks out the same validated tag
- Linux build: `x86_64-unknown-linux-gnu` -> `libodbc_engine.so`
- Windows build: `x86_64-pc-windows-msvc` -> `odbc_engine.dll`
- Uploads per-platform artifacts

### Job `create-release`

- Depends on `verify` and `build-binaries`
- Checks out validated tag
- Downloads artifacts
- Validates both required files (`odbc_engine.dll`, `libodbc_engine.so`)
- Publishes release via `softprops/action-gh-release`
- Marks prerelease automatically for tags containing `-rc.`, `-beta.`, or `-dev.`

## Release checklist

1. Define target version and update `pubspec.yaml`.
2. Update `CHANGELOG.md` with section `## [X.Y.Z] - YYYY-MM-DD`.
3. Run local smoke checks.
4. `dart pub publish --dry-run`.
5. Commit release changes.
6. Create and push tag `vX.Y.Z`.
7. Verify `release.yml` succeeds.
8. Verify GitHub Release contains both artifacts.
9. Publish to pub.dev.

## Pre-release smoke

1. `dart analyze`
2. `dart test`
3. `cd native && cargo test -p odbc_engine --lib`
4. `cd native && cargo build --release --target x86_64-pc-windows-msvc`
5. `dart run example/async_demo.dart`
6. `dart run example/streaming_demo.dart`
7. `dart run example/pool_demo.dart`

Linux note on Windows host:

- `cargo build/check --target x86_64-unknown-linux-gnu` requires cross toolchain (example: `x86_64-linux-gnu-gcc`).
- If unavailable locally, use the official workflow Linux job as mandatory Linux validation.

## Commands

```bash
# commit
git add pubspec.yaml CHANGELOG.md
git commit -m "chore: release X.Y.Z"
git push origin main

# tag
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z

# publish
dart pub publish
```

PowerShell helper (repo root):

```powershell
.\scripts\create_release.ps1 1.1.0
```

This helper validates tag format, validates `pubspec.yaml` and `CHANGELOG.md`, then creates and pushes the tag.

## Common failures

### `cp: cannot stat`

Use workspace path in workflow:

`native/target/${{ matrix.target }}/release/${{ matrix.artifact }}`

### `Pattern 'uploads/*' does not match any files`

Ensure `download-artifact` has:

- `pattern: '*'`
- `merge-multiple: true`

### `403` while creating release

Verify workflow permission:

```yaml
permissions:
  contents: write
```

## Rollback

If an incorrect tag was published:

```bash
git tag -d vX.Y.Z
git push origin :refs/tags/vX.Y.Z
```

Then publish a corrected version.
