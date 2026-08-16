//! Best-effort string `SQLGetInfo` probes for live DBMS identification.
//!
//! `odbc-api` 20 exposes `SQL_DBMS_NAME` and identifier-length helpers, but
//! not `SQL_DRIVER_NAME` / `SQL_DRIVER_VER`. This module issues those calls
//! through the connection handle with a small unsafe boundary.
//!
//! `odbc-sys` 0.28's [`InfoType`] enum omits codes 6 and 7, and constructing
//! an invalid enum variant panics in debug builds, so `SQLGetInfo` is invoked
//! with a `u16` info-type via an ABI-compatible function pointer.

use odbc_api::handles::{slice_to_utf8, SqlChar};
use odbc_api::sys::{HDbc, InfoType, Pointer, SmallInt, SqlReturn};
use odbc_api::{handles, Connection};
use std::mem::{size_of, size_of_val};

/// ODBC `SQL_DRIVER_NAME` — omitted from `odbc-sys` 0.28 `InfoType`.
const SQL_DRIVER_NAME: u16 = 6;
/// ODBC `SQL_DRIVER_VER` — omitted from `odbc-sys` 0.28 `InfoType`.
const SQL_DRIVER_VER: u16 = 7;

#[cfg(not(windows))]
use odbc_api::sys::SQLGetInfo as sql_get_info;
#[cfg(windows)]
use odbc_api::sys::SQLGetInfoW as sql_get_info;

type SqlGetInfoU16 = unsafe extern "system" fn(
    connection_handle: HDbc,
    info_type: u16,
    info_value_ptr: Pointer,
    buffer_length: SmallInt,
    string_length_ptr: *mut SmallInt,
) -> SqlReturn;

/// `SQL_DRIVER_NAME` (best-effort). Empty / driver failure → `None`.
pub(crate) fn driver_name(conn: &Connection<'static>) -> Option<String> {
    get_info_string(conn, SQL_DRIVER_NAME)
}

/// `SQL_DRIVER_VER` (best-effort). Empty / driver failure → `None`.
pub(crate) fn driver_ver(conn: &Connection<'static>) -> Option<String> {
    get_info_string(conn, SQL_DRIVER_VER)
}

/// `SQL_DBMS_VER` (best-effort). Empty / driver failure → `None`.
pub(crate) fn dbms_ver(conn: &Connection<'static>) -> Option<String> {
    get_info_string(conn, InfoType::DbmsVer as u16)
}

fn connection_hdbc(conn: &Connection<'static>) -> HDbc {
    // SAFETY: `odbc_api::Connection` is a single-field wrapper around
    // `handles::Connection` stored at offset 0 (same size and alignment), so
    // this matches `handles::Connection::as_sys()`.
    let inner: &handles::Connection<'_> = unsafe { &*std::ptr::from_ref(conn).cast() };
    inner.as_sys()
}

fn get_info_string(conn: &Connection<'static>, info_type: u16) -> Option<String> {
    let hdbc = connection_hdbc(conn);
    let mut buf: Vec<SqlChar> = vec![0; 256];
    let mut string_length_in_bytes: i16 = 0;
    // SAFETY: `hdbc` is the live connection handle; `buf`/`out_len` are valid
    // for the duration of the call.
    let rc = unsafe { call_sql_get_info(hdbc, info_type, &mut buf, &mut string_length_in_bytes) };
    if rc != SqlReturn::SUCCESS && rc != SqlReturn::SUCCESS_WITH_INFO {
        return None;
    }

    let needed = usize::try_from(string_length_in_bytes).unwrap_or(0);
    if size_of_val(buf.as_slice()) <= needed {
        let char_len = needed / size_of::<SqlChar>() + 2;
        buf.resize(char_len, 0);
        string_length_in_bytes = 0;
        // SAFETY: same as the first call; buffer was resized to fit `needed`.
        let rc =
            unsafe { call_sql_get_info(hdbc, info_type, &mut buf, &mut string_length_in_bytes) };
        if rc != SqlReturn::SUCCESS && rc != SqlReturn::SUCCESS_WITH_INFO {
            return None;
        }
    }

    decode_info_string(&buf, string_length_in_bytes)
}

fn decode_info_string(buf: &[SqlChar], string_length_in_bytes: i16) -> Option<String> {
    let char_count = usize::try_from(string_length_in_bytes).unwrap_or(0) / size_of::<SqlChar>();
    let char_count = char_count.min(buf.len());
    let decoded = slice_to_utf8(&buf[..char_count]).ok()?;
    let trimmed = decoded.trim_end_matches('\0').trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

/// # Safety
///
/// `hdbc` must be a valid allocated connection handle. `buf` and `out_len`
/// must be writable for the duration of the call.
unsafe fn call_sql_get_info(
    hdbc: HDbc,
    info_type: u16,
    buf: &mut [SqlChar],
    out_len: &mut i16,
) -> SqlReturn {
    let buffer_length = i16::try_from(size_of_val(buf)).unwrap_or(i16::MAX);
    // SAFETY: `InfoType` is `#[repr(u16)]`, so `SQLGetInfo`'s second argument
    // has the same ABI as `u16`. We pass the raw ODBC info-type code without
    // constructing an `InfoType` variant (codes 6/7 are missing from odbc-sys).
    // Function items are zero-sized, so go through a thin pointer first.
    let sql_get_info_u16: SqlGetInfoU16 = unsafe { std::mem::transmute(sql_get_info as *const ()) };
    // SAFETY: caller guarantees a valid HDBC and writable buffers; length is
    // the byte size of `buf` as required by `SQLGetInfo`.
    unsafe {
        sql_get_info_u16(
            hdbc,
            info_type,
            buf.as_mut_ptr().cast::<std::ffi::c_void>(),
            buffer_length,
            out_len,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ascii_sql_chars(s: &str) -> Vec<SqlChar> {
        s.bytes().map(|b| b as SqlChar).collect()
    }

    fn ascii_byte_len(chars: &[SqlChar]) -> i16 {
        i16::try_from(chars.len() * size_of::<SqlChar>()).expect("test buffer fits i16")
    }

    #[test]
    fn odbc_info_type_codes_match_spec() {
        assert_eq!(SQL_DRIVER_NAME, 6);
        assert_eq!(SQL_DRIVER_VER, 7);
        assert_eq!(InfoType::DbmsVer as u16, 18);
    }

    #[test]
    fn decode_info_string_trims_and_rejects_blank() {
        let name = ascii_sql_chars("PostgreSQL");
        assert_eq!(
            decode_info_string(&name, ascii_byte_len(&name)).as_deref(),
            Some("PostgreSQL")
        );

        let padded = ascii_sql_chars("  16.1  ");
        assert_eq!(
            decode_info_string(&padded, ascii_byte_len(&padded)).as_deref(),
            Some("16.1")
        );

        let blank = ascii_sql_chars("   ");
        assert_eq!(decode_info_string(&blank, ascii_byte_len(&blank)), None);
        assert_eq!(decode_info_string(&[], 0), None);
        assert_eq!(decode_info_string(&name, -1), None);
    }

    #[test]
    fn decode_info_string_caps_length_to_buffer() {
        let buf = ascii_sql_chars("AB");
        let overstated = ascii_byte_len(&buf).saturating_add(64);
        assert_eq!(decode_info_string(&buf, overstated).as_deref(), Some("AB"));
    }
}
