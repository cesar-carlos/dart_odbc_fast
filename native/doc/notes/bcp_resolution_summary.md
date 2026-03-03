# BCP Native Implementation - Resolution Summary

**Date**: 2026-03-03  
**Feature**: 4.1 - BCP Nativo SQL Server  
**Status**: ✅ **COMPLETO**

## Executive Summary

Successfully implemented and debugged native SQL Server BCP (Bulk Copy Program) API integration, achieving **74.93x performance improvement** over standard ArrayBinding for numeric bulk inserts.

## Problem Statement

Initial implementation of native BCP resulted in:
1. `STATUS_HEAP_CORRUPTION` crashes
2. `bcp_initW` failures (rc=0)
3. Incorrect row counts (715 instead of 5000)

## Investigation Process

### Phase 1: Isolation Testing

Created progressive isolation tests to identify crash stage:
- ✅ `test_e2e_native_bcp_connect_only`: Connection setup stable
- ✅ `test_e2e_native_bcp_init_only`: Isolated `bcp_initW` behavior

### Phase 2: DLL Compatibility Discovery

**Finding**: `bcp_initW` fails with modern ODBC drivers but works with legacy driver.

| Driver              | Version | `bcp_initW` Status |
|---------------------|---------|-------------------|
| `msodbcsql18.dll`   | 18.x    | ❌ Fails (rc=0)   |
| `msodbcsql17.dll`   | 17.x    | ❌ Fails (rc=0)   |
| `sqlncli11.dll`     | 11.0    | ✅ Works          |

**Root Cause**: Modern Microsoft ODBC drivers have a bug or intentional incompatibility with the legacy BCP API.

**Solution**: Prioritize `sqlncli11.dll` in library loading order.

### Phase 3: `bcp_collen` State Persistence Bug

**Finding**: Only 715 out of 5000 rows inserted correctly despite all `bcp_sendrow` calls succeeding.

**Root Cause**: `bcp_collen` sets column length for **all subsequent rows** until called again.

Incorrect pattern:
```rust
// ❌ Only call bcp_collen for null rows
if is_null(row) {
    bcp_collen(hdbc, SQL_NULL_DATA, col_idx);
}
bcp_sendrow(hdbc); // Non-null rows after null still use SQL_NULL_DATA!
```

**Solution**: Call `bcp_collen` for **every row**:
```rust
// ✅ Call bcp_collen for every row
let collen = if is_null(row) {
    SQL_NULL_DATA
} else {
    std::mem::size_of::<T>() as i32
};
bcp_collen(hdbc, collen, col_idx);
bcp_sendrow(hdbc);
```

## Implementation Changes

### File: `src/engine/core/sqlserver_bcp.rs`

1. **DLL Priority**:
   ```rust
   const CANDIDATE_LIBRARIES: &[&str] = &["sqlncli11.dll", "msodbcsql17.dll", "msodbcsql18.dll"];
   ```

2. **New Method**: `row_collen_for_bcp`
   - Returns correct length for every row (not just nulls)
   - Replaces `row_collen_override` which only returned `Some` for nulls

3. **Row Processing Loop**:
   - Now calls `bcp_collen` for **every column in every row**
   - Ensures correct length state for each `bcp_sendrow` call

### File: `tests/e2e_bcp_native_numeric_test.rs`

1. **New Tests**:
   - `test_e2e_native_bcp_numeric_nullable`: 5000 rows with nulls ✅
   - `test_e2e_native_bcp_i32_only_non_null`: 1000 rows without nulls ✅
   - `test_e2e_native_bcp_i32_zero_rows`: Edge case with 0 rows ✅
   - `test_benchmark_native_vs_fallback`: Performance comparison ✅

2. **Isolation Tests** (marked `#[ignore]` for diagnostics):
   - `test_e2e_native_bcp_connect_only`
   - `test_e2e_native_bcp_init_only`

## Performance Results

### Benchmark: 50,000 rows (I32 + I64, non-nullable)

| Method        | Time    | Throughput   | Speedup |
|---------------|---------|--------------|---------|
| Native BCP    | 69.54ms | 719,050 r/s  | 74.93x  |
| ArrayBinding  | 5.21s   | 9,596 r/s    | 1.00x   |

**Conclusion**: Native BCP achieves **~75x speedup**, far exceeding the 2-5x target.

## Current Limitations

1. **DLL Dependency**: Requires `sqlncli11.dll` (SQL Server Native Client 11.0)
   - Modern drivers (`msodbcsql17/18`) not compatible
   - Fallback to ArrayBinding if `sqlncli11.dll` unavailable

2. **Type Support**: Currently only numeric types (`I32`, `I64`)
   - `Text` and `Binary` types fall back to ArrayBinding
   - Future work: Add text/binary support to native path

3. **Runtime Guardrail**: Disabled by default
   - Enable with `ODBC_ENABLE_UNSTABLE_NATIVE_BCP=1`
   - Ensures stability until production validation complete

## Testing Status

All tests passing:
- ✅ Unit tests: `build_bound_columns` with nullable columns
- ✅ E2E tests: Native BCP with various scenarios
- ✅ E2E tests: Fallback path (ArrayBinding)
- ✅ Benchmark test: Performance comparison
- ✅ Clippy: No warnings
- ✅ Dart analyzer: No issues

## Documentation

Created/Updated:
1. `native/doc/bcp_dll_compatibility.md`: Technical details and solutions
2. `native/doc/notes/action_plan.md`: Progress tracking and discoveries
3. `src/engine/core/sqlserver_bcp.rs`: Module-level documentation
4. This summary document

## Next Steps

1. **Production Validation**:
   - Test with real-world SQL Server workloads
   - Monitor for edge cases and errors
   - Collect performance metrics

2. **Feature Enhancement** (optional):
   - Add `Text`/`Binary` type support to native path
   - Investigate `msodbcsql17/18` compatibility (report to Microsoft?)

3. **Guardrail Removal** (future):
   - After production validation, consider enabling native BCP by default
   - Keep fallback mechanism for robustness

## Lessons Learned

1. **DLL Compatibility**: Modern drivers don't always maintain backward compatibility with legacy APIs
2. **State Persistence**: FFI functions may have hidden state that persists across calls
3. **Isolation Testing**: Progressive isolation tests are invaluable for debugging complex FFI issues
4. **Documentation**: Official API docs may not cover all edge cases or compatibility issues

## References

- [bcp_init - Microsoft Docs](https://learn.microsoft.com/en-us/sql/relational-databases/native-client-odbc-extensions-bulk-copy-functions/bcp-init)
- [bcp_collen - Microsoft Docs](https://learn.microsoft.com/en-us/sql/relational-databases/native-client-odbc-extensions-bulk-copy-functions/bcp-collen)
- [bcp_sendrow - Microsoft Docs](https://learn.microsoft.com/en-us/sql/relational-databases/native-client-odbc-extensions-bulk-copy-functions/bcp-sendrow)
- [SQL Server Native Client](https://learn.microsoft.com/en-us/sql/relational-databases/native-client/sql-server-native-client)
