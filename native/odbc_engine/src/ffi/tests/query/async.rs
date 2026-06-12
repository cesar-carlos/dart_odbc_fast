//! Async query FFI tests.

use crate::ffi::global::*;
use crate::ffi::*;
use std::ffi::CString;
use std::os::raw::{c_int, c_uint};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Barrier, Mutex};

use super::super::support::{next_test_invalid_id, TEST_INVALID_ID};

#[test]
fn test_ffi_execute_async_invalid_conn() {
    odbc_init();

    let sql = CString::new("SELECT 1").expect("sql");
    let request_id = odbc_execute_async(TEST_INVALID_ID, sql.as_ptr());
    assert_eq!(
        request_id, 0,
        "Invalid connection should return request_id=0"
    );
}

#[test]
fn test_ffi_execute_async_params_invalid_conn() {
    odbc_init();

    let sql = CString::new("SELECT ?").expect("sql");
    let request_id = odbc_execute_async_params(TEST_INVALID_ID, sql.as_ptr(), std::ptr::null(), 0);
    assert_eq!(
        request_id, 0,
        "Invalid connection should return request_id=0 with null params"
    );

    let params = [1u8, 2, 3, 4];
    let request_id = odbc_execute_async_params(
        TEST_INVALID_ID,
        sql.as_ptr(),
        params.as_ptr(),
        params.len() as c_uint,
    );
    assert_eq!(
        request_id, 0,
        "Invalid connection should return request_id=0 with params"
    );
}

#[test]
fn test_ffi_execute_async_params_null_inputs() {
    odbc_init();

    let request_id =
        odbc_execute_async_params(TEST_INVALID_ID, std::ptr::null(), std::ptr::null(), 0);
    assert_eq!(request_id, 0, "Null SQL should return request_id=0");

    let sql = CString::new("SELECT ?").expect("sql");
    let request_id = odbc_execute_async_params(TEST_INVALID_ID, sql.as_ptr(), std::ptr::null(), 4);
    assert_eq!(
        request_id, 0,
        "Null params pointer with positive length should fail"
    );
}

#[test]
fn test_ffi_async_poll_null_out_status() {
    let result = odbc_async_poll(1, std::ptr::null_mut());
    assert_eq!(result, -1, "Null out_status should return -1");
}

#[test]
fn test_ffi_async_poll_invalid_request_id() {
    let mut status: c_int = 0;
    let result = odbc_async_poll(TEST_INVALID_ID, &mut status);
    assert_eq!(result, -1, "Invalid request_id should return -1");
}

#[test]
fn test_ffi_async_cancel_and_free_invalid_request_id() {
    let cancel_result = odbc_async_cancel(TEST_INVALID_ID);
    assert_eq!(cancel_result, -1, "Invalid request_id should fail cancel");

    let free_result = odbc_async_free(TEST_INVALID_ID);
    assert_eq!(free_result, -1, "Invalid request_id should fail free");
}

#[test]
fn test_ffi_async_get_result_null_pointers() {
    let mut written: c_uint = 0;
    let result_null_buf = odbc_async_get_result(1, std::ptr::null_mut(), 16, &mut written);
    assert_eq!(result_null_buf, -1, "Null out_buffer should return -1");

    let mut buf = vec![0u8; 16];
    let result_null_written = odbc_async_get_result(1, buf.as_mut_ptr(), 16, std::ptr::null_mut());
    assert_eq!(result_null_written, -1, "Null out_written should return -1");
}

#[test]
fn test_ffi_async_get_result_invalid_request_id() {
    let mut written: c_uint = 0;
    let mut buf = vec![0u8; 16];
    let result = odbc_async_get_result(
        TEST_INVALID_ID,
        buf.as_mut_ptr(),
        buf.len() as c_uint,
        &mut written,
    );
    assert_eq!(result, -1, "Invalid request_id should return -1");
    assert_eq!(written, 0, "No bytes should be written on invalid request");
}

#[test]
fn test_ffi_async_get_result_retry_after_buffer_too_small_preserves_data() {
    odbc_init();

    let request_id: u32 = next_test_invalid_id();
    let payload = vec![7u8; 2048];
    let slot = Arc::new(AsyncRequestSlot {
        conn_id: 0,
        cancelled: AtomicBool::new(false),
        outcome: Mutex::new(AsyncRequestOutcome::Ready(Ok(payload.clone()))),
        join_handle: Mutex::new(None),
    });

    {
        let Some(mut async_mgr) = lock_async_requests() else {
            panic!("Failed to lock async requests");
        };
        async_mgr.requests.insert(request_id, slot);
    }

    let mut small_buf = vec![0u8; 128];
    let mut written: c_uint = 0;
    let first = odbc_async_get_result(
        request_id,
        small_buf.as_mut_ptr(),
        small_buf.len() as c_uint,
        &mut written,
    );
    assert_eq!(first, -2, "First call should report buffer too small");
    assert_eq!(written as usize, payload.len());

    let mut big_buf = vec![0u8; 4096];
    let second = odbc_async_get_result(
        request_id,
        big_buf.as_mut_ptr(),
        big_buf.len() as c_uint,
        &mut written,
    );
    assert_eq!(second, 0, "Retry with larger buffer should succeed");
    assert_eq!(written as usize, payload.len());
    assert_eq!(&big_buf[..payload.len()], payload.as_slice());
}

