# Native Rust Tests

This folder contains integration tests for the native Rust ODBC engine.

## Test Summary

Tests cover the main areas of the crate:

- **FFI layer** (C ABI surface for Dart/Flutter)
- **Engine** (connection, execution, streaming, batch, pooling, transactions)
- **Protocol** (encode/decode, compression, columnar)
- **Errors** (typed + structured errors)
- **Observability / security / versioning**

## Test Categories

### FFI Tests (`ffi::tests` in `src/ffi/mod.rs`)
These tests validate the C FFI layer that Dart uses to communicate with the Rust engine. They test:

- **Buffer management**: Pre-allocated buffer APIs
- **Error handling**: Error message retrieval and structured errors
- **Parameter validation**: Null pointer checks, buffer sizes
- **Lifecycle**: Init, connect, disconnect flow
- **Query execution**: Basic query API validation
- **Streaming**: Streaming query lifecycle

**Key characteristics:**
- Tests use the same buffer-based API that Dart FFI uses
- Validates pointer safety and buffer boundaries
- Ensures error messages are correctly propagated
- Tests edge cases (null pointers, invalid IDs, buffer overflows)

### Error Handling Tests (`error::tests` in `src/error/mod.rs`)
Tests for the error handling system:

- Error variant creation and formatting
- Structured error serialization/deserialization
- Unicode message handling
- Roundtrip encoding/decoding
- Error properties extraction

### Protocol Tests (`protocol::*::tests`)
Tests for the binary protocol implementation:

- **Types**: ODBC type conversions, SQL type mapping
- **Encoder**: Binary buffer encoding, metadata serialization
- Magic number and version validation
- Null value handling
- Multi-column/row support

### Security Tests (`security::*::tests`)
Tests for security-related modules:

- **secure_buffer**: Buffer creation and manipulation, zeroization on drop (ZeroizeOnDrop), Unicode and binary data, memory safety
- **audit**: AuditLogger enabled/disabled, log_connection/log_query/log_error, event cap (10000), get_events
- **secret_manager**: Secret and SecretManager store/retrieve/remove/clear, missing-key error

### Version Tests (`versioning::protocol_version::tests`)
Tests for protocol version management:

- Version compatibility checks
- Breaking change detection
- Version ordering and comparison
- Display formatting

## Running Tests

### From project root:
```powershell
# Run native tests (debug build)
.\scripts\test_native.ps1

# Run with release build
.\scripts\test_native.ps1 -Release
```

### From `native/odbc_engine`:

```powershell
# All tests
cargo test --all-targets

# Only FFI unit tests (fast)
cargo test --lib ffi::tests

# With output
cargo test --all-targets -- --nocapture
```

### Lib unit tests that require ODBC (when DSN is set)

Some unit tests inside `src/` are marked `#[ignore]` because they need a real ODBC connection (e.g. `handles::tests::test_handle_manager_create_connection`, `engine::cell_reader::tests::*`). To run them when `ODBC_TEST_DSN` is available (in env or in `.env` at project root):

```powershell
# From native/ (workspace root)
cargo test -p odbc_engine --lib -- --ignored

# From native/odbc_engine
cargo test --lib -- --ignored
```

These tests call `test_helpers::load_dotenv()` (or a local `get_test_dsn()`) so `.env` is loaded before reading `ODBC_TEST_DSN`. Without DSN they are skipped by default (not run unless `--ignored` is used).

## Integration Tests (files in this folder)

Integration tests in `.rs` files here test higher-level scenarios:

- `abi_test.rs`: ABI version compatibility
- `phase1X_test.rs`: Phase-specific feature tests
- `integration_test.rs`: End-to-end connection tests (requires real ODBC DSN)
- `e2e_*.rs`: End-to-end tests for specific features (connection, execution, streaming, pooling)
- `e2e_bulk_transaction_stress_test.rs`: E2E stress with massive insert/update/delete under explicit transaction control (commit and rollback)

**Note:** Tests that require a real database **self-skip** when a DSN is not
configured or when E2E is disabled (so local runs/CI can stay green without DB).

