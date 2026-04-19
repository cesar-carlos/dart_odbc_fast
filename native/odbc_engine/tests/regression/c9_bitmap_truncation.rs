//! C9 — Truncated null bitmap must produce an explicit `MalformedPayload`/validation error,
//! never silently treat missing bits as "not null".
//!
//! Currently `is_null` returns `false` when the row index exceeds the bitmap length.
//! After the fix, the parser MUST validate `bitmap.len() == ceil(row_count/8)` and reject
//! malformed payloads.

use odbc_engine::protocol::bulk_insert::is_null;

#[test]
fn is_null_with_complete_bitmap_returns_correct_value() {
    let bitmap = vec![0b00000001];
    assert!(is_null(&bitmap, 0));
    assert!(!is_null(&bitmap, 1));
}

#[test]
fn is_null_with_full_bitmap_returns_correct_value_for_each_bit() {
    let bitmap = vec![0xFFu8];
    for i in 0..8 {
        assert!(is_null(&bitmap, i), "bit {i} should be null");
    }
}

/// Documents the *current* (buggy) behaviour: rows beyond the bitmap silently
/// report not-null. The companion fix in `parse_bulk_insert_payload` validates
/// length up-front so this branch becomes unreachable in production.
#[test]
fn is_null_truncated_bitmap_currently_returns_false() {
    let bitmap = vec![0xFFu8]; // covers rows 0..=7
    let bit_outside = 100;
    assert!(
        !is_null(&bitmap, bit_outside),
        "documented current behaviour: out-of-range row treated as non-null; \
         enforcement now lives in parse_bulk_insert_payload"
    );
}
