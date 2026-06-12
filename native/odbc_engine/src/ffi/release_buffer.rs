//! Releases FFI scratch buffers allocated by Dart via `package:ffi` `malloc`.

use crate::ffi_guard_int;
use std::os::raw::{c_uint, c_void};

/// Frees a buffer previously allocated with the host C `malloc` allocator.
#[no_mangle]
pub extern "C" fn odbc_release_buffer(ptr: *mut u8, len: c_uint) {
    let _ = ffi_guard_int!({
        if ptr.is_null() {
            return 0;
        }
        let _ = len;
        // SAFETY: ownership transfers from Dart `malloc` exactly once.
        unsafe {
            libc::free(ptr.cast::<c_void>());
        }
        0
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn should_ignore_null_release_buffer_pointer() {
        odbc_release_buffer(std::ptr::null_mut(), 0);
    }

    #[test]
    fn should_release_malloc_compatible_buffer() {
        let ptr = unsafe { libc::malloc(16).cast::<u8>() };
        assert!(!ptr.is_null());
        odbc_release_buffer(ptr, 16);
    }
}
