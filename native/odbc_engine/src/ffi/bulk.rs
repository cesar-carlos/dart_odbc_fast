// Allow FFI functions to dereference raw pointers without being marked unsafe
// This is expected and safe for extern "C" FFI boundaries
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use super::global::*;
use super::prelude::*;

use rayon::prelude::*;
use std::os::raw::{c_int, c_uint};

/// Maps a bulk-insert row count to the FFI `c_uint` out-parameter without silent truncation.
pub(crate) fn bulk_rows_inserted_for_ffi(total: usize) -> Result<c_uint> {
    u32::try_from(total).map_err(|_| {
        OdbcError::ValidationError(format!(
            "bulk insert row count {total} exceeds maximum representable value ({})",
            c_uint::MAX
        ))
    })
}

/// Bulk insert using array binding.
#[no_mangle]
pub extern "C" fn odbc_bulk_insert_array(
    conn_id: c_uint,
    _table: *const c_char,
    _columns: *const *const c_char,
    _column_count: c_uint,
    data_buffer: *const u8,
    buffer_len: c_uint,
    _row_count: c_uint,
    rows_inserted: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if data_buffer.is_null() || rows_inserted.is_null() || buffer_len == 0 {
            let Some(mut state) = try_lock_global_state() else {
                return -1;
            };
            set_error(
            &mut state,
            "odbc_bulk_insert_array: data_buffer and rows_inserted must be non-null, buffer_len > 0"
                .to_string(),
        );
            return -1;
        }

        // SAFETY: `data_buffer` is non-null and `buffer_len > 0` (validated above);
        // caller guarantees the buffer is readable for `buffer_len` bytes.
        let slice = unsafe { std::slice::from_raw_parts(data_buffer, buffer_len as usize) };
        let payload = match parse_bulk_insert_payload(slice) {
            Ok(p) => p,
            Err(e) => {
                let Some(mut state) = try_lock_global_state() else {
                    return -1;
                };
                set_error(&mut state, e.to_string());
                return -1;
            }
        };

        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };
        #[cfg(feature = "sqlserver-bcp")]
        let conn_str_owned = state.connection_strings.get(&conn_id).cloned();
        let target = match take_runnable_connection(&mut state, conn_id) {
            Ok(target) => target,
            Err(e) => {
                set_connection_structured_error(&mut state, conn_id, e.to_structured());
                return -1;
            }
        };
        let mut target_guard = RunnableTargetGuard::new(conn_id, target);
        drop(state);

        #[cfg(feature = "sqlserver-bcp")]
        let conn_str = conn_str_owned.as_deref();
        #[cfg(not(feature = "sqlserver-bcp"))]
        let conn_str: Option<&str> = None;

        let result = match target_guard.target_mut() {
            RunnableConnection::Regular(conn_arc) => {
                let conn_guard = match conn_arc.lock() {
                    Ok(g) => g,
                    Err(_) => {
                        let Some(mut state) = try_lock_global_state() else {
                            return -1;
                        };
                        set_connection_error(
                            &mut state,
                            conn_id,
                            "Failed to lock connection".to_string(),
                        );
                        return -1;
                    }
                };
                bulk_insert_payload(conn_guard.connection(), &payload, conn_str)
            }
            RunnableConnection::Pooled { pooled, .. } => match pooled.lock() {
                Ok(conn_guard) => {
                    bulk_insert_payload(conn_guard.get_connection(), &payload, conn_str)
                }
                Err(_) => Err(OdbcError::InternalError(
                    "Failed to lock pooled connection".to_string(),
                )),
            },
        };

        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };
        restore_pooled_connection(&mut state, conn_id, target_guard.take_target());

        match result {
            Ok(total) => match bulk_rows_inserted_for_ffi(total) {
                Ok(rows) => {
                    // SAFETY: `rows_inserted` is non-null (checked at function entry).
                    unsafe {
                        *rows_inserted = rows;
                    }
                    0
                }
                Err(e) => {
                    set_connection_structured_error(&mut state, conn_id, e.to_structured());
                    -1
                }
            },
            Err(e) => {
                // For bulk insert, use conn_id to store error
                set_connection_structured_error(&mut state, conn_id, e.to_structured());
                -1
            }
        }
    })
}

