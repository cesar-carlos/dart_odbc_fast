use super::super::global::*;
use super::super::global_state::{set_out_written_zero, write_ffi_output_buffer};
use crate::engine::core::prepared_cache::PreparedStatementMetrics;
use crate::engine::DbmsInfo;
use crate::ffi::guard;
use crate::plugins::capabilities::returning::DmlVerb;
use crate::plugins::capabilities::SessionOptions;

use std::os::raw::{c_char, c_int, c_uint};

/// Fixed wire size for [`odbc_get_cache_metrics`].
pub(crate) const PREPARED_CACHE_METRICS_BYTES: usize = 64;

/// Validates non-null output buffer pointers with a non-zero capacity.
pub(crate) fn require_output_buffer(
    buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> bool {
    !buffer.is_null() && !out_written.is_null() && buffer_len > 0
}

/// Validates pointers shared by dialect SQL builder entry points.
pub(crate) fn require_sql_builder_ptrs(
    conn_str: *const c_char,
    out_buf: *mut u8,
    buf_len: c_uint,
    out_written: *mut c_uint,
) -> bool {
    !conn_str.is_null() && !out_buf.is_null() && !out_written.is_null() && buf_len > 0
}

/// Validates pointers for upsert / returning builders (three NUL inputs + output).
pub(crate) fn require_dialect_sql_ptrs(
    conn_str: *const c_char,
    primary: *const c_char,
    secondary: *const c_char,
    out_buf: *mut u8,
    buf_len: c_uint,
    out_written: *mut c_uint,
) -> bool {
    !conn_str.is_null()
        && !primary.is_null()
        && !secondary.is_null()
        && !out_buf.is_null()
        && !out_written.is_null()
        && buf_len > 0
}

/// Parses a NUL-terminated UTF-8 C string from the FFI caller.
///
/// # Safety
///
/// When `ptr` is non-null, the caller must guarantee it points to a valid
/// NUL-terminated C string that remains readable for the duration of the borrow.
pub(crate) unsafe fn parse_cstr<'a>(ptr: *const c_char) -> Option<&'a str> {
    let c_str = guard::ptr_to_cstr(ptr)?;
    c_str.to_str().ok()
}

/// Like [`parse_cstr`] but zeroes `out_written` before returning `None`.
///
/// # Safety
///
/// Same obligations as [`parse_cstr`]; `out_written` may be written on failure.
pub(crate) unsafe fn parse_cstr_zero_out<'a>(
    ptr: *const c_char,
    out_written: *mut c_uint,
) -> Option<&'a str> {
    // SAFETY: Forwarded from this function's # Safety contract; ptr is a valid
    // NUL-terminated C string for the borrow.
    match unsafe { parse_cstr(ptr) } {
        Some(value) => Some(value),
        None => {
            set_out_written_zero(out_written);
            None
        }
    }
}

/// Writes UTF-8 bytes into the caller-provided output buffer.
pub(crate) fn write_utf8_output(
    bytes: &[u8],
    buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    write_ffi_output_buffer(bytes, buffer, buffer_len, out_written)
}

/// Writes a NUL-terminated UTF-8 driver name into `out_buf`.
///
/// # Safety
///
/// `out_buf` must be non-null with capacity `buffer_len > 0`.
pub(crate) unsafe fn write_null_terminated_utf8(
    name: &str,
    out_buf: *mut c_char,
    buffer_len: c_uint,
) {
    let name_bytes = name.as_bytes();
    let copy_len = (name_bytes.len() + 1).min(buffer_len as usize);
    // SAFETY: `out_buf` is non-null with `buffer_len > 0` (caller obligation);
    // `copy_len` fits within `buffer_len` and includes the NUL terminator slot.
    unsafe {
        std::ptr::copy_nonoverlapping(name_bytes.as_ptr(), out_buf as *mut u8, copy_len - 1);
        *out_buf.add(copy_len - 1) = 0;
    }
}

