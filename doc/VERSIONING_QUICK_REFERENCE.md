# VERSIONING_QUICK_REFERENCE.md - Quick Reference

## 10-second decision

If version is `0.x.y`:

- Public API breaking change -> `0.(x+1).0`
- Non-breaking change (feature/fix/docs/perf) -> `0.x.(y+1)`

If version is `>=1.0.0`:

- Breaking -> `MAJOR`
- Backward-compatible feature -> `MINOR`
- Fix/perf/docs -> `PATCH`

Current project phase: `>=1.0.0`.

## Quick table (pre-1.0.0)

| Change type               | Bump  |
| ------------------------- | ----- |
| Rename/remove public API  | MINOR |
| Change public return type | MINOR |
| Add required parameter    | MINOR |
| Add new method            | PATCH |
| Add optional parameter    | PATCH |
| Bug fix                   | PATCH |
| Performance               | PATCH |
| Documentation             | PATCH |

## Breaking checklist

Mark as breaking if any item is true:

- [ ] Removes public API
- [ ] Renames public API
- [ ] Changes public API signature/return
- [ ] Removes compatibility without migration window

## Examples

1. `execute(String sql)` -> `execute(String sql, {Duration? timeout})`
   Result: PATCH.

2. `execute(String sql)` -> `executeQuery(String sql)`
   Result: MINOR (pre-1.0.0) / MAJOR (post-1.0.0).

## Useful commands

```bash
# current version
rg "^version:" pubspec.yaml

# create stable tag
git tag -a v1.1.0 -m "Release v1.1.0"
git push origin v1.1.0
```

PowerShell helper (validates pubspec/changelog before tagging):

```powershell
.\scripts\create_release.ps1 1.1.0
```

## References

- [VERSIONING_STRATEGY.md](VERSIONING_STRATEGY.md)
- [CHANGELOG_TEMPLATE.md](CHANGELOG_TEMPLATE.md)