/// Bulk insert using BulkCopyExecutor when sqlserver-bcp is enabled, else ArrayBinding.
/// conn_str: when Some, enables native BCP attempt for SQL Server (requires pre-connect SQL_COPT_SS_BCP).
fn bulk_insert_payload(
    conn: &odbc_api::Connection<'static>,
    payload: &BulkInsertPayload,
    conn_str: Option<&str>,
) -> Result<usize> {
    #[cfg(feature = "sqlserver-bcp")]
    {
        let bcp = BulkCopyExecutor::new(1000);
        bcp.bulk_copy_from_payload(conn, payload, conn_str)
    }
    #[cfg(not(feature = "sqlserver-bcp"))]
    {
        let _ = conn_str;
        ArrayBinding::default().bulk_insert_generic(conn, payload)
    }
}

fn bulk_insert_payload_range(
    conn: &odbc_api::Connection<'static>,
    payload: &BulkInsertPayload,
    conn_str: Option<&str>,
    start: usize,
    end: usize,
) -> Result<usize> {
    #[cfg(feature = "sqlserver-bcp")]
    {
        // Native BCP currently consumes an owned BulkInsertPayload, so parallel
        // BCP keeps the chunk materialization fallback. The default array
        // binding path below uses the original payload by row range.
        let chunk = slice_payload_rows(payload, start, end)?;
        bulk_insert_payload(conn, &chunk, conn_str)
    }
    #[cfg(not(feature = "sqlserver-bcp"))]
    {
        let _ = conn_str;
        ArrayBinding::default().bulk_insert_generic_range(conn, payload, start, end)
    }
}

pub(crate) fn row_chunk_ranges(row_count: usize, parallelism: usize) -> Vec<(usize, usize)> {
    if row_count == 0 {
        return Vec::new();
    }
    let workers = parallelism.max(1).min(row_count);
    let chunk_size = row_count.div_ceil(workers).max(1);
    (0..row_count)
        .step_by(chunk_size)
        .map(|start| (start, (start + chunk_size).min(row_count)))
        .collect()
}

#[cfg(feature = "sqlserver-bcp")]
fn slice_null_bitmap(bitmap: &[u8], start: usize, len: usize) -> Vec<u8> {
    let mut out = vec![0u8; len.div_ceil(8)];
    for i in 0..len {
        if is_null(bitmap, start + i) {
            out[i / 8] |= 1u8 << (i % 8);
        }
    }
    out
}

#[cfg(feature = "sqlserver-bcp")]
pub(crate) fn slice_payload_rows(
    payload: &BulkInsertPayload,
    start: usize,
    end: usize,
) -> Result<BulkInsertPayload> {
    let total_rows = payload.row_count as usize;
    if start > end || end > total_rows {
        return Err(OdbcError::ValidationError(
            "Invalid bulk insert chunk range".to_string(),
        ));
    }
    let chunk_rows = end - start;

    let mut chunk_data = Vec::with_capacity(payload.column_data.len());
    for col in &payload.column_data {
        let sliced = match col {
            BulkColumnData::I32 {
                values,
                null_bitmap,
            } => BulkColumnData::I32 {
                values: values[start..end].to_vec(),
                null_bitmap: null_bitmap
                    .as_ref()
                    .map(|bm| slice_null_bitmap(bm, start, chunk_rows)),
            },
            BulkColumnData::I64 {
                values,
                null_bitmap,
            } => BulkColumnData::I64 {
                values: values[start..end].to_vec(),
                null_bitmap: null_bitmap
                    .as_ref()
                    .map(|bm| slice_null_bitmap(bm, start, chunk_rows)),
            },
            BulkColumnData::Text {
                rows,
                max_len,
                null_bitmap,
            } => BulkColumnData::Text {
                rows: rows[start..end].to_vec(),
                max_len: *max_len,
                null_bitmap: null_bitmap
                    .as_ref()
                    .map(|bm| slice_null_bitmap(bm, start, chunk_rows)),
            },
            BulkColumnData::Binary {
                rows,
                max_len,
                null_bitmap,
            } => BulkColumnData::Binary {
                rows: rows[start..end].to_vec(),
                max_len: *max_len,
                null_bitmap: null_bitmap
                    .as_ref()
                    .map(|bm| slice_null_bitmap(bm, start, chunk_rows)),
            },
            BulkColumnData::Timestamp {
                values,
                null_bitmap,
            } => BulkColumnData::Timestamp {
                values: values[start..end].to_vec(),
                null_bitmap: null_bitmap
                    .as_ref()
                    .map(|bm| slice_null_bitmap(bm, start, chunk_rows)),
            },
        };
        chunk_data.push(sliced);
    }

    Ok(BulkInsertPayload {
        table: payload.table.clone(),
        columns: payload.columns.clone(),
        row_count: chunk_rows as u32,
        column_data: chunk_data,
    })
}

