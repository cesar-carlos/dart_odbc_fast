//! Shared helpers for FFI unit tests.

use crate::ffi::prelude::*;
use crate::ffi::state;
use crate::ffi::*;
use std::ffi::CString;
use std::os::raw::{c_char, c_uint};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

pub(crate) const TEST_INVALID_ID_BASE: u32 = 0xDEAD_BEEF;

/// Invalid ID used in tests (shared). Prefer `next_test_invalid_id()` when asserting on error message to avoid conflicts under parallel test runs.
pub(crate) const TEST_INVALID_ID: u32 = TEST_INVALID_ID_BASE;

/// Returns a unique invalid ID per call.
/// Starts at BASE+1 to never collide with TEST_INVALID_ID.
/// Use in tests that assert on get_last_error() content so parallel runs
/// don't overwrite the global error with the same ID.
///
/// Tests that must see a specific `last_error` after an FFI call also use
/// `#[serial(ffi_last_error)]` so another test cannot call `set_error` in
/// between the failure and `odbc_get_error` (e.g. `odbc_bulk_insert_parallel` validation).
pub(crate) fn next_test_invalid_id() -> u32 {
    static NEXT: AtomicU32 = AtomicU32::new(TEST_INVALID_ID_BASE.wrapping_add(1));
    NEXT.fetch_add(1, Ordering::SeqCst)
}

pub(crate) fn get_last_error() -> String {
    let mut buffer = vec![0u8; 1024];
    let result = odbc_get_error(buffer.as_mut_ptr() as *mut c_char, buffer.len() as c_uint);

    if result < 0 {
        return "Failed to get error".to_string();
    }

    let len = result as usize;
    String::from_utf8_lossy(&buffer[..len]).to_string()
}

pub(crate) fn trigger_structured_cancel_unsupported_error() {
    let stmt_id = next_test_invalid_id();
    state::insert_statement(stmt_id, StatementHandle::new(1, "SELECT 1".to_string(), 0));
    let _ = odbc_cancel(stmt_id);
    let _ = state::remove_statement(stmt_id);
}

pub(crate) fn structured_error_test_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

pub(crate) fn with_structured_error_test_isolation<T>(f: impl FnOnce() -> T) -> T {
    let _guard = structured_error_test_lock()
        .lock()
        .unwrap_or_else(|e| e.into_inner());

    // Sprint 4 follow-up A2 split: snapshot/restore through the
    // dedicated legacy-error `RwLock` instead of `GlobalState`.
    let (prev_message, prev_structured) = {
        let guard = state::legacy_global_error_read().expect("legacy error lock");
        (guard.message.clone(), guard.structured.clone())
    };

    let result = f();

    if let Some(mut guard) = state::legacy_global_error_write() {
        guard.message = prev_message;
        guard.structured = prev_structured;
    }

    result
}

pub(crate) fn ffi_test_dsn() -> Option<String> {
    use std::sync::Once;
    static INIT: Once = Once::new();

    // Load .env only once. The `dotenvy` dep is optional and only
    // available behind the `test-helpers` feature; when the feature
    // is off we skip the load (env vars from the process still work).
    INIT.call_once(|| {
        #[cfg(feature = "test-helpers")]
        {
            let _ = dotenvy::dotenv();
        }
    });

    // Check whether E2E tests are enabled
    let enabled = std::env::var("ENABLE_E2E_TESTS").ok().and_then(|val| {
        let normalized = val.trim().to_lowercase();
        match normalized.as_str() {
            "1" | "true" | "yes" | "y" => Some(true),
            "0" | "false" | "no" | "n" => Some(false),
            _ => None,
        }
    }) == Some(true);

    if !enabled {
        return None;
    }

    std::env::var("ODBC_TEST_DSN")
        .ok()
        .filter(|s| !s.is_empty())
}

pub(crate) fn ffi_test_dsn_is_sql_server(dsn: &str) -> bool {
    let lower = dsn.to_lowercase();
    lower.contains("sql server")
        || lower.contains("sqlserver")
        || lower.contains("msodbcsql")
        || lower.contains("ms sql")
        || lower.contains("mssql")
}

pub(crate) fn release_pooled_connection_with_retry(pooled_id: u32) {
    for _ in 0..50 {
        if odbc_pool_release_connection(pooled_id) == 0 {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("pooled connection {pooled_id} was not released after stream close");
}

pub(crate) fn fetch_and_close_stream(stream_id: u32) {
    let mut buffer = vec![0u8; 4096];
    let mut written: c_uint = 0;
    let mut has_more: u8 = 0;
    let fetch = odbc_stream_fetch(
        stream_id,
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
        &mut has_more,
    );
    assert_eq!(fetch, 0, "pooled stream fetch should succeed");
    assert!(written > 0, "pooled stream should return data");
    let close = odbc_stream_close(stream_id);
    assert_eq!(close, 0, "pooled stream close should succeed");
}

pub(crate) fn run_pooled_stream_case<F>(pool_id: u32, start: F)
where
    F: FnOnce(u32, *const c_char) -> u32,
{
    let pooled_id = odbc_pool_get_connection(pool_id);
    assert!(pooled_id > 0, "pool checkout should succeed");
    let sql = CString::new("SELECT 1 AS n").unwrap();
    let stream_id = start(pooled_id, sql.as_ptr());
    assert!(stream_id > 0, "pooled stream start should succeed");
    fetch_and_close_stream(stream_id);
    release_pooled_connection_with_retry(pooled_id);
}
