# SQL Server BCP DLL Compatibility

## Summary

Native SQL Server BCP (Bulk Copy Program) API has compatibility issues with modern ODBC drivers. This document details the investigation and solutions.

## Problem

When implementing native BCP using `bcp_initW`, `bcp_bind`, `bcp_sendrow`, and `bcp_done` functions, we encountered:

1. **`STATUS_HEAP_CORRUPTION`** crashes during execution
2. **`bcp_initW` returning 0 (failure)** with modern ODBC drivers
3. **Incorrect row counts** (e.g., 715 rows inserted instead of 5000)

## Root Causes

### Issue 1: Modern ODBC Driver Incompatibility

**Symptom**: `bcp_initW` returns 0 (failure) even when:
- Table exists and is accessible
- Connection is BCP-enabled (`SQL_COPT_SS_BCP` set before connect)
- All parameters are valid

**Affected Drivers**:
- ❌ `msodbcsql18.dll` (Microsoft ODBC Driver 18 for SQL Server)
- ❌ `msodbcsql17.dll` (Microsoft ODBC Driver 17 for SQL Server)
- ✅ `sqlncli11.dll` (SQL Server Native Client 11.0) - **WORKS**

**Solution**: Prioritize `sqlncli11.dll` in `CANDIDATE_LIBRARIES` array:

```rust
const CANDIDATE_LIBRARIES: &[&str] = &["sqlncli11.dll", "msodbcsql17.dll", "msodbcsql18.dll"];
```

### Issue 2: `bcp_collen` State Persistence

**Symptom**: Only a fraction of rows are inserted correctly (e.g., 715 out of 5000).

**Root Cause**: `bcp_collen` sets the column length for **all subsequent `bcp_sendrow` calls** until called again. When handling nullable columns:

```rust
// ❌ WRONG: Only call bcp_collen for null rows
for row in rows {
    if is_null(row) {
        bcp_collen(hdbc, SQL_NULL_DATA, col_idx); // Sets length to NULL
    }
    // Non-null rows still use SQL_NULL_DATA from previous call!
    bcp_sendrow(hdbc);
}
```

This causes non-null rows after a null row to be treated as NULL.

**Solution**: Call `bcp_collen` for **every row** with the correct length:

```rust
// ✅ CORRECT: Call bcp_collen for every row
for row in rows {
    let collen = if is_null(row) {
        SQL_NULL_DATA
    } else {
        std::mem::size_of::<i32>() as i32
    };
    bcp_collen(hdbc, collen, col_idx);
    bcp_sendrow(hdbc);
}
```

## Implementation

### DLL Priority Order

```rust
const CANDIDATE_LIBRARIES: &[&str] = &["sqlncli11.dll", "msodbcsql17.dll", "msodbcsql18.dll"];
```

### bcp_collen for Nullable Columns

```rust
fn row_collen_for_bcp(&self, row_idx: usize) -> i32 {
    match self {
        BoundColumnRef::I32 { null_bitmap, .. } => {
            if null_bitmap.is_some_and(|bm| is_null(bm, row_idx)) {
                SQL_NULL_DATA
            } else {
                std::mem::size_of::<i32>() as i32
            }
        }
        BoundColumnRef::I64 { null_bitmap, .. } => {
            if null_bitmap.is_some_and(|bm| is_null(bm, row_idx)) {
                SQL_NULL_DATA
            } else {
                std::mem::size_of::<i64>() as i32
            }
        }
    }
}
```

### Row Processing Loop

```rust
for row_idx in 0..row_count {
    for (idx, col) in bound_columns.iter_mut().enumerate() {
        col.write_row(row_idx);
        let collen = col.row_collen_for_bcp(row_idx);
        let collen_rc = unsafe {
            bcp_collen(dbc_handle, collen, (idx + 1) as i32)
        };
        if collen_rc == 0 {
            return Err(OdbcError::InternalError(format!(
                "bcp_collen failed at row {} column {}",
                row_idx, idx + 1
            )));
        }
    }
    let send_rc = unsafe { bcp_sendrow(dbc_handle) };
    if send_rc == 0 {
        return Err(OdbcError::InternalError(format!(
            "bcp_sendrow failed at row {}",
            row_idx
        )));
    }
}
```

## Testing

### E2E Tests

All tests in `tests/e2e_bcp_native_numeric_test.rs` pass with `sqlncli11.dll`:

- ✅ `test_e2e_native_bcp_numeric_nullable`: 5000 rows with `I32` + `I64` (nulls via bitmap)
- ✅ `test_e2e_native_bcp_i32_only_non_null`: 1000 rows with `I32` (no nulls)
- ✅ `test_e2e_native_bcp_i32_zero_rows`: 0 rows (edge case)

### Isolation Tests

Diagnostic tests (marked `#[ignore]`) for debugging:

- `test_e2e_native_bcp_connect_only`: Verifies BCP-enabled connection setup
- `test_e2e_native_bcp_init_only`: Verifies `bcp_initW` call and cleanup

## Limitations

### Current Scope

- ✅ Numeric types: `I32`, `I64`
- ✅ Nullable columns via `null_bitmap`
- ❌ Text/Binary types: Not yet implemented in native path (fallback to ArrayBinding)

### Runtime Guardrail

Native BCP is **disabled by default** due to:
- DLL compatibility issues
- Limited type support
- Need for production validation

Enable with environment variable:

```bash
export ODBC_ENABLE_UNSTABLE_NATIVE_BCP=1
```

## References

- [bcp_init - Microsoft Docs](https://learn.microsoft.com/en-us/sql/relational-databases/native-client-odbc-extensions-bulk-copy-functions/bcp-init)
- [bcp_collen - Microsoft Docs](https://learn.microsoft.com/en-us/sql/relational-databases/native-client-odbc-extensions-bulk-copy-functions/bcp-collen)
- [bcp_sendrow - Microsoft Docs](https://learn.microsoft.com/en-us/sql/relational-databases/native-client-odbc-extensions-bulk-copy-functions/bcp-sendrow)

## Performance

Benchmark numbers are maintained in a single source of truth:

- `native/doc/performance_comparison.md` (section **BCP (Bulk Copy)**)

This avoids drift between compatibility guidance and benchmark snapshots.

## Future Work

1. Investigate `msodbcsql17/18` compatibility (report issue to Microsoft?)
2. Add `Text` and `Binary` type support to native path
3. Validate performance with nullable columns and larger datasets
4. Consider removing runtime guardrail after production validation