## Multi-Database Testing Architecture

The test suite supports running E2E tests against multiple database systems (SQL Server, Sybase, PostgreSQL, MySQL, Oracle) through a unified architecture.

**Key Features:**
- **Automatic database detection** from connection string
- **Conditional test skipping** for database-specific tests
- **SQL compatibility** prioritizing ANSI SQL standards
- **yesple configuration** via `.env` file in project root

**Database type validation (helpers in `helpers::e2e`):**

| Helper | Usage |
|--------|-------|
| `detect_database_type(conn_str)` | Infers `DatabaseType` (SqlServer, Sybase, PostgreSQL, MySQL, Oracle, Unknown) from the connection string. |
| `is_database_type(expected: DatabaseType)` | Returns `true` only when the connected database (via `ODBC_TEST_DSN` / `get_sqlserver_test_dsn()`) matches the expected type. Otherwise prints `"[WARN] Skipping test: requires X, but connected to Y"` and returns `false`. Use this at the start of database-specific tests (for example: `if !is_database_type(DatabaseType::SqlServer) { return; }`). |
| `get_connection_and_db_type()` | Returns `Option<(String, DatabaseType)>` (connection string + detected type). Useful to adapt DDL/SQL per database (for example: `e2e_bulk_operations_test`). |

Example in a SQL Server-specific test:

```rust
use helpers::{is_database_type, should_run_e2e_tests, DatabaseType};
// ...
if !should_run_e2e_tests() { return; }
if !is_database_type(DatabaseType::SqlServer) { return; }
```

**Quick Start:**
1. Configure your database connection in `.env`:
   ```ini
   ODBC_TEST_DSN=Driver={SQL Anywhere 16};Host=localhost;Port=2650;ServerName=VL;DatabaseName=VL;UID=dba;PWD=sql;
   ```

2. Run tests:
   ```powershell
   cd native\odbc_engine
   cargo test
   ```

3. Tests automatically:
   - Detect the database type from connection string
   - Skip database-specific tests when not applicable
   - Run generic tests on any configured database

**For complete documentation, see [MULTI_DATABASE_TESTING.md](MULTI_DATABASE_TESTING.md)**

**DSN / `.env` configuration:** see [E2E_TESTS_ENV_CONFIG.md](../E2E_TESTS_ENV_CONFIG.md)

## Test Strategy

1. **FFI Layer** (in `src/ffi/mod.rs`)
   - Fast unit tests
   - No external dependencies
   - Validates C API contract
   - **Run these first** to catch API issues early

2. **Integration Tests** (in `tests/*.rs`)
   - Slower, require setup
   - Test real ODBC connections
   - Validate end-to-end scenarios
   - Run after FFI tests pass

## CI/CD

In CI pipelines:
1. Always run FFI tests (fast, no setup)
2. Optionally run integration tests if DSN configured
3. FFI tests catch most API contract issues before Dart tests

## Adding New Tests

### For FFI functions:
Add tests to `src/ffi/mod.rs` in the `#[cfg(test)] mod tests` block:

```rust
#[test]
fn test_my_ffi_function() {
    odbc_init();
    
    let result = my_ffi_function(...);
    
    assert_eq!(result, expected);
}
```

### For integration scenarios:
Create a new file in `tests/` folder:

```rust
// tests/my_integration_test.rs
use odbc_engine::*;

#[test]
#[ignore] // If requires DSN
fn test_my_scenario() {
    // ...
}
```

## Code Coverage

To generate coverage (HTML + LCOV) with [cargo-tarpaulin](https://github.com/xd009642/tarpaulin):

```powershell
.\scripts\run_coverage.ps1
```

Requires `cargo install cargo-tarpaulin`. Output: `native/coverage/tarpaulin-report.html`, `native/coverage/lcov.info`.

The heuristic/estimator (no DB, fast) is available as:

```powershell
.\scripts\analyze_coverage.ps1
```

## Debugging

To see detailed output:
```bash
cargo test --lib ffi::tests -- --nocapture
```

To run with logging:
```bash
RUST_LOG=debug cargo test --lib ffi::tests
```
