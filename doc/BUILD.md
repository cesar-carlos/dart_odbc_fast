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

1. `native/target/release/<lib>` (workspace target)
2. `native/odbc_engine/target/release/<lib>` (member-local target)
3. `package:odbc_fast/<lib>` (Native Assets)
4. PATH/LD_LIBRARY_PATH

Tip: always using `cd native && cargo build --release` avoids manual DLL/.so copy steps.

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

## Tests

```bash
dart test
```

Useful suites:

```bash
dart test test/domain/
dart test test/infrastructure/native/
dart test test/integration/
```

CI scope (`.github/workflows/ci.yml`):

1. Runs quality gate (`cargo fmt`, `cargo clippy`, Rust build, and `dart analyze`)
2. Runs only unit test scope (`test/application`, `test/domain`, `test/infrastructure`, and `test/helpers/database_detection_test.dart`)
3. Does not run `test/integration`, `test/e2e`, `test/stress`, or `test/my_test`

Note: part of integration coverage depends on a real DSN (`ODBC_TEST_DSN`).

To include the 10 normally-skipped tests (slow, stress, native-assets):

```bash
RUN_SKIPPED_TESTS=1 dart test
```

In PowerShell: `$env:RUN_SKIPPED_TESTS='1'; dart test`. Accepted values: `1`, `true`, `yes`.

## Related Troubleshooting

- Library not found issues: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
- Release/tag/workflow issues: [RELEASE_AUTOMATION.md](RELEASE_AUTOMATION.md)
- Versioning policy: [VERSIONING_STRATEGY.md](VERSIONING_STRATEGY.md)
