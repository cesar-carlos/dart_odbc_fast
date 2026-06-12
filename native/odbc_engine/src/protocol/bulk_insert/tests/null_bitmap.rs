use super::{is_null, is_null_strict, null_bitmap_size, parse_bulk_insert_payload, TAG_I32};

#[test]
fn null_bitmap_size_table() {
    assert_eq!(null_bitmap_size(0), 0);
    assert_eq!(null_bitmap_size(1), 1);
    assert_eq!(null_bitmap_size(8), 1);
    assert_eq!(null_bitmap_size(9), 2);
}
#[test]
fn is_null_strict_errors_on_bad_row() {
    let e = is_null_strict(&[0u8], 1, 1).expect_err("out of range");
    assert!(e.to_string().contains("out of range"));
}
#[test]
fn is_null_strict_errors_on_truncated_bitmap() {
    let e = is_null_strict(&[], 0, 1).expect_err("truncated");
    assert!(e.to_string().contains("null bitmap truncated"));
}
#[test]
fn is_null_reads_packed_bits() {
    let bmp = [0b101];
    assert!(is_null(&bmp, 0));
    assert!(!is_null(&bmp, 1));
    assert!(is_null(&bmp, 2));
}
#[test]
fn is_null_returns_false_when_row_byte_index_outside_bitmap() {
    let bmp = [0xFF];
    assert!(!is_null(&bmp, 8));
}
#[test]
fn is_null_strict_reads_bit_within_row_count() {
    let bmp = [0b100];
    assert!(is_null_strict(&bmp, 2, 3).unwrap());
    assert!(!is_null_strict(&bmp, 0, 3).unwrap());
}
#[test]
fn should_reject_legacy_null_bitmap_length_mismatch() {
    let mut v = Vec::new();
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(b"t");
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(b"a");
    v.push(TAG_I32);
    v.push(1); // nullable
    v.extend_from_slice(&0u32.to_le_bytes());
    v.extend_from_slice(&1u32.to_le_bytes());
    v.push(0); // bitmap too short for 1 row (expects 1 byte, got 0 after push?)

    let err = parse_bulk_insert_payload(&v).expect_err("bitmap");
    assert!(
        err.to_string().contains("truncated")
            || err.to_string().contains("null bitmap")
            || err.to_string().contains("mismatch")
    );
}
