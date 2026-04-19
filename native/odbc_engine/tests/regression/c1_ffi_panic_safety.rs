//! C1 — Panics must not unwind across FFI boundaries.
//!
//! Validates that `ffi::guard` helpers convert any panic into a stable,
//! categorical error code rather than letting `extern "C"` unwind (which is UB).

use odbc_engine::ffi::guard::{call_id, call_int, call_int_assert_unwind_safe, call_ptr, FfiError};

#[test]
fn call_int_returns_panic_code_when_body_panics() {
    let r = call_int(|| {
        // SAFETY: simulate any unhandled panic in an FFI body.
        panic!("simulated FFI panic");
    });
    assert_eq!(r, FfiError::Panic.as_i32());
}

#[test]
fn call_int_passes_success_value() {
    let r = call_int(|| 0);
    assert_eq!(r, 0);
}

#[test]
fn call_int_passes_error_codes() {
    let r = call_int(|| FfiError::InvalidHandle.as_i32());
    assert_eq!(r, -2);
}

#[test]
fn call_int_assert_unwind_safe_with_local_state_panic() {
    use std::cell::Cell;
    let shared = Cell::new(0i32);
    let r = call_int_assert_unwind_safe(|| {
        shared.set(1);
        panic!("with shared mutable capture");
    });
    assert_eq!(r, FfiError::Panic.as_i32());
    assert_eq!(shared.get(), 1);
}

#[test]
fn call_id_returns_zero_on_panic() {
    let v: u64 = call_id(|| panic!("id panic"));
    assert_eq!(v, 0u64);
}

#[test]
fn call_ptr_returns_null_on_panic() {
    let p: *mut u8 = call_ptr(|| panic!("ptr panic"));
    assert!(p.is_null());
}
