//! FFI safety guard.
//!
//! Wraps `extern "C"` function bodies in `std::panic::catch_unwind` so panics
//! never unwind across the C ABI (which is undefined behavior).
//!
//! Usage in any FFI entry point:
//!
//! ```text
//! use std::os::raw::{c_char, c_int};
//! use odbc_engine::ffi::guard::call_int;
//!
//! pub extern "C" fn odbc_some_call(_arg: *const c_char) -> c_int {
//!     call_int(|| {
//!         // return the status code the C ABI expects
//!         0
//!     })
//! }
//! ```
//!
//! Conventions for `i32`/`c_int` returns:
//! - `0`              : success
//! - negative values  : categorized errors (see `FfiError`)
//! - positive values  : domain-specific (e.g. handle ids); only when documented
//!
//! Functions returning pointers should use `call_ptr` and `null_mut()` on
//! failure; size functions should use `call_size`.

use std::os::raw::c_int;
use std::panic::{catch_unwind, AssertUnwindSafe, UnwindSafe};

/// Standard FFI error categories (negative `c_int` values returned by
/// guarded entry points).
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiError {
    /// Caller passed a null pointer where one was required.
    NullPointer = -1,
    /// Caller passed an invalid handle ID or one that has been freed.
    InvalidHandle = -2,
    /// Caller passed an invalid argument (range/size/encoding).
    InvalidArgument = -3,
    /// A panic was caught crossing the FFI boundary.
    Panic = -4,
    /// An internal poisoning/lock failure prevented the operation.
    InternalLock = -5,
    /// A driver/ODBC error occurred (use `odbc_get_error*` for details).
    OdbcError = -6,
    /// Operation timed out.
    Timeout = -7,
    /// Resource limit reached (too many handles, too large payload, etc).
    ResourceLimit = -8,
    /// Operation cancelled by caller.
    Cancelled = -9,
    /// Generic catch-all (prefer specific variants when possible).
    Generic = -100,
}

impl FfiError {
    pub const fn as_i32(self) -> i32 {
        self as i32
    }
}

/// Run an FFI body that returns `c_int` directly, catching panics.
///
/// The closure must return the value to forward to the C caller. On panic,
/// `FfiError::Panic` is returned and the panic message is logged via `log::error!`.
pub fn call_int<F>(f: F) -> c_int
where
    F: FnOnce() -> c_int + UnwindSafe,
{
    match catch_unwind(f) {
        Ok(v) => v,
        Err(payload) => {
            log_panic_payload("FFI call_int", &payload);
            FfiError::Panic.as_i32()
        }
    }
}

/// Run an FFI body that returns a pointer, catching panics.
/// On panic, returns `std::ptr::null_mut()`.
pub fn call_ptr<F, T>(f: F) -> *mut T
where
    F: FnOnce() -> *mut T + UnwindSafe,
{
    match catch_unwind(f) {
        Ok(p) => p,
        Err(payload) => {
            log_panic_payload("FFI call_ptr", &payload);
            std::ptr::null_mut()
        }
    }
}

/// Run an FFI body that returns a `usize` (e.g. byte counts), catching panics.
/// On panic returns `0`.
pub fn call_size<F>(f: F) -> usize
where
    F: FnOnce() -> usize + UnwindSafe,
{
    match catch_unwind(f) {
        Ok(v) => v,
        Err(payload) => {
            log_panic_payload("FFI call_size", &payload);
            0
        }
    }
}

/// Run an FFI body that returns `u32`/`u64` ID-like values, catching panics.
/// On panic returns `0` (which all FFI APIs treat as "invalid id").
pub fn call_id<F, U>(f: F) -> U
where
    F: FnOnce() -> U + UnwindSafe,
    U: FromZero,
{
    match catch_unwind(f) {
        Ok(v) => v,
        Err(payload) => {
            log_panic_payload("FFI call_id", &payload);
            U::ffi_zero()
        }
    }
}

/// Helper trait for "zero" sentinel of integer ID types returned by FFI.
pub trait FromZero {
    fn ffi_zero() -> Self;
}

impl FromZero for u32 {
    fn ffi_zero() -> Self {
        0
    }
}

impl FromZero for u64 {
    fn ffi_zero() -> Self {
        0
    }
}

impl FromZero for i64 {
    fn ffi_zero() -> Self {
        0
    }
}

/// Variant of `call_int` that also tolerates non-`UnwindSafe` captures by wrapping in `AssertUnwindSafe`.
///
/// Use only when the closure provably leaves shared state in a consistent state on panic
/// (typical for FFI bodies that touch their own local stack). Document why in a `// SAFETY:` comment.
pub fn call_int_assert_unwind_safe<F>(f: F) -> c_int
where
    F: FnOnce() -> c_int,
{
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(payload) => {
            log_panic_payload("FFI call_int (assert)", &payload);
            FfiError::Panic.as_i32()
        }
    }
}

/// `AssertUnwindSafe` variant of `call_id` for FFI bodies that capture
/// non-`UnwindSafe` state (e.g. `&mut` to global maps via guards) but that
/// are panic-safe in practice.
pub fn call_id_assert_unwind_safe<F, U>(f: F) -> U
where
    F: FnOnce() -> U,
    U: FromZero,
{
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(payload) => {
            log_panic_payload("FFI call_id (assert)", &payload);
            U::ffi_zero()
        }
    }
}

