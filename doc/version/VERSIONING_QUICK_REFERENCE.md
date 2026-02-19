# VERSIONING_QUICK_REFERENCE.md - Quick Reference

## 10-second decision

Current project phase: `>=1.0.0` (stable SemVer).

- Breaking public API change -> `MAJOR`
- Backward-compatible feature -> `MINOR`
- Fix/performance/docs/internal cleanup -> `PATCH`

Legacy (`0.x.y`) rule:

- Breaking -> `0.(x+1).0`
- Non-breaking (feature/fix/docs/perf) -> `0.x.(y+1)`

## Quick table (stable SemVer)

| Change type               | Bump  |
| ------------------------- | ----- |
| Rename/remove public API  | MAJOR |
| Change public return type | MAJOR |
| Add required parameter    | MAJOR |
| Add new public method     | MINOR |
| Add optional parameter    | MINOR |
| Bug fix                   | PATCH |
| Performance               | PATCH |
| Documentation only        | PATCH |

## Breaking checklist

Mark as breaking if any item is true:

- [ ] Removes public API
- [ ] Renames public API
- [ ] Changes public API signature/return
- [ ] Removes compatibility without migration window

## Examples

1. `execute(String sql)` -> `execute(String sql, {Duration? timeout})`
   Result: MINOR (post-1.0.0).

2. `execute(String sql)` -> `executeQuery(String sql)`
   Result: MAJOR (post-1.0.0).

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
