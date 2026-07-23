//! Multi-result set wire protocol.
//!
//! v1 (legacy):  `[count: u32 LE] [item ...]`
//!
//! v2 (current): `[magic: 0x4D554C54 ("MULT") LE]
//!                [version: u16 LE = 2] [reserved: u16 = 0]
//!                [count: u32 LE] [item ...]`
//!
//! Each `item` is identical in v1 and v2:
//! - `[tag: u8]` (0 = ResultSet, 1 = RowCount)
//! - `[len: u32 LE]`
//! - `[payload: len bytes]`
//!   * tag = 0 → payload is a row-buffer encoded by `binary_protocol` v1
//!   * tag = 1 → payload is `[i64 LE]` (8 bytes, signed row count)
//!
//! [`encode_multi`] always emits the v2 framing. [`decode_multi`] auto-detects
//! the framing by sniffing the first 4 bytes — payloads produced by older
//! versions of this engine continue to round-trip without a breaking change
//! at the FFI layer.

use crate::error::{OdbcError, Result};
use crate::protocol::encoder::{OUTPUT_FOOTER_MAGIC, REF_CURSOR_FOOTER_MAGIC};

const TAG_RESULT_SET: u8 = 0;
const TAG_ROW_COUNT: u8 = 1;

/// `MULT` little-endian (`b'M' | b'U'<<8 | b'L'<<16 | b'T'<<24`).
pub const MULTI_RESULT_MAGIC: u32 = 0x544C554D;

/// Current multi-result protocol version.
pub const MULTI_RESULT_VERSION: u16 = 2;

const HEADER_V2_LEN: usize = 4 /*magic*/ + 2 /*version*/ + 2 /*reserved*/ + 4 /*count*/;
const MIN_ITEM_LEN: usize = 1 /*tag*/ + 4 /*len*/;
const MAX_MULTI_RESULT_ITEMS: usize = 16_384;
const MAX_MULTI_RESULT_PAYLOAD: usize = 256 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq)]
pub enum MultiResultItem {
    ResultSet(Vec<u8>),
    RowCount(i64),
}

/// Encode a list of items using the v2 framing (magic + version + count).
///
/// Convenience wrapper around [`try_encode_multi`]. Well-formed payloads within
/// wire limits always succeed. On overflow the error is logged and an empty
/// buffer is returned instead of panicking; fallible callers should use
/// [`try_encode_multi`] directly.
pub fn encode_multi(items: &[MultiResultItem]) -> Vec<u8> {
    match try_encode_multi(items) {
        Ok(buf) => buf,
        Err(e) => {
            log::error!("encode_multi: {e}");
            Vec::new()
        }
    }
}

/// Single-item MULT payload for DML / no-cursor executes (row-count only).
pub fn encode_row_count_only(row_count: i64) -> Vec<u8> {
    encode_multi(&[MultiResultItem::RowCount(row_count)])
}

/// Checked variant of [`encode_multi`] for callers that prefer an error over a
/// panic when a result set exceeds the wire-format limits.
pub fn try_encode_multi(items: &[MultiResultItem]) -> Result<Vec<u8>> {
    let capacity = checked_add_len(HEADER_V2_LEN, estimate_payload_size(items)?)?;
    let count = checked_u32_len(items.len(), "multi-result item count")?;
    let mut out = Vec::with_capacity(capacity);
    out.extend_from_slice(&MULTI_RESULT_MAGIC.to_le_bytes());
    out.extend_from_slice(&MULTI_RESULT_VERSION.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes()); // reserved
    out.extend_from_slice(&count.to_le_bytes());
    encode_items(items, &mut out)?;
    Ok(out)
}

/// Encode using the legacy v1 framing (no magic, no version). Kept around for
/// regression / compatibility tests; production callers should use
/// [`encode_multi`].
///
/// Same non-panicking contract as [`encode_multi`]; see [`try_encode_multi_v1`]
/// for fallible encoding.
#[doc(hidden)]
pub fn encode_multi_v1(items: &[MultiResultItem]) -> Vec<u8> {
    match try_encode_multi_v1(items) {
        Ok(buf) => buf,
        Err(e) => {
            log::error!("encode_multi_v1: {e}");
            Vec::new()
        }
    }
}