/// `AssertUnwindSafe` variant of `call_ptr`.
pub fn call_ptr_assert_unwind_safe<F, T>(f: F) -> *mut T
where
    F: FnOnce() -> *mut T,
{
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(p) => p,
        Err(payload) => {
            log_panic_payload("FFI call_ptr (assert)", &payload);
            std::ptr::null_mut()
        }
    }
}

fn log_panic_payload(site: &str, payload: &Box<dyn std::any::Any + Send>) {
    let msg = if let Some(s) = payload.downcast_ref::<&'static str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "<non-string panic payload>".to_string()
    };
    log::error!("{site}: panic caught crossing FFI boundary: {msg}");
}

/// Convenience macro to wrap an FFI body returning `c_int`.
///
/// Use when capturing local/non-`UnwindSafe` state is acceptable (typical for FFI bodies).
///
/// ```text
/// use std::os::raw::c_int;
/// use odbc_engine::ffi_guard_int;
///
/// pub extern "C" fn odbc_foo() -> c_int {
///     ffi_guard_int!({
///         // body
///         0
///     })
/// }
/// ```
#[macro_export]
macro_rules! ffi_guard_int {
    ($body:block) => {{
        $crate::ffi::guard::call_int_assert_unwind_safe(|| -> std::os::raw::c_int { $body })
    }};
}

/// Like `ffi_guard_int!` but for ID-like (`u32`/`u64`/`i64`) returns where `0`
/// is the standard "invalid id" sentinel.
#[macro_export]
macro_rules! ffi_guard_id {
    ($ty:ty, $body:block) => {{
        $crate::ffi::guard::call_id_assert_unwind_safe(|| -> $ty { $body })
    }};
}

/// Like `ffi_guard_int!` but for pointer returns; on panic returns `null_mut`.
#[macro_export]
macro_rules! ffi_guard_ptr {
    ($ty:ty, $body:block) => {{
        $crate::ffi::guard::call_ptr_assert_unwind_safe(|| -> *mut $ty { $body })
    }};
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn call_int_passes_through_value() {
        assert_eq!(call_int(|| 0), 0);
        assert_eq!(call_int(|| 42), 42);
        assert_eq!(call_int(|| -1), -1);
    }

    #[test]
    fn call_int_catches_panic() {
        let r = call_int(|| panic!("boom"));
        assert_eq!(r, FfiError::Panic.as_i32());
    }

    #[test]
    fn call_int_catches_string_panic() {
        let r = call_int(|| panic!("dynamic {}", 42));
        assert_eq!(r, FfiError::Panic.as_i32());
    }

    #[test]
    fn call_ptr_returns_value() {
        let p = call_ptr(|| Box::into_raw(Box::new(7i32)));
        assert!(!p.is_null());
        // SAFETY: we just constructed the box; reclaim it to avoid leak.
        let reclaimed = unsafe { Box::from_raw(p) };
        assert_eq!(*reclaimed, 7);
    }

    #[test]
    fn call_ptr_returns_null_on_panic() {
        let p: *mut u8 = call_ptr(|| panic!("ptr boom"));
        assert!(p.is_null());
    }

    #[test]
    fn call_id_returns_zero_on_panic_u32() {
        let v: u32 = call_id(|| panic!("id boom"));
        assert_eq!(v, 0);
    }

    #[test]
    fn call_id_returns_zero_on_panic_u64() {
        let v: u64 = call_id(|| panic!("id boom"));
        assert_eq!(v, 0);
    }

    #[test]
    fn call_size_returns_zero_on_panic() {
        let v = call_size(|| panic!("sz boom"));
        assert_eq!(v, 0);
    }

    #[test]
    fn call_int_assert_unwind_safe_catches_panic() {
        use std::cell::Cell;
        let counter = Cell::new(0);
        let r = call_int_assert_unwind_safe(|| {
            counter.set(counter.get() + 1);
            panic!("with shared state");
        });
        assert_eq!(r, FfiError::Panic.as_i32());
        assert_eq!(counter.get(), 1);
    }

    #[test]
    fn ffi_error_codes_are_negative() {
        assert!(FfiError::NullPointer.as_i32() < 0);
        assert!(FfiError::InvalidHandle.as_i32() < 0);
        assert!(FfiError::InvalidArgument.as_i32() < 0);
        assert!(FfiError::Panic.as_i32() < 0);
        assert!(FfiError::InternalLock.as_i32() < 0);
        assert!(FfiError::OdbcError.as_i32() < 0);
        assert!(FfiError::Timeout.as_i32() < 0);
        assert!(FfiError::ResourceLimit.as_i32() < 0);
        assert!(FfiError::Cancelled.as_i32() < 0);
        assert!(FfiError::Generic.as_i32() < 0);
    }

    #[test]
    fn ffi_error_codes_are_distinct() {
        let codes = [
            FfiError::NullPointer.as_i32(),
            FfiError::InvalidHandle.as_i32(),
            FfiError::InvalidArgument.as_i32(),
            FfiError::Panic.as_i32(),
            FfiError::InternalLock.as_i32(),
            FfiError::OdbcError.as_i32(),
            FfiError::Timeout.as_i32(),
            FfiError::ResourceLimit.as_i32(),
            FfiError::Cancelled.as_i32(),
            FfiError::Generic.as_i32(),
        ];
        let mut sorted = codes.to_vec();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), codes.len(), "FfiError codes must be unique");
    }

    #[test]
    fn from_zero_impls_return_zero() {
        assert_eq!(<u32 as FromZero>::ffi_zero(), 0u32);
        assert_eq!(<u64 as FromZero>::ffi_zero(), 0u64);
        assert_eq!(<i64 as FromZero>::ffi_zero(), 0i64);
    }
}
