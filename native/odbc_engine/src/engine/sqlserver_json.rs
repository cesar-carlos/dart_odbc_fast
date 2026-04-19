//! SQL Server `FOR JSON` result-shape normalisation.
//!
//! ## Background
//!
//! When a query ends in `FOR JSON PATH | AUTO`, SQL Server does **not**
//! return the JSON payload as a single row containing one large value.
//! Instead, it streams the payload back in **multiple rows** of up to
//! ~2033 characters each, all under a single column whose name is the
//! reserved magic identifier
//! `JSON_F52E2B61-18A1-11D1-B105-00805F49916B`.
//!
//! Client tools (SSMS, `sqlcmd`, the .NET / JDBC drivers) hide this by
//! concatenating those rows into one logical string before exposing the
//! result to the application. A raw ODBC consumer sees the chunks as
//! independent rows and, if it only reads the first one, observes an
//! apparently truncated JSON document at the 2033-byte boundary.
//!
//! This is the root cause behind GitHub issue
//! [#2 — JSON Truncation in odbc_fast with SQL Server FOR JSON Queries](
//! https://github.com/cesar-carlos/dart_odbc_fast/issues/2). The
//! `maxResultBufferBytes` connection option had nothing to do with it:
//! the protocol buffer was perfectly capable of carrying the whole
//! payload, but only the first chunk was ever produced because the
//! caller stopped at row 0.
//!
//! ## What this module does
//!
//! [`coalesce_for_json_rows`] inspects a populated [`RowBuffer`] and, if
//! it matches the FOR JSON shape (1 column, magic name), concatenates
//! every non-NULL row's bytes into a single row containing one cell with
//! the full JSON document. The operation is a no-op for any other
//! result set.
//!
//! Apply this helper **after** all rows have been fetched but **before**
//! the buffer is encoded to the wire, in every code path that returns a
//! complete result set in one shot (non-streaming queries, multi-result
//! pieces, in-memory streaming, spill-mode streaming).
//!
//! Truly batched cursor streaming (`execute_streaming_batched`) is
//! deliberately **not** rewritten by this helper because batches arrive
//! one at a time and concatenation would defeat the streaming contract
//! — the Dart caller is responsible for joining the chunks in that
//! mode, or for switching to a non-batched API when working with
//! `FOR JSON` output.

use crate::protocol::{OdbcType, RowBuffer};

/// SQL Server's reserved column name for `FOR JSON` results.
///
/// The driver always returns this exact spelling regardless of the
/// outer `SELECT`'s syntax (PATH/AUTO, ROOT(...), WITHOUT_ARRAY_WRAPPER,
/// etc). The match is case-insensitive defensively in case a future
/// driver release lower-cases the identifier.
pub const SQLSERVER_FOR_JSON_COLUMN_NAME: &str = "JSON_F52E2B61-18A1-11D1-B105-00805F49916B";

/// Returns `true` when the buffer was produced by a SQL Server `FOR JSON`
/// query: exactly one column whose name matches
/// [`SQLSERVER_FOR_JSON_COLUMN_NAME`] (case-insensitive).
pub fn is_for_json_result(buffer: &RowBuffer) -> bool {
    buffer.column_count() == 1
        && buffer
            .columns
            .first()
            .is_some_and(|c| c.name.eq_ignore_ascii_case(SQLSERVER_FOR_JSON_COLUMN_NAME))
}