#[doc(hidden)]
pub fn try_encode_multi_v1(items: &[MultiResultItem]) -> Result<Vec<u8>> {
    let capacity = checked_add_len(4, estimate_payload_size(items)?)?;
    let count = checked_u32_len(items.len(), "multi-result item count")?;
    let mut out = Vec::with_capacity(capacity);
    out.extend_from_slice(&count.to_le_bytes());
    encode_items(items, &mut out)?;
    Ok(out)
}

fn encode_items(items: &[MultiResultItem], out: &mut Vec<u8>) -> Result<()> {
    for item in items {
        match item {
            MultiResultItem::ResultSet(buf) => {
                out.push(TAG_RESULT_SET);
                let len = checked_u32_len(buf.len(), "multi-result item payload")?;
                out.extend_from_slice(&len.to_le_bytes());
                out.extend_from_slice(buf);
            }
            MultiResultItem::RowCount(n) => {
                out.push(TAG_ROW_COUNT);
                out.extend_from_slice(&8u32.to_le_bytes());
                out.extend_from_slice(&n.to_le_bytes());
            }
        }
    }
    Ok(())
}

/// Growing MULT v2 encoder that appends items in place (no intermediate item Vec).
#[derive(Debug)]
pub struct MultiResultWriter {
    buf: Vec<u8>,
    count: usize,
}

impl MultiResultWriter {
    /// Starts a v2 MULT buffer with a placeholder item count.
    pub fn new() -> Self {
        Self::with_capacity(64)
    }

    /// Starts a v2 MULT buffer reserving `payload_hint` bytes beyond the header.
    pub fn with_capacity(payload_hint: usize) -> Self {
        let mut buf = Vec::with_capacity(HEADER_V2_LEN.saturating_add(payload_hint));
        buf.extend_from_slice(&MULTI_RESULT_MAGIC.to_le_bytes());
        buf.extend_from_slice(&MULTI_RESULT_VERSION.to_le_bytes());
        buf.extend_from_slice(&0u16.to_le_bytes()); // reserved
        buf.extend_from_slice(&0u32.to_le_bytes()); // count placeholder
        Self { buf, count: 0 }
    }

    /// Reserves space for the next result-set push plus a few similar siblings.
    ///
    /// Call after observing the first encoded cursor size so subsequent pushes
    /// avoid realloc/copy cascades on small multi-result batches.
    pub fn reserve_similar(&mut self, payload_len: usize, extra_result_sets: usize) {
        let per_rs = MIN_ITEM_LEN.saturating_add(payload_len);
        let per_rc = MIN_ITEM_LEN.saturating_add(8);
        let need = per_rs
            .saturating_mul(extra_result_sets.saturating_add(1))
            .saturating_add(per_rc.saturating_mul(2));
        self.buf.reserve(need);
    }

    /// Appends a result-set payload (moves bytes into the MULT buffer).
    pub fn push_result_set(&mut self, mut payload: Vec<u8>) -> Result<()> {
        self.ensure_item_budget()?;
        if payload.len() > MAX_MULTI_RESULT_PAYLOAD {
            return Err(OdbcError::ResourceLimitReached(format!(
                "multi-result item payload {} exceeds limit {}",
                payload.len(),
                MAX_MULTI_RESULT_PAYLOAD
            )));
        }
        let len = checked_u32_len(payload.len(), "multi-result item payload")?;
        self.buf.reserve(MIN_ITEM_LEN.saturating_add(payload.len()));
        self.buf.push(TAG_RESULT_SET);
        self.buf.extend_from_slice(&len.to_le_bytes());
        self.buf.append(&mut payload);
        self.count += 1;
        Ok(())
    }

    /// Appends a row-count item.
    pub fn push_row_count(&mut self, row_count: i64) -> Result<()> {
        self.ensure_item_budget()?;
        self.buf.reserve(MIN_ITEM_LEN.saturating_add(8));
        self.buf.push(TAG_ROW_COUNT);
        self.buf.extend_from_slice(&8u32.to_le_bytes());
        self.buf.extend_from_slice(&row_count.to_le_bytes());
        self.count += 1;
        Ok(())
    }

    /// Patches the item count and returns the finished MULT buffer.
    pub fn finish(mut self) -> Result<Vec<u8>> {
        let count = checked_u32_len(self.count, "multi-result item count")?;
        self.buf[8..12].copy_from_slice(&count.to_le_bytes());
        Ok(self.buf)
    }

