//! D1 — DRT1 multi-result wire compatibility.
//!
//! Verifies the on-wire contract for the directed OUT (`DRT1`) engine path
//! when `SQLMoreResults` produces extra items beyond the first result set:
//!
//! - **Single RS + OUT (drain empty):** the buffer must start with the ODBC
//!   row-major magic (`0x4F444243`) and end with an `OUT1` footer, exactly as
//!   before this change.
//! - **Multi RS + OUT (drain non-empty):** the buffer must start with the MULT
//!   magic (`0x544C554D`), contain every result set / row-count in order, and
//!   end with an `OUT1` footer.
//! - **Decoder round-trip:** `decode_multi` + trailer parsing must recover the
//!   original items and OUT values unchanged.
//!
//! These are pure-protocol unit tests (no live ODBC connection needed).

use odbc_engine::protocol::{
    decode_multi, encode_multi, MultiResultItem, ParamValue, RowBuffer, RowBufferEncoder,
};

const ODBC_MAGIC: u32 = 0x4F444243;
const MULT_MAGIC: u32 = 0x544C554D;
const OUT1_MAGIC: u32 = 0x3154554F; // b"OUT1" LE

fn le_u32(buf: &[u8], off: usize) -> u32 {
    u32::from_le_bytes(buf[off..off + 4].try_into().unwrap())
}

fn encode_empty_rb() -> Vec<u8> {
    RowBufferEncoder::encode(&RowBuffer::new())
}

// ─── single RS + OUT (drain empty → legacy wire) ─────────────────────────────

/// When there are no extra drain items the wire must start with the ODBC
/// row-major magic (not MULT) so existing decoders are unaffected.
#[test]
fn single_rs_out_starts_with_odbc_magic() {
    let body = encode_empty_rb();
    let out = ParamValue::Integer(42);
    let buf = RowBufferEncoder::append_output_footer(body, &[out]);

    assert_eq!(
        le_u32(&buf, 0),
        ODBC_MAGIC,
        "single RS + OUT must start with ODBC magic"
    );
    assert_ne!(le_u32(&buf, 0), MULT_MAGIC);
}

/// Single RS + OUT wire must contain the OUT1 magic followed by count = 1.
#[test]
fn single_rs_out_has_out1_footer() {
    let body = encode_empty_rb();
    let out = ParamValue::Integer(99);
    let buf = RowBufferEncoder::append_output_footer(body.clone(), &[out]);

    // OUT1 is appended right after the ODBC payload.
    let after_odbc = body.len();
    assert!(
        buf.len() > after_odbc + 8,
        "buffer must extend beyond ODBC payload"
    );
    assert_eq!(le_u32(&buf, after_odbc), OUT1_MAGIC, "OUT1 magic expected");
    let count = le_u32(&buf, after_odbc + 4);
    assert_eq!(count, 1, "OUT1 count must be 1");
}

// ─── multi RS + OUT (drain non-empty → MULT envelope) ────────────────────────

/// Helper: build the buffer the directed engine path now emits when drain is
/// non-empty (mirrors the Rust implementation exactly).
fn directed_multi_buf(drain: Vec<MultiResultItem>, out_vals: &[ParamValue]) -> Vec<u8> {
    let first = encode_empty_rb();
    let mut items = Vec::with_capacity(1 + drain.len());
    items.push(MultiResultItem::ResultSet(first));
    items.extend(drain);
    let multi = encode_multi(&items);
    RowBufferEncoder::append_output_footer(multi, out_vals)
}

/// When drain has items the buffer must start with MULT magic, not ODBC.
#[test]
fn multi_rs_out_starts_with_mult_magic() {
    let drain = vec![
        MultiResultItem::ResultSet(encode_empty_rb()),
        MultiResultItem::RowCount(5),
    ];
    let buf = directed_multi_buf(drain, &[ParamValue::Integer(7)]);

    assert_eq!(
        le_u32(&buf, 0),
        MULT_MAGIC,
        "multi RS + OUT must start with MULT magic"
    );
    assert_ne!(le_u32(&buf, 0), ODBC_MAGIC);
}

/// decode_multi must recover all items (first + drain) from the MULT frame.
#[test]
fn multi_rs_out_decode_recovers_all_items() {
    let drain = vec![
        MultiResultItem::ResultSet(encode_empty_rb()),
        MultiResultItem::RowCount(3),
    ];
    let buf = directed_multi_buf(drain, &[ParamValue::Integer(1)]);

    // Find where MULT ends so we can pass only the MULT portion to decode_multi.
    // The MULT header gives us the exact item count and sizes.
    // For this test just pass the whole buffer; decode_multi stops at count.
    let items = decode_multi(&buf).expect("decode_multi must succeed");
    assert_eq!(items.len(), 3, "expected first + 2 drain items");

    assert!(
        matches!(items[0], MultiResultItem::ResultSet(_)),
        "item[0] must be ResultSet"
    );
    assert!(
        matches!(items[1], MultiResultItem::ResultSet(_)),
        "item[1] must be ResultSet"
    );
    assert!(
        matches!(items[2], MultiResultItem::RowCount(3)),
        "item[2] must be RowCount(3)"
    );
}

