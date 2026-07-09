use crate::engine::wide_text::wide_text_to_utf8_bytes;
use crate::error::{OdbcError, Result};
use crate::protocol::{cell_bytes_from_slice, CellBytes, OdbcType};
use odbc_api::{CursorRow, Nullable};

#[derive(Default)]
pub struct CellReader {
    wide_buf: Vec<u16>,
    binary_buf: Vec<u8>,
}

impl CellReader {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn read_cell_bytes(
        &mut self,
        row: &mut CursorRow<'_>,
        column_number: u16,
        odbc_type: OdbcType,
    ) -> Result<Option<CellBytes>> {
        match odbc_type {
            OdbcType::Binary => self.read_binary(row, column_number),
            OdbcType::Integer => self.read_i32_as_le_bytes(row, column_number),
            OdbcType::BigInt => self.read_i64_as_le_bytes(row, column_number),
            _ => self.read_text(row, column_number),
        }
    }

    /// Read a text cell as UTF-8 bytes, regardless of the column's underlying
    /// SQL type or the driver's locale.
    ///
    /// ## Why we go through `get_wide_text`
    ///
    /// `odbc_api::CursorRow::get_text` issues `SQLGetData(SQL_C_CHAR)`, which
    /// asks the ODBC driver to deliver the value transcoded to the **client's
    /// ANSI code page**. For a US/Western Windows host this is CP1252; for a
    /// Linux box it depends on `LANG`. Any character that does not fit the
    /// destination code page is silently replaced by `?` (or, with some
    /// drivers, by a Latin-1-looking byte sequence — the `"¹ÜÀíÔ±"` mojibake
    /// reported in [issue #1](
    /// https://github.com/cesar-carlos/dart_odbc_fast/issues/1)).
    ///
    /// `get_wide_text` issues `SQLGetData(SQL_C_WCHAR)` instead, which is
    /// guaranteed by the spec to deliver UTF-16 LE — the same encoding SQL
    /// Server uses internally for `NVARCHAR`. We then transcode the UTF-16
    /// code units to UTF-8 via [`crate::engine::wide_text`], which keeps the
    /// `from_utf16_lossy` U+FFFD contract for unpaired surrogates while
    /// short-circuiting ASCII-only cells.
    ///
    /// This means **every** text-shaped column (`VARCHAR`, `NVARCHAR`,
    /// `CHAR`, `NCHAR`, `TEXT`, `NTEXT`, `WLONGVARCHAR`, dates and numerics
    /// returned as text, etc.) round-trips Unicode correctly without
    /// requiring connection-string tweaks like `CodePage=936` or driver-
    /// specific options. The cost is a single per-cell UTF-16 → UTF-8 pass;
    /// negligible compared with the ODBC fetch itself.
    fn read_text(
        &mut self,
        row: &mut CursorRow<'_>,
        column_number: u16,
    ) -> Result<Option<CellBytes>> {
        self.read_wide_text(row, column_number)
            .map(|value| value.map(wide_text_to_utf8_bytes))
    }

    /// Reads a binary cell. The internal buffer is reused across calls so the
    /// driver appends into already-allocated capacity; only the produced
    /// `Vec<u8>` returned to the caller is freshly allocated (and sized to
    /// the exact cell length to avoid wasting RAM in long result sets).
    fn read_binary(
        &mut self,
        row: &mut CursorRow<'_>,
        column_number: u16,
    ) -> Result<Option<CellBytes>> {
        self.binary_buf.clear();
        let has_value = row
            .get_binary(column_number, &mut self.binary_buf)
            .map_err(OdbcError::from)?;

        if has_value {
            // Tightly-sized copy so each cell only owns its own bytes; the
            // shared `binary_buf` keeps its capacity for the next cell.
            Ok(Some(self.binary_buf.as_slice().into()))
        } else {
            Ok(None)
        }
    }

