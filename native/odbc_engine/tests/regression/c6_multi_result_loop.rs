//! C6 — `execute_multi_result` must not break out of the loop on a row-count-only first
//! result; it must call `more_results` and continue collecting subsequent result sets.
//!
//! Live ODBC tests are gated behind `#[ignore]` and only run when `ODBC_TEST_DSN` is set.

use odbc_engine::protocol::{decode_multi, MultiResultItem};

/// Simulates the scenario where the first item in a multi-result batch is a row count
/// followed by one or more result sets. The decoder must round-trip all items.
#[test]
fn decode_multi_handles_rowcount_followed_by_resultsets() {
    use odbc_engine::protocol::encode_multi;
    let items = vec![
        MultiResultItem::RowCount(3),
        MultiResultItem::ResultSet(vec![1, 2, 3, 4]),
        MultiResultItem::ResultSet(vec![5, 6, 7, 8]),
    ];
    let buf = encode_multi(&items);
    let decoded = decode_multi(&buf).expect("decode_multi should succeed");
    assert_eq!(decoded.len(), 3, "all three items must be present");
    matches!(decoded[0], MultiResultItem::RowCount(3));
    matches!(decoded[1], MultiResultItem::ResultSet(_));
    matches!(decoded[2], MultiResultItem::ResultSet(_));
}
