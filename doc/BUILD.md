# BUILD.md - Build and Development

Practical guide to prepare the environment, compile the Rust engine, and validate the Dart package.

## Prerequisites

### Windows

```powershell
winget install Rustlang.Rust.MSVC
winget install Google.DartSDK
```

- Install the MSVC C++ build tools and Windows SDK required by the Rust MSVC toolchain.
- ODBC Driver Manager is available on Windows; database-specific drivers are separate.
- Python helpers require Python 3.10+. Binding generation also needs libclang.

### Linux (Ubuntu/Debian)

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
sudo apt-get update
sudo apt-get install -y build-essential pkg-config unixodbc unixodbc-dev libclang-dev llvm
```

Install the Dart SDK separately using its supported installation method; the
commands above do not configure a Dart package repository. Supported package
platforms are Windows and Linux.

## Local Build (recommended flow)

From repository root:

```bash
dart pub get
cargo build --manifest-path native/Cargo.toml --release
```

Expected output:

- Windows: `native/target/release/odbc_engine.dll`
- Linux: `native/target/release/libodbc_engine.so`

## Native Library Resolution Order

Two layers cooperate: the **build hook** (`hook/build.dart`) chooses which
binary to register as a Native Asset, and **`library_loader.dart`** loads it at
runtime.

### Runtime (library loader)

The [loader](../lib/infrastructure/native/bindings/library_loader.dart) selects:

1. Explicit file from `ODBC_FAST_NATIVE_LIBRARY` (a missing file is an error).
2. Local release or versioned cache, choosing the newer modification time
   (local wins ties); `ODBC_FAST_PREFER_LOCAL_BUILD=true` forces local preference.
3. Hook-registered Native Asset: `package:odbc_fast/<lib>`.
4. System library paths (PATH / LD_LIBRARY_PATH).

Local candidates are workspace then crate-local release directories under the
working directory, then the root found by walking up to `pubspec.yaml`.
No manual copy is needed for a normal workspace build.

### Build hook (`hook/build.dart`)

Before automatic resolution, the hook uses the configured
`native_library_directory` user define, or `ODBC_FAST_NATIVE_LIBRARY` when
available in its environment. The directory must contain the platform library.
User defines survive the SDK's hermetic hook environment. Automatic resolution:

1. Local release artifact when `ODBC_FAST_PREFER_LOCAL_BUILD=true`, or when it is
   newer than (or as new as) the versioned cache entry
2. Versioned cache: `~/.cache/odbc_fast/<version>/<os>_x64/<lib>`
3. Local release artifact (workspace then crate-local)
4. GitHub Release download for **x64** only (skipped when `CI=true`,
   `PUB_ENVIRONMENT` contains `pub.dev`, or `ODBC_FAST_SKIP_DOWNLOAD=true`);
   verifies `<lib>.sha256` when the sidecar exists

Prebuilt downloads target Windows/Linux x64. Windows/Linux arm64 requires a
matching local build; other operating systems are rejected by the resolver.

Env vars:

| Variable | Effect |
|----------|--------|
| `ODBC_FAST_NATIVE_LIBRARY` | Explicit native library file; invalid paths fail |
| `ODBC_FAST_PREFER_LOCAL_BUILD=true` | Prefer local release over cache |
| `ODBC_FAST_SKIP_DOWNLOAD=true` | Never download from GitHub Releases |

## FFI bindings

The Rust build regenerates the C header from exports and cbindgen configuration.
For the generated columnar decompression bindings, run from the repository root:

```bash
dart run tool/ffigen.dart
dart tool/check_ffi_exports.dart
```

The generator accepts an optional absolute libclang library path. It only
regenerates `columnar_decompress.g.dart`. Other binding surfaces include
handwritten code: inspect their headers and generator inputs before changing
them. The legacy `ffigen.yaml` targets `odbc_bindings.dart`; do not blindly
regenerate it over the maintained implementation.

## Helper Scripts (Cross-Platform)

Python scripts are provided for common development tasks and work on Windows, Linux, and macOS:

```bash
# Build Rust without overwriting maintained bindings
python scripts/build.py --skip-bindings

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

Use [TESTING.md](TESTING.md) for the canonical unit commands, live-test gates,
CI scopes and coverage instructions. The documentation/example checks are:

```bash
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
