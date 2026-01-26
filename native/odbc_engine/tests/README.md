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

### Security Tests (`security::secure_buffer::tests`)
Tests for secure memory management:

- Buffer creation and manipulation
- Zeroization on drop (ZeroizeOnDrop)
- Unicode and binary data handling
- Memory safety validation

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

## Integration Tests (files in this folder)

Integration tests in `.rs` files here test higher-level scenarios:

- `abi_test.rs`: ABI version compatibility
- `phase1X_test.rs`: Phase-specific feature tests
- `integration_test.rs`: End-to-end connection tests (requires real ODBC DSN)
- `e2e_*.rs`: End-to-end tests for specific features (connection, execution, streaming, pooling)

**Note:** Tests that require a real database **self-skip** when a DSN is not
configured or when E2E is disabled (so local runs/CI can stay green without DB).

## Multi-Database Testing Architecture

The test suite supports running E2E tests against multiple database systems (SQL Server, Sybase, PostgreSQL, MySQL, Oracle) through a unified architecture.

**Key Features:**
- **Automatic database detection** from connection string
- **Conditional test skipping** for database-specific tests
- **SQL compatibility** prioritizing ANSI SQL standards
- **Simple configuration** via `.env` file in project root

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

**📖 For complete documentation, see [MULTI_DATABASE_TESTING.md](MULTI_DATABASE_TESTING.md)**

**📖 DSN / `.env` configuration:** see [E2E_TESTS_ENV_CONFIG.md](../E2E_TESTS_ENV_CONFIG.md)

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

## Debugging

To see detailed output:
```bash
cargo test --lib ffi::tests -- --nocapture
```

To run with logging:
```bash
RUST_LOG=debug cargo test --lib ffi::tests
```