    /// Number of items appended so far.
    pub fn item_count(&self) -> usize {
        self.count
    }

    fn ensure_item_budget(&self) -> Result<()> {
        if self.count >= MAX_MULTI_RESULT_ITEMS {
            return Err(OdbcError::ResourceLimitReached(format!(
                "multi-result item count exceeds limit {MAX_MULTI_RESULT_ITEMS}"
            )));
        }
        Ok(())
    }
}

impl Default for MultiResultWriter {
    fn default() -> Self {
        Self::new()
    }
}

fn estimate_payload_size(items: &[MultiResultItem]) -> Result<usize> {
    let mut size = 0usize;
    for item in items {
        size = checked_add_len(size, MIN_ITEM_LEN)?;
        size = checked_add_len(
            size,
            match item {
                MultiResultItem::ResultSet(b) => b.len(),
                MultiResultItem::RowCount(_) => 8,
            },
        )?;
    }
    Ok(size)
}

fn checked_u32_len(value: usize, field: &'static str) -> Result<u32> {
    value.try_into().map_err(|_| {
        OdbcError::ResourceLimitReached(format!("{field} length/count {value} does not fit in u32"))
    })
}

fn checked_add_len(left: usize, right: usize) -> Result<usize> {
    left.checked_add(right).ok_or_else(|| {
        OdbcError::ResourceLimitReached("multi-result payload size overflow".to_string())
    })
}

/// Decode a multi-result buffer. Accepts both the v2 framing (magic +
/// version + count) and the legacy v1 framing (just `count`). Unknown
/// versions return `ValidationError`.
pub fn decode_multi(data: &[u8]) -> Result<Vec<MultiResultItem>> {
    if data.len() >= 4
        && u32::from_le_bytes([data[0], data[1], data[2], data[3]]) == MULTI_RESULT_MAGIC
    {
        decode_multi_v2(data)
    } else {
        decode_multi_v1(data)
    }
}

fn decode_multi_v2(data: &[u8]) -> Result<Vec<MultiResultItem>> {
    if data.len() < HEADER_V2_LEN {
        return Err(OdbcError::ValidationError(
            "Multi-result v2 buffer too short for header".to_string(),
        ));
    }
    let version = u16::from_le_bytes([data[4], data[5]]);
    if version != MULTI_RESULT_VERSION {
        return Err(OdbcError::ValidationError(format!(
            "Unsupported multi-result version: {} (expected {})",
            version, MULTI_RESULT_VERSION
        )));
    }
    let count = u32::from_le_bytes([data[8], data[9], data[10], data[11]]) as usize;
    decode_items(data, HEADER_V2_LEN, count, true)
}

fn decode_multi_v1(data: &[u8]) -> Result<Vec<MultiResultItem>> {
    if data.len() < 4 {
        return Err(OdbcError::ValidationError(
            "Multi-result buffer too short for count".to_string(),
        ));
    }
    let count = u32::from_le_bytes([data[0], data[1], data[2], data[3]]) as usize;
    decode_items(data, 4, count, false)
}