fn bulk_insert_parallel_with_pool(
    pool: &ConnectionPool,
    payload: &BulkInsertPayload,
    parallelism: usize,
) -> Result<usize> {
    let row_count = payload.row_count as usize;
    if row_count == 0 {
        return Ok(0);
    }

    let conn_str = pool.connection_string();
    let ranges = row_chunk_ranges(row_count, parallelism);
    let results: Vec<Result<usize>> = ranges
        .into_par_iter()
        .map(|(start, end)| {
            let pooled = pool.get()?;
            let odbc_conn = pooled.get_connection();
            bulk_insert_payload_range(odbc_conn, payload, Some(conn_str), start, end)
        })
        .collect();

    let mut total = 0usize;
    let mut errors: Vec<(usize, String)> = Vec::new();
    for (chunk_idx, r) in results.into_iter().enumerate() {
        match r {
            Ok(n) => total += n,
            Err(e) => errors.push((chunk_idx, e.to_string())),
        }
    }
    if errors.is_empty() {
        Ok(total)
    } else {
        let msg = errors
            .iter()
            .map(|(idx, err)| format!("chunk[{}]: {}", idx, err))
            .collect::<Vec<_>>()
            .join("; ");
        Err(OdbcError::InternalError(format!(
            "Parallel bulk insert: {} failed chunk(s) ({} rows inserted before failure): {}",
            errors.len(),
            total,
            msg
        )))
    }
}

/// Parallel bulk insert using pool.
#[no_mangle]
pub extern "C" fn odbc_bulk_insert_parallel(
    pool_id: c_uint,
    _table: *const c_char,
    _columns: *const *const c_char,
    _column_count: c_uint,
    data_buffer: *const u8,
    buffer_len: c_uint,
    parallelism: c_uint,
    rows_inserted: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if data_buffer.is_null() || rows_inserted.is_null() || buffer_len == 0 {
            let Some(mut state) = try_lock_global_state() else {
                return -1;
            };
            set_error(
            &mut state,
            "odbc_bulk_insert_parallel: data_buffer and rows_inserted must be non-null, buffer_len > 0"
                .to_string(),
        );
            return -1;
        }

        if parallelism == 0 {
            let Some(mut state) = try_lock_global_state() else {
                return -1;
            };
            set_error(
                &mut state,
                "odbc_bulk_insert_parallel: parallelism must be >= 1".to_string(),
            );
            return -1;
        }

        // SAFETY: `data_buffer` is non-null and `buffer_len > 0` (validated above);
        // caller guarantees the buffer is readable for `buffer_len` bytes.
        let slice = unsafe { std::slice::from_raw_parts(data_buffer, buffer_len as usize) };
        let payload = match parse_bulk_insert_payload(slice) {
            Ok(p) => p,
            Err(e) => {
                let Some(mut state) = try_lock_global_state() else {
                    return -1;
                };
                set_error(&mut state, e.to_string());
                return -1;
            }
        };

        let pool = {
            let Some(mut state) = try_lock_global_state() else {
                return -1;
            };
            match state.pools.get(&pool_id) {
                Some(p) => Arc::clone(p),
                None => {
                    set_error(&mut state, format!("Invalid pool ID: {}", pool_id));
                    return -1;
                }
            }
        };

        match bulk_insert_parallel_with_pool(pool.as_ref(), &payload, parallelism as usize) {
            Ok(total) => match bulk_rows_inserted_for_ffi(total) {
                Ok(rows) => {
                    // SAFETY: `rows_inserted` is non-null (checked at function entry).
                    unsafe {
                        *rows_inserted = rows;
                    }
                    0
                }
                Err(e) => {
                    let Some(mut state) = try_lock_global_state() else {
                        return -1;
                    };
                    set_structured_error(&mut state, e.to_structured());
                    -1
                }
            },
            Err(e) => {
                let Some(mut state) = try_lock_global_state() else {
                    return -1;
                };
                set_structured_error(&mut state, e.to_structured());
                -1
            }
        }
    })
}
