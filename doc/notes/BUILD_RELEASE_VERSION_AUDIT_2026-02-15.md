# BUILD_RELEASE_VERSION_AUDIT_2026-02-15.md

Coherence and reliability audit of build/release/versioning process.

## Scope

1. Workflows: `.github/workflows/ci.yml`, `.github/workflows/release.yml`
2. Scripts: `scripts/create_release.ps1`, `scripts/build.ps1`, `scripts/build.sh`
3. Docs: `doc/BUILD.md`, `doc/RELEASE_AUTOMATION.md`, `doc/VERSIONING_STRATEGY.md`, `doc/VERSIONING_QUICK_REFERENCE.md`

## Overall conclusion

The process is now coherent and more reliable for automated releases.

## Applied adjustments

1. Hardened `release.yml`:
   - `workflow_dispatch` requires `tag` input
   - metadata validation (`tag`, `pubspec.yaml`, `CHANGELOG.md`)
   - exact ref/tag checkout across jobs
   - pre-publish quality gate (`cargo build`, `cargo fmt`, `cargo clippy`, `cargo test --lib`, `dart analyze`, unit-only `dart test`)
   - artifact presence validation before creating release
2. Reworked `scripts/create_release.ps1`:
   - removed obsolete manual release flow
   - validates tag/pubspec/changelog consistency
   - creates and pushes tag to trigger `release.yml`
3. Synced documentation with real flow:
   - `doc/RELEASE_AUTOMATION.md`
   - `doc/VERSIONING_STRATEGY.md`
   - `doc/VERSIONING_QUICK_REFERENCE.md`
4. Marked `artifacts/RELEASE_NOTES.md` as legacy (official flow uses generated release notes)
5. Aligned `ci.yml` quality gate:
   - includes `dart analyze` in addition to existing lint/build/test steps

## Residual risks (accepted)

1. Integration/e2e/stress tests remain outside CI/release by design (require real DSN/environment).
2. `scripts/build.ps1` and `scripts/build.sh` remain local convenience scripts, not release gate replacements.

## Operational recommendation

1. Use `scripts/create_release.ps1` to initiate tag-based release.
2. Treat `release.yml` as the source of truth for binary publication.