    /// Fetches the cell directly as `SQL_C_SLONG` (driver-side conversion).
    ///
    /// Replaces the previous path of `SQLGetData(SQL_C_WCHAR)` → `String::from_utf16_lossy`
    /// → `trim().parse::<i32>()` (5 allocations + 2 transcodings per cell)
    /// with a single fixed-size FFI fetch into a stack-allocated `Nullable<i32>`.
    /// `Integer` columns originate from `SQL_INTEGER` / `SQL_SMALLINT` /
    /// `SQL_TINYINT` / `SQL_BIT`, all losslessly convertible to `i32` by the
    /// driver. Drivers that surface dynamically-typed values (e.g. SQLite
    /// affinity) under an `Integer` label will surface a clear conversion
    /// error here instead of silently round-tripping the value as raw text.
    fn read_i32_as_le_bytes(
        &mut self,
        row: &mut CursorRow<'_>,
        column_number: u16,
    ) -> Result<Option<CellBytes>> {
        let mut target: Nullable<i32> = Nullable::null();
        row.get_data(column_number, &mut target)
            .map_err(OdbcError::from)?;
        match target.into_opt() {
            None => Ok(None),
            Some(value) => Ok(Some(cell_bytes_from_slice(&value.to_le_bytes()))),
        }
    }

    /// Fetches the cell directly as `SQL_C_SBIGINT`. See [`Self::read_i32_as_le_bytes`]
    /// for the rationale on bypassing the wide-text conversion path.
    fn read_i64_as_le_bytes(
        &mut self,
        row: &mut CursorRow<'_>,
        column_number: u16,
    ) -> Result<Option<CellBytes>> {
        let mut target: Nullable<i64> = Nullable::null();
        row.get_data(column_number, &mut target)
            .map_err(OdbcError::from)?;
        match target.into_opt() {
            None => Ok(None),
            Some(value) => Ok(Some(cell_bytes_from_slice(&value.to_le_bytes()))),
        }
    }

    fn read_wide_text(
        &mut self,
        row: &mut CursorRow<'_>,
        column_number: u16,
    ) -> Result<Option<&[u16]>> {
        self.wide_buf.clear();
        let has_value = row
            .get_wide_text(column_number, &mut self.wide_buf)
            .map_err(OdbcError::from)?;

        if has_value {
            Ok(Some(&self.wide_buf))
        } else {
            Ok(None)
        }
    }
}

