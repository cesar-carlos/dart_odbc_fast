//! C ABI to decompress columnar v2 block payloads (zstd / lz4) for Dart/FFI.
//! Algorithm ids match [crate::protocol::columnar::CompressionType] (`1` = zstd, `2` = lz4).

use crate::protocol::columnar::CompressionType;
use crate::protocol::compression;
use crate::{ffi::guard::FfiError, ffi_guard_int};
use std::collections::HashMap;
use std::os::raw::{c_int, c_uchar, c_uint};
use std::sync::{Mutex, OnceLock};

static DECOMPRESS_ALLOCATIONS: OnceLock<Mutex<HashMap<usize, (usize, usize)>>> = OnceLock::new();
const MAX_COLUMNAR_DECOMPRESSED_LEN: usize = 256 * 1024 * 1024;

fn decompress_allocations() -> &'static Mutex<HashMap<usize, (usize, usize)>> {
    DECOMPRESS_ALLOCATIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Decompress a single columnar column payload. On success, returns 0; `*out` points to
/// memory allocated by this library and `*out_len` / `*out_cap` are set. Call
/// [odbc_columnar_decompress_free] with the same `out`, `out_len`, and `out_cap` to release.
/// Lengths are `u32` to match a plain Dart/FFI binding without `size_t` porting.
#[no_mangle]
pub extern "C" fn odbc_columnar_decompress(
    algorithm: c_uchar,
    data: *const u8,
    data_len: c_uint,
    out_data: *mut *mut u8,
    out_len: *mut c_uint,
    out_cap: *mut c_uint,
) -> c_int {
    ffi_guard_int!({
        if data.is_null() || out_data.is_null() || out_len.is_null() || out_cap.is_null() {
            return FfiError::NullPointer.as_i32();
        }
        if data_len as u64 > usize::MAX as u64 {
            return FfiError::ResourceLimit.as_i32();
        }
        let slice = unsafe { std::slice::from_raw_parts(data, data_len as usize) };
        let ct = match CompressionType::from_u8(algorithm) {
            CompressionType::None => return FfiError::InvalidArgument.as_i32(),
            t => t,
        };
        let mut v =
            match compression::decompress_with_limit(slice, ct, MAX_COLUMNAR_DECOMPRESSED_LEN) {
                Ok(b) => b,
                Err(_) => return FfiError::InvalidArgument.as_i32(),
            };
        v.shrink_to_fit();
        let cap = v.capacity();
        let len = v.len();
        if len > c_uint::MAX as usize || cap > c_uint::MAX as usize {
            return FfiError::ResourceLimit.as_i32();
        }
        let p = v.as_mut_ptr();
        let mut allocations = match decompress_allocations().lock() {
            Ok(allocations) => allocations,
            Err(_) => return FfiError::InternalLock.as_i32(),
        };
        allocations.insert(p as usize, (len, cap));
        std::mem::forget(v);
        unsafe {
            *out_data = p;
            *out_len = len as c_uint;
            *out_cap = cap as c_uint;
        }
        0
    })
}

/// Frees a buffer returned by [odbc_columnar_decompress].
#[no_mangle]
pub extern "C" fn odbc_columnar_decompress_free(p: *mut u8, len: c_uint, cap: c_uint) {
    let _ = ffi_guard_int!({
        if p.is_null() {
            return 0;
        }
        let allocation = match decompress_allocations().lock() {
            Ok(mut allocations) => allocations.remove(&(p as usize)),
            Err(_) => None,
        };
        let (actual_len, actual_cap) = match allocation {
            Some(allocation) => allocation,
            None => return 0,
        };
        let _ = (len, cap);
        unsafe {
            let _ = Vec::from_raw_parts(p, actual_len, actual_cap);
        }
        0
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::columnar::CompressionType as Ct;
    use crate::protocol::compress;
    use std::os::raw::c_uint;

    #[test]
    fn odbc_decompress_zstd_roundtrip() {
        let raw = b"the quick brown fox jumps over the lazy dog. ".repeat(50);
        let comp = compress(&raw, Ct::Zstd).expect("compress for test");
        let mut pout: *mut u8 = std::ptr::null_mut();
        let mut olen: c_uint = 0;
        let mut ocap: c_uint = 0;
        let st = odbc_columnar_decompress(
            1u8,
            comp.as_ptr(),
            comp.len() as c_uint,
            &mut pout,
            &mut olen,
            &mut ocap,
        );
        assert_eq!(st, 0);
        assert_eq!(olen as usize, raw.len());
        let got = unsafe { std::slice::from_raw_parts(pout, olen as usize) };
        assert_eq!(got, raw.as_slice());
        odbc_columnar_decompress_free(pout, olen, ocap);
    }

    #[test]
    fn odbc_decompress_free_uses_recorded_layout() {
        let raw = b"layout safe free".repeat(20);
        let comp = compress(&raw, Ct::Zstd).expect("compress for test");
        let mut pout: *mut u8 = std::ptr::null_mut();
        let mut olen: c_uint = 0;
        let mut ocap: c_uint = 0;
        let st = odbc_columnar_decompress(
            1u8,
            comp.as_ptr(),
            comp.len() as c_uint,
            &mut pout,
            &mut olen,
            &mut ocap,
        );
        assert_eq!(st, 0);
        assert!(!pout.is_null());

        odbc_columnar_decompress_free(pout, 0, 0);
        odbc_columnar_decompress_free(pout, olen, ocap);
    }
}