#[test]
fn test_ffi_async_get_result_marks_request_consumed_after_success() {
    odbc_init();

    let request_id: u32 = next_test_invalid_id();
    let payload = b"done".to_vec();
    let slot = Arc::new(AsyncRequestSlot {
        conn_id: 0,
        cancelled: AtomicBool::new(false),
        outcome: Mutex::new(AsyncRequestOutcome::Ready(Ok(payload.clone()))),
        join_handle: Mutex::new(None),
    });

    {
        let Some(mut async_mgr) = lock_async_requests() else {
            panic!("Failed to lock async requests");
        };
        async_mgr.requests.insert(request_id, slot);
    }

    let mut buf = vec![0u8; 16];
    let mut written: c_uint = 0;
    let first = odbc_async_get_result(
        request_id,
        buf.as_mut_ptr(),
        buf.len() as c_uint,
        &mut written,
    );
    assert_eq!(first, 0);
    assert_eq!(written as usize, payload.len());

    let mut status: c_int = 0;
    let poll = odbc_async_poll(request_id, &mut status);
    assert_eq!(poll, 0);
    assert_eq!(status, ASYNC_STATUS_ERROR);

    let second = odbc_async_get_result(
        request_id,
        buf.as_mut_ptr(),
        buf.len() as c_uint,
        &mut written,
    );
    assert_eq!(second, -1);
}

#[test]
fn test_async_requests_free_for_connection_removes_only_matching_slots() {
    let mut manager = AsyncRequestManager::new();
    manager.requests.insert(
        1,
        Arc::new(AsyncRequestSlot {
            conn_id: 10,
            cancelled: AtomicBool::new(false),
            outcome: Mutex::new(AsyncRequestOutcome::Pending),
            join_handle: Mutex::new(None),
        }),
    );
    manager.requests.insert(
        2,
        Arc::new(AsyncRequestSlot {
            conn_id: 20,
            cancelled: AtomicBool::new(false),
            outcome: Mutex::new(AsyncRequestOutcome::Pending),
            join_handle: Mutex::new(None),
        }),
    );

    manager.free_for_connection(10);

    assert!(!manager.requests.contains_key(&1));
    assert!(manager.requests.contains_key(&2));
}

#[test]
fn should_copy_param_buffer_for_owned_async_paths() {
    let data = [7u8, 8, 9];
    // SAFETY: `data.as_ptr()` is valid for `data.len()` bytes and the
    // helper copies the bytes immediately.
    let params = unsafe { read_param_buffer_owned(data.as_ptr(), data.len() as c_uint) }.unwrap();
    assert_eq!(params, data);
}

#[test]
fn async_requests_concurrent_init_is_lossless() {
    let base = next_test_invalid_id().wrapping_mul(1024);
    const THREADS: usize = 16;
    const INSERTS_PER_THREAD: u32 = 32;

    let barrier = Arc::new(Barrier::new(THREADS));
    let mut handles = Vec::with_capacity(THREADS);
    for t in 0..THREADS {
        let b = Arc::clone(&barrier);
        handles.push(std::thread::spawn(move || {
            b.wait();
            let conn_id = base.wrapping_add(t as u32 * 100);
            for i in 0..INSERTS_PER_THREAD {
                let request_id = base
                    .wrapping_add(t as u32 * INSERTS_PER_THREAD)
                    .wrapping_add(i);
                let slot = Arc::new(AsyncRequestSlot {
                    conn_id,
                    cancelled: AtomicBool::new(false),
                    outcome: Mutex::new(AsyncRequestOutcome::Pending),
                    join_handle: Mutex::new(None),
                });
                let mut guard = lock_async_requests()
                    .expect("async_requests mutex must be acquirable from every thread");
                guard.requests.insert(request_id, slot);
            }
        }));
    }
    for h in handles {
        h.join().expect("worker thread");
    }

    let guard = lock_async_requests().expect("async_requests still locks after the race");
    let mut observed = 0usize;
    for t in 0..THREADS {
        for i in 0..INSERTS_PER_THREAD {
            let request_id = base
                .wrapping_add(t as u32 * INSERTS_PER_THREAD)
                .wrapping_add(i);
            if guard.requests.contains_key(&request_id) {
                observed += 1;
            }
        }
    }
    assert_eq!(
        observed,
        THREADS * (INSERTS_PER_THREAD as usize),
        "every insert must be observable after the concurrent first-access race"
    );
}
