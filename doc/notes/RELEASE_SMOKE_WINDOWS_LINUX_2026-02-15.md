# RELEASE_SMOKE_WINDOWS_LINUX_2026-02-15.md

Release smoke execution record used to close item 4.3 in the performance/reliability plan.

## Date

- 2026-02-15

## Local environment

- Host: Windows (x64)
- Workspace: `d:\Developer\dart_odbc_fast`

## Local checks executed

1. `dart analyze`
   - Result: OK (`No issues found`)
2. `dart test`
   - Result: OK (`All tests passed`)
3. `cargo test -p odbc_engine --lib` (in `native/`)
   - Result: OK (`610 passed; 0 failed; 16 ignored`)
4. `cargo build --release --target x86_64-pc-windows-msvc` (in `native/`)
   - Result: OK
   - Artifact: `native/target/x86_64-pc-windows-msvc/release/odbc_engine.dll`
5. Manual examples execution:
   - `dart run example/async_demo.dart`
   - `dart run example/streaming_demo.dart`
   - `dart run example/pool_demo.dart`
   - Result: exit code 0 for all 3 commands

## Linux

Local attempt to validate Linux target:

- Command: `cargo check --release --target x86_64-unknown-linux-gnu`
- Result: failed on Windows host due to missing cross toolchain dependency (`x86_64-linux-gnu-gcc`).

Release decision:

1. Official Linux smoke is enforced in `.github/workflows/release.yml`, job `build-binaries` on `ubuntu-latest`.
2. Before publishing, execute release workflow (`v*` tag or `workflow_dispatch`) and validate upload of `libodbc_engine.so`.

## Exit criteria for item 4.3

- Windows local smoke: completed
- Linux smoke: covered by official release pipeline