fn decode_items(
    data: &[u8],
    mut offset: usize,
    count: usize,
    reject_trailing: bool,
) -> Result<Vec<MultiResultItem>> {
    validate_item_count(data, offset, count)?;
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        if offset >= data.len() {
            return Err(OdbcError::ValidationError(
                "Multi-result buffer truncated at item".to_string(),
            ));
        }
        let tag = data[offset];
        offset += 1;
        if offset + 4 > data.len() {
            return Err(OdbcError::ValidationError(
                "Multi-result buffer truncated at item length".to_string(),
            ));
        }
        let len = u32::from_le_bytes([
            data[offset],
            data[offset + 1],
            data[offset + 2],
            data[offset + 3],
        ]) as usize;
        if len > MAX_MULTI_RESULT_PAYLOAD {
            return Err(OdbcError::ValidationError(format!(
                "Multi-result item payload {} exceeds limit {}",
                len, MAX_MULTI_RESULT_PAYLOAD
            )));
        }
        offset += 4;
        let end = offset.checked_add(len).ok_or_else(|| {
            OdbcError::ValidationError("Multi-result payload offset overflow".to_string())
        })?;
        if end > data.len() {
            return Err(OdbcError::ValidationError(
                "Multi-result buffer truncated at item payload".to_string(),
            ));
        }
        let payload = &data[offset..end];
        offset = end;
        match tag {
            TAG_RESULT_SET => out.push(MultiResultItem::ResultSet(payload.to_vec())),
            TAG_ROW_COUNT => {
                if len != 8 {
                    return Err(OdbcError::ValidationError(
                        "RowCount item expected 8-byte payload".to_string(),
                    ));
                }
                let n = i64::from_le_bytes([
                    payload[0], payload[1], payload[2], payload[3], payload[4], payload[5],
                    payload[6], payload[7],
                ]);
                out.push(MultiResultItem::RowCount(n));
            }
            _ => {
                return Err(OdbcError::ValidationError(format!(
                    "Unknown multi-result item tag: {}",
                    tag
                )));
            }
        }
    }
    if reject_trailing && offset != data.len() && !is_known_footer(&data[offset..]) {
        return Err(OdbcError::ValidationError(
            "Multi-result v2 buffer has trailing bytes".to_string(),
        ));
    }
    Ok(out)
}

fn is_known_footer(data: &[u8]) -> bool {
    data.starts_with(&OUTPUT_FOOTER_MAGIC) || data.starts_with(&REF_CURSOR_FOOTER_MAGIC)
}

