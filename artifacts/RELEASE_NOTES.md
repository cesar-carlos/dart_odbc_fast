# RELEASE_NOTES.md (Legacy Manual Template)

This file is legacy.

Current flow:

1. Official release is created by `.github/workflows/release.yml`.
2. The `create-release` job uses `generate_release_notes: true`.
3. Binaries are attached automatically:
   - `odbc_engine.dll`
   - `libodbc_engine.so`

When to edit manually:

- Only if you need to replace auto-generated GitHub Release notes.
- Always align with:
  - `pubspec.yaml` (version)
  - `CHANGELOG.md`
  - `doc/RELEASE_AUTOMATION.md`