pub fn read_cell_bytes(
    row: &mut CursorRow<'_>,
    column_number: u16,
    odbc_type: OdbcType,
) -> Result<Option<CellBytes>> {
    CellReader::new().read_cell_bytes(row, column_number, odbc_type)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(feature = "test-helpers")]
    use crate::engine::{execute_query_with_cached_connection, OdbcConnection, OdbcEnvironment};
    #[cfg(feature = "test-helpers")]
    use crate::test_helpers::load_dotenv;

    #[test]
    fn wide_text_to_utf8_bytes_ascii() {
        assert_eq!(wide_text_to_utf8_bytes(&[0x48, 0x69]).as_slice(), b"Hi");
    }

    #[test]
    fn wide_text_to_utf8_bytes_cjk_round_trips_utf8() {
        let wide: Vec<u16> = "你好".encode_utf16().collect();
        assert_eq!(wide_text_to_utf8_bytes(&wide).as_slice(), "你好".as_bytes());
    }

    #[test]
    fn wide_text_to_utf8_bytes_unpaired_surrogate_becomes_replacement_char() {
        let out = wide_text_to_utf8_bytes(&[0xD800]);
        assert_eq!(out.as_slice(), "\u{FFFD}".as_bytes());
    }

    #[test]
    fn cell_reader_default_matches_new() {
        let a = CellReader::default();
        let b = CellReader::new();
        assert!(a.wide_buf.is_empty() && b.wide_buf.is_empty());
        assert!(a.binary_buf.is_empty() && b.binary_buf.is_empty());
    }

    #[test]
    fn wide_text_to_utf8_bytes_empty_slice_is_empty_utf8() {
        assert!(wide_text_to_utf8_bytes(&[]).is_empty());
    }

    #[cfg(feature = "test-helpers")]
    fn get_test_dsn() -> Option<String> {
        load_dotenv();
        std::env::var("ODBC_TEST_DSN")
            .ok()
            .filter(|s| !s.is_empty())
    }

    #[cfg(feature = "test-helpers")]
    fn lock_handles_for_test(
        handles: &crate::handles::SharedHandleManager,
    ) -> Result<std::sync::MutexGuard<'_, crate::handles::HandleManager>> {
        crate::error::lock_mutex(handles)
    }

    #[cfg(feature = "test-helpers")]
    fn lock_cached_connection_for_test(
        conn_arc: &std::sync::Arc<std::sync::Mutex<crate::handles::CachedConnection>>,
    ) -> Result<std::sync::MutexGuard<'_, crate::handles::CachedConnection>> {
        crate::error::lock_mutex(conn_arc)
    }

    #[test]
    #[ignore]
    #[cfg(feature = "test-helpers")]
    fn test_read_cell_bytes_integer() {
        let conn_str = get_test_dsn().expect("ODBC_TEST_DSN not set");

        let env = OdbcEnvironment::new();
        env.init().expect("Failed to initialize environment");

        let handles = env.get_handles();
        let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect");

        let handles = conn.get_handles();
        let conn_arc = {
            let handles_guard = lock_handles_for_test(&handles).expect("lock handles");
            handles_guard
                .get_connection(conn.get_connection_id())
                .expect("Failed to get ODBC connection")
        };
        let mut odbc_conn = lock_cached_connection_for_test(&conn_arc).expect("lock connection");

        let sql = "SELECT 42 AS value";
        let buffer = execute_query_with_cached_connection(&mut odbc_conn, sql)
            .expect("Failed to execute query");
        conn.disconnect().expect("Failed to disconnect");

        let decoded =
            crate::protocol::BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode");

        assert_eq!(decoded.column_count, 1);
        assert_eq!(decoded.row_count, 1);
    }

    #[test]
    #[ignore]
    #[cfg(feature = "test-helpers")]
    fn test_read_cell_bytes_text() {
        let conn_str = get_test_dsn().expect("ODBC_TEST_DSN not set");

        let env = OdbcEnvironment::new();
        env.init().expect("Failed to initialize environment");

        let handles = env.get_handles();
        let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect");

        let handles = conn.get_handles();
        let conn_arc = {
            let handles_guard = lock_handles_for_test(&handles).expect("lock handles");
            handles_guard
                .get_connection(conn.get_connection_id())
                .expect("Failed to get ODBC connection")
        };
        let mut odbc_conn = lock_cached_connection_for_test(&conn_arc).expect("lock connection");

        let sql = "SELECT 'test' AS value";
        let buffer = execute_query_with_cached_connection(&mut odbc_conn, sql)
            .expect("Failed to execute query");
        conn.disconnect().expect("Failed to disconnect");

        let decoded =
            crate::protocol::BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode");

        assert_eq!(decoded.column_count, 1);
        assert_eq!(decoded.row_count, 1);
    }

    #[test]
    #[ignore]
    #[cfg(feature = "test-helpers")]
    fn test_read_cell_bytes_null() {
        let conn_str = get_test_dsn().expect("ODBC_TEST_DSN not set");

        let env = OdbcEnvironment::new();
        env.init().expect("Failed to initialize environment");

        let handles = env.get_handles();
        let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect");

        let handles = conn.get_handles();
        let conn_arc = {
            let handles_guard = lock_handles_for_test(&handles).expect("lock handles");
            handles_guard
                .get_connection(conn.get_connection_id())
                .expect("Failed to get ODBC connection")
        };
        let mut odbc_conn = lock_cached_connection_for_test(&conn_arc).expect("lock connection");

        let sql = "SELECT NULL AS value";
        let buffer = execute_query_with_cached_connection(&mut odbc_conn, sql)
            .expect("Failed to execute query");
        conn.disconnect().expect("Failed to disconnect");

        let decoded =
            crate::protocol::BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode");

        assert_eq!(decoded.column_count, 1);
        assert_eq!(decoded.row_count, 1);
        assert_eq!(decoded.rows[0][0], None);
    }

    #[test]
    #[ignore]
    #[cfg(feature = "test-helpers")]
    fn test_read_cell_bytes_bigint() {
        let conn_str = get_test_dsn().expect("ODBC_TEST_DSN not set");

        let env = OdbcEnvironment::new();
        env.init().expect("Failed to initialize environment");

        let handles = env.get_handles();
        let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect");

        let handles = conn.get_handles();
        let conn_arc = {
            let handles_guard = lock_handles_for_test(&handles).expect("lock handles");
            handles_guard
                .get_connection(conn.get_connection_id())
                .expect("Failed to get ODBC connection")
        };
        let mut odbc_conn = lock_cached_connection_for_test(&conn_arc).expect("lock connection");

        let sql = "SELECT 9223372036854775807 AS value";
        let buffer = execute_query_with_cached_connection(&mut odbc_conn, sql)
            .expect("Failed to execute query");
        conn.disconnect().expect("Failed to disconnect");

        let decoded =
            crate::protocol::BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode");

        assert_eq!(decoded.column_count, 1);
        assert_eq!(decoded.row_count, 1);
    }
}