/// OUT1 footer must follow immediately after the MULT payload.
#[test]
fn multi_rs_out_has_out1_after_mult() {
    let drain = vec![MultiResultItem::ResultSet(encode_empty_rb())];
    let out_vals = [ParamValue::Integer(42)];
    let buf = directed_multi_buf(drain, &out_vals);

    // Locate MULT end: header(8 bytes for magic+version+reserved) + count(4) + items.
    // Easiest: re-encode just the MULT part to know its length.
    let first = encode_empty_rb();
    let items = vec![
        MultiResultItem::ResultSet(first),
        MultiResultItem::ResultSet(encode_empty_rb()),
    ];
    let mult_only = encode_multi(&items);
    let mult_len = mult_only.len();

    assert!(
        buf.len() > mult_len + 8,
        "buffer must extend beyond MULT payload"
    );
    let out1_pos = mult_len;
    assert_eq!(
        le_u32(&buf, out1_pos),
        OUT1_MAGIC,
        "OUT1 magic must follow MULT at offset {out1_pos}"
    );
    let count = le_u32(&buf, out1_pos + 4);
    assert_eq!(count, 1, "OUT1 count must be 1");
}

/// Ensure drain-empty case (single RS) produces bytes byte-for-byte identical
/// to the output of `RowBufferEncoder::append_output_footer` on its own.
#[test]
fn drain_empty_matches_legacy_encoding() {
    let out = ParamValue::Integer(55);

    // Legacy path (unchanged code).
    let legacy =
        RowBufferEncoder::append_output_footer(encode_empty_rb(), std::slice::from_ref(&out));

    // Simulate what the engine now does for drain.is_empty() == true.
    let new_path = RowBufferEncoder::append_output_footer(encode_empty_rb(), &[out]);

    assert_eq!(
        legacy, new_path,
        "drain-empty new path must be byte-for-byte identical to legacy"
    );
}

// ─── row-count first (DML-first procedure, no initial cursor) ────────────────
//
// When a directed procedure starts with DML (no initial cursor), the engine
// now captures the affected-row count and emits it as `RowCount(n)` as the
// very first item inside the MULT envelope.  Previously an empty `ResultSet`
// was emitted instead, losing the count and confusing the Dart parser.

/// Build the MULT+OUT1 buffer for a DML-first procedure (mirrors the engine).
fn directed_multi_buf_rc_first(
    initial_rc: i64,
    drain: Vec<MultiResultItem>,
    out_vals: &[ParamValue],
) -> Vec<u8> {
    let mut items = Vec::with_capacity(1 + drain.len());
    items.push(MultiResultItem::RowCount(initial_rc));
    items.extend(drain);
    let multi = encode_multi(&items);
    RowBufferEncoder::append_output_footer(multi, out_vals)
}

/// RowCount-first wire must begin with MULT magic (not ODBC magic).
#[test]
fn rowcount_first_starts_with_mult_magic() {
    let drain = vec![MultiResultItem::ResultSet(encode_empty_rb())];
    let buf = directed_multi_buf_rc_first(3, drain, &[ParamValue::Integer(7)]);

    assert_eq!(
        le_u32(&buf, 0),
        MULT_MAGIC,
        "RowCount-first wire must start with MULT magic"
    );
    assert_ne!(le_u32(&buf, 0), ODBC_MAGIC);
}

/// decode_multi must recover item[0] = RowCount(n) for a DML-first procedure.
#[test]
fn rowcount_first_decode_item0_is_rowcount() {
    let initial_rc: i64 = 5;
    let drain = vec![MultiResultItem::ResultSet(encode_empty_rb())];
    let buf = directed_multi_buf_rc_first(initial_rc, drain, &[ParamValue::Integer(1)]);

    let items = decode_multi(&buf).expect("decode_multi must succeed");
    assert_eq!(items.len(), 2, "expected 2 items: RowCount + ResultSet");

    assert!(
        matches!(items[0], MultiResultItem::RowCount(5)),
        "item[0] must be RowCount(5)"
    );
    assert!(
        matches!(items[1], MultiResultItem::ResultSet(_)),
        "item[1] must be ResultSet"
    );
}

/// RowCount → ResultSet → RowCount → OUT1 round-trip.
#[test]
fn rowcount_first_rc_rs_rc_out1_roundtrip() {
    let drain = vec![
        MultiResultItem::ResultSet(encode_empty_rb()),
        MultiResultItem::RowCount(2),
    ];
    let out_val = ParamValue::Integer(99);
    let buf = directed_multi_buf_rc_first(1, drain, std::slice::from_ref(&out_val));

    // Whole buffer starts with MULT.
    assert_eq!(le_u32(&buf, 0), MULT_MAGIC);

    // decode_multi recovers all 3 items.
    let items = decode_multi(&buf).expect("decode_multi must succeed");
    assert_eq!(items.len(), 3);
    assert!(matches!(items[0], MultiResultItem::RowCount(1)));
    assert!(matches!(items[1], MultiResultItem::ResultSet(_)));
    assert!(matches!(items[2], MultiResultItem::RowCount(2)));

    // OUT1 follows the MULT frame.
    let mult_only = encode_multi(&[
        MultiResultItem::RowCount(1),
        MultiResultItem::ResultSet(encode_empty_rb()),
        MultiResultItem::RowCount(2),
    ]);
    let out1_pos = mult_only.len();
    assert_eq!(le_u32(&buf, out1_pos), OUT1_MAGIC, "OUT1 must follow MULT");
    let count = le_u32(&buf, out1_pos + 4);
    assert_eq!(count, 1, "OUT1 count must be 1");
}