/// Serializes prepared-statement cache metrics into the 64-byte FFI layout.
pub(crate) fn encode_prepared_cache_metrics(metrics: &PreparedStatementMetrics) -> [u8; 64] {
    let mut payload = [0u8; PREPARED_CACHE_METRICS_BYTES];
    payload[0..8].copy_from_slice(&(metrics.cache_size as u64).to_le_bytes());
    payload[8..16].copy_from_slice(&(metrics.cache_max_size as u64).to_le_bytes());
    payload[16..24].copy_from_slice(&metrics.cache_hits.to_le_bytes());
    payload[24..32].copy_from_slice(&metrics.cache_misses.to_le_bytes());
    payload[32..40].copy_from_slice(&metrics.total_prepares.to_le_bytes());
    payload[40..48].copy_from_slice(&metrics.total_executions.to_le_bytes());
    payload[48..56].copy_from_slice(&(metrics.memory_usage_bytes as u64).to_le_bytes());
    payload[56..64].copy_from_slice(&metrics.avg_executions_per_stmt.to_le_bytes());
    payload
}

/// Copies a fixed-size metrics payload into the caller buffer.
///
/// # Safety
///
/// `buffer` and `out_written` must be non-null; `buffer_len >= 64`.
pub(crate) unsafe fn write_fixed_metrics_buffer(
    payload: &[u8; PREPARED_CACHE_METRICS_BYTES],
    buffer: *mut u8,
    out_written: *mut c_uint,
) {
    // SAFETY: caller guarantees non-null pointers and sufficient capacity.
    unsafe {
        std::ptr::copy_nonoverlapping(payload.as_ptr(), buffer, PREPARED_CACHE_METRICS_BYTES);
        *out_written = PREPARED_CACHE_METRICS_BYTES as c_uint;
    }
}

/// Introspects DBMS metadata on a runnable connection without pool bookkeeping.
/// Warms [`CachedConnection::engine_id`] so XA / transaction / plugin lookup
/// reuse the same `SQL_DBMS_NAME` cache.
pub(crate) fn detect_dbms_info_on_runnable(
    target: &RunnableConnection,
) -> std::result::Result<DbmsInfo, OdbcError> {
    target.with_cached(DbmsInfo::detect_from_cached)
}

#[derive(serde::Deserialize)]
pub(crate) struct UpsertPayload {
    pub(crate) columns: Vec<String>,
    pub(crate) conflict: Vec<String>,
    #[serde(default)]
    pub(crate) update: Option<Vec<String>>,
}

pub(crate) fn parse_upsert_payload(json: &str) -> Option<UpsertPayload> {
    serde_json::from_str(json).ok()
}

pub(crate) fn upsert_column_refs(payload: &UpsertPayload) -> (Vec<&str>, Vec<&str>) {
    let columns = payload.columns.iter().map(String::as_str).collect();
    let conflict = payload.conflict.iter().map(String::as_str).collect();
    (columns, conflict)
}

pub(crate) fn upsert_update_refs(payload: &UpsertPayload) -> Option<Vec<&str>> {
    payload
        .update
        .as_ref()
        .map(|values| values.iter().map(String::as_str).collect())
}

pub(crate) fn parse_dml_verb(verb: c_int) -> Option<DmlVerb> {
    match verb {
        0 => Some(DmlVerb::Insert),
        1 => Some(DmlVerb::Update),
        2 => Some(DmlVerb::Delete),
        _ => None,
    }
}

pub(crate) fn parse_columns_csv(columns_csv: &str) -> Vec<&str> {
    columns_csv
        .split(',')
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .collect()
}

#[derive(serde::Deserialize)]
struct SessionOptionsJson {
    #[serde(default)]
    application_name: Option<String>,
    #[serde(default)]
    timezone: Option<String>,
    #[serde(default)]
    charset: Option<String>,
    #[serde(default)]
    schema: Option<String>,
    #[serde(default)]
    extra_sql: Vec<String>,
}

/// Parses optional session-init JSON or returns defaults when absent/empty.
///
/// # Safety
///
/// When `options_json` is non-null, the caller must guarantee a valid
/// NUL-terminated C string for the duration of the call.
pub(crate) unsafe fn parse_session_options(options_json: *const c_char) -> Option<SessionOptions> {
    if options_json.is_null() {
        return Some(SessionOptions::default());
    }
    // SAFETY: Non-null options_json was checked above; caller guarantees a valid
    // NUL-terminated C string for the duration of this call.
    let json = unsafe { parse_cstr(options_json)? };
    if json.trim().is_empty() {
        return Some(SessionOptions::default());
    }
    let parsed: SessionOptionsJson = serde_json::from_str(json).ok()?;
    Some(SessionOptions {
        application_name: parsed.application_name,
        timezone: parsed.timezone,
        charset: parsed.charset,
        schema: parsed.schema,
        extra_sql: parsed.extra_sql,
    })
}
