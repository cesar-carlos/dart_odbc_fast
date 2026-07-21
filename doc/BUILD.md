# BUILD.md - Build and Development

Practical guide to prepare the environment, compile the Rust engine, and validate the Dart package.

## Prerequisites

### Windows

```powershell
winget install Rustlang.Rust.MSVC
winget install Google.DartSDK
```

- ODBC Driver Manager is already available on Windows.

### Linux (Ubuntu/Debian)

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
sudo apt-get update
sudo apt-get install -y dart unixodbc unixodbc-dev libclang-dev llvm
```

## Local Build (recommended flow)

From repository root:

```bash
cd native
cargo build --release
```

Expected output:

- Windows: `native/target/release/odbc_engine.dll`
- Linux: `native/target/release/libodbc_engine.so`

## Native Library Resolution Order

`library_loader.dart` attempts to load in this order:

1. `<cwd>/native/target/release/<lib>` (workspace target relative to working dir)
2. `<cwd>/native/odbc_engine/target/release/<lib>` (member-local target)
3. Same two paths repeated relative to the **package root** (found by walking up to the directory containing `pubspec.yaml`).
4. `package:odbc_fast/<lib>` (Native Assets — production download)
5. System PATH / LD_LIBRARY_PATH

Tip: `cd native && cargo build --release` writes to `native/target/release/`, which step 1 picks up automatically — no manual copy needed.

## Manual Copy (only when needed)

### Windows

```powershell
New-Item -ItemType Directory -Force -Path "native\target\release" | Out-Null
Copy-Item "native\odbc_engine\target\release\odbc_engine.dll" "native\target\release\odbc_engine.dll" -Force
```

### Linux

```bash
mkdir -p native/target/release
cp native/odbc_engine/target/release/libodbc_engine.so native/target/release/
```

## FFI Bindings (optional)

Bindings are maintained in the repository. Regenerate only when the C surface changes:

```bash
dart run ffigen -v info
```

Config file: `ffigen.yaml`

## Helper Scripts (Cross-Platform)

Python scripts are provided for common development tasks and work on Windows, Linux, and macOS:

```bash
# Build Rust + FFI bindings
python scripts/build.py

# Run all tests (build Rust first)
python scripts/test_all.py

# Run only unit tests
python scripts/test_unit.py

# Run native Rust tests
python scripts/test_native.py

# Validate everything
python scripts/validate_all.py

# Quick artifact check
python scripts/validate_all.py --artifacts-only
```

For detailed usage and all available scripts, see [scripts/README.md](../scripts/README.md).

## Tests

```bash
dart test
```

CI and opt-in scopes, live/stress/perf flags, and coverage policy:
**[`TESTING.md`](TESTING.md)** (canonical). Short local suites:

```bash
dart test test/domain/
dart test test/infrastructure/native/
dart test test/documentation test/example
```

## Related Documentation

- Documentation index: [README.md](README.md)
- Dart architecture: [ARCHITECTURE.md](ARCHITECTURE.md)
- FFI surface and public API: [API_SURFACE.md](API_SURFACE.md)
- Driver capabilities and engine matrix: [CAPABILITIES_v3.md](CAPABILITIES_v3.md)
- Test policy, CI scope, coverage: [TESTING.md](TESTING.md)
- Performance defaults and open work: [PERFORMANCE.md](PERFORMANCE.md)
- Docker E2E stack: [development/docker-test-stack.md](development/docker-test-stack.md)
- Release/tag/workflow issues: [RELEASE_AUTOMATION.md](version/RELEASE_AUTOMATION.md)
- Versioning policy: [VERSIONING_STRATEGY.md](version/VERSIONING_STRATEGY.md)
- Quick version bump decisions: [VERSIONING_QUICK_REFERENCE.md](version/VERSIONING_QUICK_REFERENCE.md)
- Changelog entry template: [CHANGELOG_TEMPLATE.md](version/CHANGELOG_TEMPLATE.md)
- Data type mapping contract: [TYPE_MAPPING.md](notes/TYPE_MAPPING.md)
- Pending / deferred work: [Features/PENDING_IMPLEMENTATIONS.md](Features/PENDING_IMPLEMENTATIONS.md)

## Validation and error guidance

Recent runtime validations are fail-fast and happen before payload emission:

- `BulkInsertBuilder.addRow()` validates:
  - row length vs column count
  - nullability (`nullable: false` rejects `null`)
  - type per column (`i32`, `i64`, `text`, `decimal`, `binary`, `timestamp`)
  - text `maxLen` for both character count and UTF-8 byte length
- `paramValuesFromObjects()` validates:
  - `double.nan` and infinities are rejected for decimal mapping
  - `DateTime.year` must be in `[1, 9999]`

Typical failures:

- `StateError`: invalid null in non-nullable bulk column
- `ArgumentError`: incompatible type/range/length in bulk or parameter mapping
