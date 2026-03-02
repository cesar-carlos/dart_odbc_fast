//! FFI compatibility tests (Fase 0 - Plano de Implementacao)
//!
//! Cobre casos de compatibilidade FFI: ponteiros nulos, UTF-8 invalido,
//! buffers curtos, IDs invalidos. Executa sem banco de dados.
//!
//! Rodar: cargo test -p odbc_engine --features ffi-tests ffi_compatibility

use odbc_engine::{
    odbc_connect, odbc_connect_with_timeout, odbc_disconnect, odbc_get_error,
    odbc_get_structured_error, odbc_init,
};
use std::os::raw::c_char;

#[test]
fn ffi_connect_null_pointer_returns_zero() {
    let result = odbc_connect(std::ptr::null());
    assert_eq!(result, 0, "odbc_connect(NULL) must return 0");
}

#[test]
fn ffi_connect_with_timeout_null_pointer_returns_zero() {
    let result = odbc_connect_with_timeout(std::ptr::null(), 0);
    assert_eq!(
        result, 0,
        "odbc_connect_with_timeout(NULL, 0) must return 0"
    );
}

#[test]
fn ffi_connect_invalid_utf8_returns_zero() {
    odbc_init();
    let invalid_utf8: Vec<u8> = vec![0xff, 0xfe, 0x00];
    let ptr = invalid_utf8.as_ptr() as *const c_char;
    let result = odbc_connect(ptr);
    assert_eq!(result, 0, "Invalid UTF-8 conn_str must return 0");
}

#[test]
fn ffi_disconnect_invalid_conn_id_returns_nonzero() {
    let result = odbc_disconnect(0);
    assert_ne!(
        result, 0,
        "odbc_disconnect(0) must return non-zero for invalid ID"
    );
}

#[test]
fn ffi_disconnect_nonexistent_conn_id_returns_nonzero() {
    let result = odbc_disconnect(999_999);
    assert_ne!(
        result, 0,
        "odbc_disconnect(nonexistent) must return non-zero"
    );
}

#[test]
fn ffi_get_error_null_buffer_returns_negative() {
    let result = odbc_get_error(std::ptr::null_mut(), 100);
    assert_eq!(result, -1, "odbc_get_error(NULL, len) must return -1");
}

#[test]
fn ffi_get_error_zero_length_returns_negative() {
    let mut buffer = vec![0u8; 64];
    let result = odbc_get_error(buffer.as_mut_ptr() as *mut c_char, 0);
    assert_eq!(result, -1, "odbc_get_error(buf, 0) must return -1");
}

#[test]
fn ffi_get_error_valid_buffer_succeeds() {
    odbc_init();
    let mut buffer = vec![0u8; 1024];
    let result = odbc_get_error(buffer.as_mut_ptr() as *mut c_char, buffer.len() as u32);
    assert!(
        result >= 0,
        "odbc_get_error with valid buffer must not return negative"
    );
}

#[test]
fn ffi_get_structured_error_null_buffer_returns_negative() {
    let mut written: u32 = 0;
    let result = odbc_get_structured_error(std::ptr::null_mut(), 1024, &mut written);
    assert_eq!(
        result, -1,
        "odbc_get_structured_error(NULL, ...) must return -1"
    );
}

#[test]
fn ffi_get_structured_error_null_out_written_returns_negative() {
    let mut buffer = vec![0u8; 1024];
    let result = odbc_get_structured_error(
        buffer.as_mut_ptr(),
        buffer.len() as u32,
        std::ptr::null_mut(),
    );
    assert_eq!(
        result, -1,
        "odbc_get_structured_error(..., out_written=NULL) must return -1"
    );
}

#[test]
fn ffi_get_structured_error_valid_buffers_succeeds_or_no_error() {
    let mut buffer = vec![0u8; 1024];
    let mut written: u32 = 0;
    let result = odbc_get_structured_error(buffer.as_mut_ptr(), buffer.len() as u32, &mut written);
    assert!(
        result == 0 || result == 1,
        "odbc_get_structured_error must return 0 (success) or 1 (no structured error)"
    );
}

#[test]
fn ffi_init_idempotent() {
    assert_eq!(odbc_init(), 0);
    assert_eq!(odbc_init(), 0);
}

#[test]
fn ffi_id_generation_wrapping_behavior() {
    use std::sync::atomic::{AtomicU32, Ordering};

    let counter = AtomicU32::new(u32::MAX - 2);

    let id1 = counter.fetch_add(1, Ordering::SeqCst);
    assert_eq!(id1, u32::MAX - 2);

    let id2 = counter.fetch_add(1, Ordering::SeqCst);
    assert_eq!(id2, u32::MAX - 1);

    let id3 = counter.fetch_add(1, Ordering::SeqCst);
    assert_eq!(id3, u32::MAX);

    let id4 = counter.fetch_add(1, Ordering::SeqCst);
    assert_eq!(id4, 0, "Counter should wrap to 0 after u32::MAX");

    let id5 = counter.fetch_add(1, Ordering::SeqCst);
    assert_eq!(id5, 1);
}

#[test]
fn ffi_id_generation_wrapping_add_behavior() {
    let mut id = u32::MAX - 1;

    id = id.wrapping_add(1);
    assert_eq!(id, u32::MAX);

    id = id.wrapping_add(1);
    assert_eq!(id, 0, "wrapping_add should wrap to 0");

    id = id.wrapping_add(1);
    assert_eq!(id, 1);
}