fn validate_item_count(data: &[u8], offset: usize, count: usize) -> Result<()> {
    if count > MAX_MULTI_RESULT_ITEMS {
        return Err(OdbcError::ValidationError(format!(
            "Multi-result item count {} exceeds limit {}",
            count, MAX_MULTI_RESULT_ITEMS
        )));
    }
    let remaining = data.len().saturating_sub(offset);
    let min_required = count
        .checked_mul(MIN_ITEM_LEN)
        .ok_or_else(|| OdbcError::ValidationError("Multi-result count overflow".to_string()))?;
    if min_required > remaining {
        return Err(OdbcError::ValidationError(
            "Multi-result count exceeds available payload".to_string(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn multi_result_writer_round_trips_like_try_encode_multi() {
        let mut writer = MultiResultWriter::new();
        writer.push_result_set(vec![1, 2, 3]).unwrap();
        writer.push_row_count(-5).unwrap();
        writer.push_result_set(vec![9]).unwrap();
        let via_writer = writer.finish().unwrap();
        let via_encode = try_encode_multi(&[
            MultiResultItem::ResultSet(vec![1, 2, 3]),
            MultiResultItem::RowCount(-5),
            MultiResultItem::ResultSet(vec![9]),
        ])
        .unwrap();
        assert_eq!(via_writer, via_encode);
        assert_eq!(decode_multi(&via_writer).unwrap().len(), 3);
    }

    #[test]
    fn multi_result_writer_with_capacity_and_reserve_similar_round_trip() {
        let payload = vec![7u8; 128];
        let mut writer = MultiResultWriter::with_capacity(payload.len() * 2);
        writer.reserve_similar(payload.len(), 2);
        writer.push_result_set(payload.clone()).unwrap();
        writer.push_result_set(payload).unwrap();
        writer.push_row_count(3).unwrap();
        let via_writer = writer.finish().unwrap();
        let via_encode = try_encode_multi(&[
            MultiResultItem::ResultSet(vec![7u8; 128]),
            MultiResultItem::ResultSet(vec![7u8; 128]),
            MultiResultItem::RowCount(3),
        ])
        .unwrap();
        assert_eq!(via_writer, via_encode);
    }

    #[test]
    fn test_encode_decode_multi_empty() {
        let items: Vec<MultiResultItem> = vec![];
        let enc = encode_multi(&items);
        let dec = decode_multi(&enc).unwrap();
        assert_eq!(dec, items);
    }

    #[test]
    fn test_encode_decode_multi_row_count() {
        let items = vec![MultiResultItem::RowCount(42)];
        let enc = encode_multi(&items);
        let dec = decode_multi(&enc).unwrap();
        assert_eq!(dec, items);
    }

    #[test]
    fn encode_row_count_only_matches_single_item_multi_encoder() {
        for count in [0_i64, 1, 42, -1, i64::MAX, i64::MIN] {
            let via_helper = encode_row_count_only(count);
            let via_multi = encode_multi(&[MultiResultItem::RowCount(count)]);
            assert_eq!(via_helper, via_multi);
            let dec = decode_multi(&via_helper).expect("round-trip");
            assert_eq!(dec, vec![MultiResultItem::RowCount(count)]);
        }
    }

    #[test]
    fn test_encode_decode_multi_result_set() {
        let items = vec![MultiResultItem::ResultSet(vec![1, 2, 3])];
        let enc = encode_multi(&items);
        let dec = decode_multi(&enc).unwrap();
        assert_eq!(dec, items);
    }

    #[test]
    fn test_encode_decode_multi_mixed() {
        let items = vec![
            MultiResultItem::ResultSet(vec![10, 20]),
            MultiResultItem::RowCount(7),
            MultiResultItem::ResultSet(vec![30]),
        ];
        let enc = encode_multi(&items);
        let dec = decode_multi(&enc).unwrap();
        assert_eq!(dec, items);
    }

    #[test]
    fn try_encode_multi_matches_public_encoder() {
        let items = vec![
            MultiResultItem::ResultSet(vec![1, 2, 3]),
            MultiResultItem::RowCount(-5),
        ];

        assert_eq!(try_encode_multi(&items).unwrap(), encode_multi(&items));
    }

    #[test]
    fn checked_add_len_rejects_overflow() {
        let err = checked_add_len(usize::MAX, 1).unwrap_err();

        assert!(matches!(err, OdbcError::ResourceLimitReached(_)));
    }

    #[test]
    fn test_decode_multi_too_short() {
        let r = decode_multi(&[0, 0]);
        assert!(r.is_err());
    }

    #[test]
    fn encode_multi_emits_v2_header_with_magic_and_version() {
        let bytes = encode_multi(&[]);
        assert!(bytes.len() >= HEADER_V2_LEN);
        let magic = u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
        let version = u16::from_le_bytes([bytes[4], bytes[5]]);
        let reserved = u16::from_le_bytes([bytes[6], bytes[7]]);
        let count = u32::from_le_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]);
        assert_eq!(magic, MULTI_RESULT_MAGIC);
        assert_eq!(version, MULTI_RESULT_VERSION);
        assert_eq!(reserved, 0);
        assert_eq!(count, 0);
    }

    #[test]
    fn decode_multi_accepts_v1_legacy_payload() {
        let items = vec![
            MultiResultItem::ResultSet(vec![10, 20]),
            MultiResultItem::RowCount(7),
        ];
        let v1 = encode_multi_v1(&items);
        let dec = decode_multi(&v1).expect("legacy v1 buffer must decode");
        assert_eq!(dec, items);
    }

    #[test]
    fn decode_multi_rejects_unknown_version() {
        let mut bytes = encode_multi(&[]);
        // Flip version to something we don't understand.
        bytes[4] = 99;
        bytes[5] = 0;
        let r = decode_multi(&bytes);
        assert!(matches!(r, Err(OdbcError::ValidationError(_))));
    }

    #[test]
    fn decode_multi_v2_truncated_header_returns_error() {
        let bytes: Vec<u8> = MULTI_RESULT_MAGIC.to_le_bytes().to_vec();
        // Not enough bytes for version/reserved/count.
        assert!(matches!(
            decode_multi(&bytes),
            Err(OdbcError::ValidationError(_))
        ));
    }

    #[test]
    fn decode_multi_rejects_huge_count_before_allocation() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&MULTI_RESULT_MAGIC.to_le_bytes());
        bytes.extend_from_slice(&MULTI_RESULT_VERSION.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&u32::MAX.to_le_bytes());

        let result = decode_multi(&bytes);

        assert!(result.unwrap_err().to_string().contains("item count"));
    }

    #[test]
    fn decode_multi_v2_rejects_unknown_item_tag() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&MULTI_RESULT_MAGIC.to_le_bytes());
        bytes.extend_from_slice(&MULTI_RESULT_VERSION.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&1u32.to_le_bytes());
        bytes.push(99u8); // not ResultSet nor RowCount
        bytes.extend_from_slice(&0u32.to_le_bytes());

        let err = decode_multi(&bytes).unwrap_err();
        assert!(
            err.to_string().contains("Unknown multi-result item tag"),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn decode_multi_v2_rejects_row_count_with_wrong_payload_length() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&MULTI_RESULT_MAGIC.to_le_bytes());
        bytes.extend_from_slice(&MULTI_RESULT_VERSION.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&1u32.to_le_bytes());
        bytes.push(TAG_ROW_COUNT);
        bytes.extend_from_slice(&4u32.to_le_bytes()); // not 8
        bytes.extend_from_slice(&[0, 0, 0, 0]);

        let err = decode_multi(&bytes).unwrap_err();
        assert!(
            err.to_string().contains("RowCount item expected 8-byte"),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn try_encode_multi_v1_empty_round_trips_decode() {
        let items: Vec<MultiResultItem> = vec![];
        let enc = try_encode_multi_v1(&items).unwrap();
        let dec = decode_multi(&enc).unwrap();
        assert_eq!(dec, items);
    }

    #[test]
    fn decode_multi_v1_rejects_truncated_item_payload() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&1u32.to_le_bytes()); // count = 1
        bytes.push(TAG_RESULT_SET);
        bytes.extend_from_slice(&10u32.to_le_bytes()); // claims 10 bytes
        bytes.extend_from_slice(&[1, 2, 3]); // only 3

        let err = decode_multi(&bytes).unwrap_err();
        assert!(
            err.to_string().contains("truncated at item payload"),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn decode_multi_v2_rejects_trailing_bytes() {
        let mut bytes = encode_multi(&[]);
        bytes.push(1);

        let result = decode_multi(&bytes);

        assert!(result.unwrap_err().to_string().contains("trailing bytes"));
    }

    #[test]
    fn decode_multi_v2_tolerates_output_footer_trailer() {
        let items = vec![MultiResultItem::RowCount(3)];
        let mut bytes = encode_multi(&items);
        bytes.extend_from_slice(&OUTPUT_FOOTER_MAGIC);
        bytes.extend_from_slice(&0u32.to_le_bytes());

        let dec = decode_multi(&bytes).expect("footer trailer");
        assert_eq!(dec, items);
    }

    #[test]
    fn decode_multi_v2_tolerates_ref_cursor_footer_trailer() {
        let items = vec![MultiResultItem::ResultSet(vec![1, 2])];
        let mut bytes = encode_multi(&items);
        bytes.extend_from_slice(&REF_CURSOR_FOOTER_MAGIC);
        bytes.extend_from_slice(&0u32.to_le_bytes());

        let dec = decode_multi(&bytes).expect("rc footer trailer");
        assert_eq!(dec, items);
    }

    #[test]
    fn decode_multi_v1_rejects_unknown_item_tag() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&1u32.to_le_bytes());
        bytes.push(0xAB);
        bytes.extend_from_slice(&0u32.to_le_bytes());

        let err = decode_multi(&bytes).unwrap_err();
        assert!(err.to_string().contains("Unknown multi-result item tag"));
    }

    #[test]
    fn decode_multi_rejects_item_payload_over_limit() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&MULTI_RESULT_MAGIC.to_le_bytes());
        bytes.extend_from_slice(&MULTI_RESULT_VERSION.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&1u32.to_le_bytes());
        bytes.push(TAG_RESULT_SET);
        bytes.extend_from_slice(&(MAX_MULTI_RESULT_PAYLOAD as u32 + 1).to_le_bytes());

        let err = decode_multi(&bytes).unwrap_err();
        assert!(err.to_string().contains("exceeds limit"));
    }

    #[test]
    fn decode_multi_rejects_count_exceeding_available_bytes() {
        let mut bytes = encode_multi(&[]);
        bytes[8] = 2;
        bytes[9] = 0;
        bytes[10] = 0;
        bytes[11] = 0;

        let err = decode_multi(&bytes).unwrap_err();
        assert!(err.to_string().contains("exceeds available payload"));
    }

    #[test]
    fn decode_multi_rejects_item_count_over_max() {
        let mut bytes = encode_multi(&[]);
        let over = (MAX_MULTI_RESULT_ITEMS as u32).saturating_add(1);
        bytes[8..12].copy_from_slice(&over.to_le_bytes());

        let err = decode_multi(&bytes).unwrap_err();
        assert!(err.to_string().contains("item count"));
        assert!(err.to_string().contains("exceeds limit"));
    }
}
