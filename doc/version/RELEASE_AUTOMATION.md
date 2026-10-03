# RELEASE_AUTOMATION.md - Release Process

This project uses `.github/workflows/release.yml` to generate native binaries when a `v*` tag is pushed.

Version-bump policy is canonical in `VERSIONING_STRATEGY.md`. This document focuses on release execution.

## Official flow

1. Update `pubspec.yaml` and `CHANGELOG.md`.
2. Run local validation.
3. Create and push tag `vX.Y.Z`.
4. Release workflow builds Linux/Windows binaries and creates GitHub Release.
5. `publish.yml` waits for both binaries and their SHA-256 sidecars, then
   publishes stable tags to pub.dev using GitHub OIDC. Do not run a second
   manual publish while that workflow is active.

pub.dev limits `CHANGELOG.md` content to 262,144 bytes. Both metadata gates
validate `scripts/prepare_pub_changelog.py --check` before builds or asset
waiting. The publish job compacts wrapped prose only when needed; it preserves
all words, version history, fenced code and explicit Markdown line breaks.
The repository and version tag retain the original changelog formatting. If
whitespace compaction is insufficient, publication stops for editorial repair.

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
- Waits for unit tests against the built DLL on Windows
- Generates SHA-256 sidecars for both binaries
- Extracts the matching CHANGELOG section as the release body
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
9. Verify `publish.yml` succeeds and pub.dev exposes the target version.
   Prerelease tags build GitHub assets but do not trigger automatic pub.dev
   publication.

## Pre-release smoke

1. `dart analyze`
2. `dart test`
3. `cd native && cargo test -p odbc_engine --lib`
4. `cd native && cargo build --release --target x86_64-pc-windows-msvc`
5. `dart run example/quick_start_balanced_demo.dart`
6. `dart run example/streaming_demo.dart`
7. `dart run example/high_concurrency_pool_demo.dart`

Linux note on Windows host:

- `cargo build/check --target x86_64-unknown-linux-gnu` requires cross toolchain (example: `x86_64-linux-gnu-gcc`).
- If unavailable locally, use the official workflow Linux job as mandatory Linux validation.

## Commands

```bash
# commit
# Include the reviewed implementation and tests as well as release metadata.
git add -A
git commit -m "chore: release X.Y.Z"
git push origin main

# tag
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z

# Stable tag publication is automatic; inspect its completion.
gh run list --workflow publish.yml
```

Python helper (cross-platform):

```bash
python scripts/create_release.py 1.1.0
```

This helper validates tag format, validates `pubspec.yaml` and `CHANGELOG.md`, then creates and pushes the tag.

If asset waiting times out while `release.yml` is still building, first verify
the release workflow and all four required assets, then rerun the failed
tag-triggered publish run. A new `workflow_dispatch` run is not a substitute:
pub.dev OIDC requires a tag ref. Do not move or recreate a published version tag.

For a package-content rejection after a GitHub Release already exists, keep the
tag immutable. A validated export of that tag may be prepared for manual
publication by an authorized uploader, with only the required packaging changes.
If the package disables manual publication, enabling it requires the
maintainer's authorization; restore that restriction after the upload.

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