/// Concatenate every row of a `FOR JSON` result into a single row.
///
/// - No-op when the buffer does not match the FOR JSON shape.
/// - No-op when there are zero rows.
/// - When at least one chunk is non-NULL, produces a single row with one
///   non-NULL cell containing the byte-wise concatenation of every
///   non-NULL chunk in fetch order. NULL chunks are skipped (SQL Server
///   never emits them in practice, but the loop tolerates it for safety).
/// - When every chunk is NULL, collapses to a single NULL row.
///
/// The column metadata is also normalised: the type is forced to
/// [`OdbcType::Json`] so the Dart side can route the value through the
/// JSON-aware decoder regardless of how the driver labelled the column
/// (often `NVARCHAR(MAX)` / `WLONGVARCHAR`).
pub fn coalesce_for_json_rows(buffer: &mut RowBuffer) {
    if !is_for_json_result(buffer) {
        return;
    }
    if buffer.rows.is_empty() {
        return;
    }

    // Pre-compute total length so the destination buffer is sized once
    // and never reallocates while concatenating chunks.
    let total_len: usize = buffer
        .rows
        .iter()
        .filter_map(|r| r.first().and_then(|cell| cell.as_ref()).map(Vec::len))
        .sum();

    let mut all_null = true;
    let mut concatenated: Vec<u8> = Vec::with_capacity(total_len);
    for row in &buffer.rows {
        if let Some(Some(chunk)) = row.first() {
            all_null = false;
            concatenated.extend_from_slice(chunk);
        }
    }

    let merged_cell = if all_null { None } else { Some(concatenated) };
    buffer.rows = vec![vec![merged_cell]];

    if let Some(col) = buffer.columns.first_mut() {
        col.odbc_type = OdbcType::Json;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::OdbcType;

    fn make_buffer(name: &str, chunks: Vec<Option<&[u8]>>) -> RowBuffer {
        let mut buf = RowBuffer::new();
        buf.add_column(name.to_string(), OdbcType::NVarchar);
        for c in chunks {
            buf.add_row(vec![c.map(|s| s.to_vec())]);
        }
        buf
    }

    #[test]
    fn detects_canonical_for_json_column_name() {
        let buf = make_buffer(SQLSERVER_FOR_JSON_COLUMN_NAME, vec![]);
        assert!(is_for_json_result(&buf));
    }

    #[test]
    fn detection_is_case_insensitive() {
        let buf = make_buffer(
            "json_f52e2b61-18a1-11d1-b105-00805f49916b",
            vec![Some(b"[]")],
        );
        assert!(is_for_json_result(&buf));
    }

    #[test]
    fn does_not_match_other_columns() {
        let buf = make_buffer("payload", vec![Some(b"{}")]);
        assert!(!is_for_json_result(&buf));
    }

    #[test]
    fn does_not_match_when_more_than_one_column() {
        let mut buf = RowBuffer::new();
        buf.add_column(
            SQLSERVER_FOR_JSON_COLUMN_NAME.to_string(),
            OdbcType::NVarchar,
        );
        buf.add_column("extra".to_string(), OdbcType::Integer);
        assert!(!is_for_json_result(&buf));
    }

    #[test]
    fn coalesce_concatenates_multiple_chunks_in_order() {
        let mut buf = make_buffer(
            SQLSERVER_FOR_JSON_COLUMN_NAME,
            vec![
                Some(b"[{\"id\":1,"),
                Some(b"\"name\":\"a\"},"),
                Some(b"{\"id\":2,\"name\":\"b\"}]"),
            ],
        );
        coalesce_for_json_rows(&mut buf);
        assert_eq!(buf.row_count(), 1, "expected exactly one row after merge");
        assert_eq!(buf.column_count(), 1);
        let cell = buf.rows[0][0].as_ref().expect("merged cell");
        assert_eq!(
            std::str::from_utf8(cell).unwrap(),
            "[{\"id\":1,\"name\":\"a\"},{\"id\":2,\"name\":\"b\"}]"
        );
    }

    #[test]
    fn coalesce_normalises_column_type_to_json() {
        let mut buf = make_buffer(SQLSERVER_FOR_JSON_COLUMN_NAME, vec![Some(b"[]")]);
        coalesce_for_json_rows(&mut buf);
        assert_eq!(buf.columns[0].odbc_type, OdbcType::Json);
    }

    #[test]
    fn coalesce_preserves_buffer_for_non_for_json_results() {
        let mut buf = make_buffer("first_name", vec![Some(b"alice"), Some(b"bob")]);
        coalesce_for_json_rows(&mut buf);
        assert_eq!(
            buf.row_count(),
            2,
            "non FOR JSON results must not be merged"
        );
        assert_eq!(buf.columns[0].name, "first_name");
        assert_eq!(buf.columns[0].odbc_type, OdbcType::NVarchar);
    }

    #[test]
    fn coalesce_handles_empty_result() {
        let mut buf = make_buffer(SQLSERVER_FOR_JSON_COLUMN_NAME, vec![]);
        coalesce_for_json_rows(&mut buf);
        assert_eq!(buf.row_count(), 0);
        assert_eq!(buf.column_count(), 1);
    }

    #[test]
    fn coalesce_collapses_all_null_rows_to_single_null_row() {
        let mut buf = make_buffer(SQLSERVER_FOR_JSON_COLUMN_NAME, vec![None, None, None]);
        coalesce_for_json_rows(&mut buf);
        assert_eq!(buf.row_count(), 1);
        assert!(buf.rows[0][0].is_none());
    }

    #[test]
    fn coalesce_skips_null_chunks_between_real_ones() {
        let mut buf = make_buffer(
            SQLSERVER_FOR_JSON_COLUMN_NAME,
            vec![Some(b"abc"), None, Some(b"def")],
        );
        coalesce_for_json_rows(&mut buf);
        assert_eq!(buf.row_count(), 1);
        let cell = buf.rows[0][0].as_ref().expect("merged cell");
        assert_eq!(cell, b"abcdef");
    }

    /// Realistic-ish stress test: SQL Server splits FOR JSON output into
    /// chunks of up to 2033 characters. Verify we reassemble a payload
    /// that crosses dozens of chunks without losing or mangling bytes.
    #[test]
    fn coalesce_reassembles_for_json_chunks_at_2033_byte_boundary() {
        const CHUNK_BYTES: usize = 2033;
        const CHUNK_COUNT: usize = 50;

        let mut chunks_owned: Vec<Vec<u8>> = Vec::with_capacity(CHUNK_COUNT);
        for i in 0..CHUNK_COUNT {
            chunks_owned.push(vec![b'a' + (i % 26) as u8; CHUNK_BYTES]);
        }
        let chunk_refs: Vec<Option<&[u8]>> =
            chunks_owned.iter().map(|c| Some(c.as_slice())).collect();

        let mut buf = make_buffer(SQLSERVER_FOR_JSON_COLUMN_NAME, chunk_refs);
        coalesce_for_json_rows(&mut buf);

        assert_eq!(buf.row_count(), 1);
        let cell = buf.rows[0][0].as_ref().expect("merged cell");
        assert_eq!(cell.len(), CHUNK_BYTES * CHUNK_COUNT);

        // Spot-check chunk boundaries to ensure ordering was preserved.
        for i in 0..CHUNK_COUNT {
            let start = i * CHUNK_BYTES;
            let expected_byte = b'a' + (i % 26) as u8;
            assert_eq!(cell[start], expected_byte, "boundary at chunk {i}");
            assert_eq!(cell[start + CHUNK_BYTES - 1], expected_byte);
        }
    }
}
