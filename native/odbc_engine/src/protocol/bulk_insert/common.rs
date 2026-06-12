use crate::error::{OdbcError, Result};
use std::borrow::Cow;
use std::ops::Deref;
use std::str;
use std::sync::Arc;

/// Hard cap on column count to bound memory in `parse_bulk_insert_payload`.
/// Chosen to comfortably exceed any real-world table while preventing
/// allocation-bomb attacks via crafted payloads.
pub const MAX_BULK_COLUMNS: usize = 4096;

/// Hard cap on row count per single bulk-insert payload.
pub const MAX_BULK_ROWS: usize = 10_000_000;

/// Hard cap on per-cell `max_len` (bytes). 16 MiB is well above realistic
/// VARCHAR/VARBINARY widths.
pub const MAX_BULK_CELL_LEN: usize = 16 * 1024 * 1024;

pub(crate) const BULK_V2_MAGIC: &[u8; 4] = b"BLK2";
pub(crate) const BULK_V2_VERSION: u16 = 2;
pub(crate) const BULK_V2_FLAGS_NONE: u16 = 0;

pub(crate) const TAG_I32: u8 = 0;
pub(crate) const TAG_I64: u8 = 1;
pub(crate) const TAG_TEXT: u8 = 2;
pub(crate) const TAG_DECIMAL: u8 = 3;
pub(crate) const TAG_BINARY: u8 = 4;
pub(crate) const TAG_TIMESTAMP: u8 = 5;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BulkColumnType {
    I32,
    I64,
    Text,
    Decimal,
    Binary,
    Timestamp,
}

impl BulkColumnType {
    pub(crate) fn from_tag(tag: u8) -> Result<Self> {
        match tag {
            TAG_I32 => Ok(BulkColumnType::I32),
            TAG_I64 => Ok(BulkColumnType::I64),
            TAG_TEXT => Ok(BulkColumnType::Text),
            TAG_DECIMAL => Ok(BulkColumnType::Decimal),
            TAG_BINARY => Ok(BulkColumnType::Binary),
            TAG_TIMESTAMP => Ok(BulkColumnType::Timestamp),
            _ => Err(OdbcError::ValidationError(format!(
                "Unknown bulk column type tag: {}",
                tag
            ))),
        }
    }

    pub(crate) fn to_tag(&self) -> u8 {
        match self {
            BulkColumnType::I32 => TAG_I32,
            BulkColumnType::I64 => TAG_I64,
            BulkColumnType::Text => TAG_TEXT,
            BulkColumnType::Decimal => TAG_DECIMAL,
            BulkColumnType::Binary => TAG_BINARY,
            BulkColumnType::Timestamp => TAG_TIMESTAMP,
        }
    }
}

#[derive(Debug, Clone)]
pub struct BulkColumnSpec {
    pub name: String,
    pub col_type: BulkColumnType,
    pub nullable: bool,
    pub max_len: usize,
}

/// Variable-length bulk cell bytes.
///
/// Parsed wire payloads share one [`Arc`] backing buffer per cell (zero-copy
/// sub-slices). Manually constructed payloads use owned storage via the same
/// type so [`BulkInsertPayload`] stays lifetime-free for [`ArrayBinding`].
#[derive(Debug, Clone)]
pub struct BulkCellBytes {
    storage: Arc<[u8]>,
    offset: usize,
    len: usize,
}

impl BulkCellBytes {
    pub fn from_vec(bytes: Vec<u8>) -> Self {
        let storage: Arc<[u8]> = Arc::from(bytes.into_boxed_slice());
        let len = storage.len();
        Self {
            storage,
            offset: 0,
            len,
        }
    }

    pub(crate) fn from_arc_slice(storage: Arc<[u8]>, offset: usize, len: usize) -> Self {
        Self {
            storage,
            offset,
            len,
        }
    }

    pub fn as_slice(&self) -> &[u8] {
        &self.storage[self.offset..self.offset + self.len]
    }

    pub fn to_vec(&self) -> Vec<u8> {
        self.as_slice().to_vec()
    }

    pub fn into_owned(self) -> Cow<'static, [u8]> {
        Cow::Owned(self.as_slice().to_vec())
    }
}

impl From<Vec<u8>> for BulkCellBytes {
    fn from(bytes: Vec<u8>) -> Self {
        Self::from_vec(bytes)
    }
}

impl From<&[u8]> for BulkCellBytes {
    fn from(bytes: &[u8]) -> Self {
        Self::from_vec(bytes.to_vec())
    }
}

impl AsRef<[u8]> for BulkCellBytes {
    fn as_ref(&self) -> &[u8] {
        self.as_slice()
    }
}

impl Deref for BulkCellBytes {
    type Target = [u8];

    fn deref(&self) -> &Self::Target {
        self.as_slice()
    }
}

impl PartialEq<[u8]> for BulkCellBytes {
    fn eq(&self, other: &[u8]) -> bool {
        self.as_slice() == other
    }
}

impl PartialEq<&[u8]> for BulkCellBytes {
    fn eq(&self, other: &&[u8]) -> bool {
        self.as_slice() == *other
    }
}

impl PartialEq<Vec<u8>> for BulkCellBytes {
    fn eq(&self, other: &Vec<u8>) -> bool {
        self.as_slice() == other.as_slice()
    }
}

impl PartialEq<BulkCellBytes> for &[u8] {
    fn eq(&self, other: &BulkCellBytes) -> bool {
        *self == other.as_slice()
    }
}

impl<const N: usize> PartialEq<[u8; N]> for BulkCellBytes {
    fn eq(&self, other: &[u8; N]) -> bool {
        self.as_slice() == other.as_slice()
    }
}

impl<const N: usize> PartialEq<&[u8; N]> for BulkCellBytes {
    fn eq(&self, other: &&[u8; N]) -> bool {
        self.as_slice() == other.as_ref()
    }
}

/// Build a row vector from owned byte vectors (tests and manual payload construction).
pub fn bulk_rows_from_vecs(rows: impl IntoIterator<Item = Vec<u8>>) -> Vec<BulkCellBytes> {
    rows.into_iter().map(BulkCellBytes::from_vec).collect()
}

#[derive(Debug, Clone)]
pub struct BulkInsertPayload {
    pub table: String,
    pub columns: Vec<BulkColumnSpec>,
    pub row_count: u32,
    pub column_data: Vec<BulkColumnData>,
}

#[derive(Debug, Clone)]
pub enum BulkColumnData {
    I32 {
        values: Vec<i32>,
        null_bitmap: Option<Vec<u8>>,
    },
    I64 {
        values: Vec<i64>,
        null_bitmap: Option<Vec<u8>>,
    },
    Text {
        rows: Vec<BulkCellBytes>,
        max_len: usize,
        null_bitmap: Option<Vec<u8>>,
    },
    Binary {
        rows: Vec<BulkCellBytes>,
        max_len: usize,
        null_bitmap: Option<Vec<u8>>,
    },
    Timestamp {
        values: Vec<BulkTimestamp>,
        null_bitmap: Option<Vec<u8>>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BulkTimestamp {
    pub year: i16,
    pub month: u16,
    pub day: u16,
    pub hour: u16,
    pub minute: u16,
    pub second: u16,
    pub fraction: u32,
}

pub(crate) fn read_u32_le(data: &[u8], offset: &mut usize) -> Result<u32> {
    if data.len().saturating_sub(*offset) < 4 {
        return Err(OdbcError::ValidationError(
            "Bulk insert payload truncated (u32)".to_string(),
        ));
    }
    let v = u32::from_le_bytes([
        data[*offset],
        data[*offset + 1],
        data[*offset + 2],
        data[*offset + 3],
    ]);
    *offset += 4;
    Ok(v)
}

pub(crate) fn read_u16_le(data: &[u8], offset: &mut usize) -> Result<u16> {
    if data.len().saturating_sub(*offset) < 2 {
        return Err(OdbcError::ValidationError(
            "Bulk insert payload truncated (u16)".to_string(),
        ));
    }
    let v = u16::from_le_bytes([data[*offset], data[*offset + 1]]);
    *offset += 2;
    Ok(v)
}

pub(crate) fn read_bytes<'a>(data: &'a [u8], offset: &mut usize, len: usize) -> Result<&'a [u8]> {
    if data.len().saturating_sub(*offset) < len {
        return Err(OdbcError::ValidationError(
            "Bulk insert payload truncated (bytes)".to_string(),
        ));
    }
    let slice = &data[*offset..*offset + len];
    *offset += len;
    Ok(slice)
}

pub fn null_bitmap_size(n: usize) -> usize {
    n.div_ceil(8)
}

/// Read the null bit for `row` from a packed bitmap.
///
/// Returns `false` when `row` is beyond the bitmap (treated as "not null") to
/// preserve historical behaviour. **The single source of truth for bitmap
/// integrity is `parse_bulk_insert_payload`**, which rejects payloads whose
/// bitmap length differs from `null_bitmap_size(row_count)` (C9).
pub fn is_null(bitmap: &[u8], row: usize) -> bool {
    if row / 8 >= bitmap.len() {
        return false;
    }
    (bitmap[row / 8] & (1u8 << (row % 8))) != 0
}

/// Strict bitmap accessor: returns an error when the bit lies outside the
/// bitmap, instead of defaulting to `false`. Use in code paths that have
/// already been promoted to validate payloads up-front.
pub fn is_null_strict(bitmap: &[u8], row: usize, row_count: usize) -> Result<bool> {
    if row >= row_count {
        return Err(OdbcError::MalformedPayload(format!(
            "row index {row} out of range (row_count={row_count})"
        )));
    }
    let byte_idx = row / 8;
    if byte_idx >= bitmap.len() {
        return Err(OdbcError::MalformedPayload(format!(
            "null bitmap truncated: byte index {byte_idx} out of range (len={})",
            bitmap.len()
        )));
    }
    Ok((bitmap[byte_idx] & (1u8 << (row % 8))) != 0)
}

/// Read a null-bitmap of exactly `null_bitmap_size(row_count)` bytes and verify it.
pub(crate) fn read_null_bitmap(
    data: &[u8],
    o: &mut usize,
    nullable: bool,
    row_count: usize,
) -> Result<Option<Vec<u8>>> {
    if !nullable {
        return Ok(None);
    }
    let expected = null_bitmap_size(row_count);
    Ok(Some(read_bytes(data, o, expected)?.to_vec()))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BulkPayloadWire {
    Legacy,
    V2,
}

pub(crate) fn validate_variable_cell_len(len: usize, max_len: usize) -> Result<()> {
    if len > MAX_BULK_CELL_LEN {
        return Err(OdbcError::ResourceLimitReached(format!(
            "cell length {len} exceeds MAX_BULK_CELL_LEN={MAX_BULK_CELL_LEN}"
        )));
    }
    if max_len > 0 && len > max_len {
        return Err(OdbcError::MalformedPayload(format!(
            "cell length {len} exceeds column max_len {max_len}"
        )));
    }
    Ok(())
}

/// Convert `usize` to `u32` for wire-format length fields, returning a
/// validation error instead of silently truncating.
pub(crate) fn len_to_u32(n: usize, what: &str) -> Result<u32> {
    u32::try_from(n).map_err(|_| {
        OdbcError::MalformedPayload(format!(
            "{what} length {n} does not fit in u32 (max {})",
            u32::MAX
        ))
    })
}

pub(crate) fn checked_payload_size_add(current: usize, added: usize) -> Result<usize> {
    current
        .checked_add(added)
        .ok_or_else(|| OdbcError::ResourceLimitReached("bulk payload size overflow".to_string()))
}

pub(crate) fn checked_payload_size_mul(left: usize, right: usize) -> Result<usize> {
    left.checked_mul(right)
        .ok_or_else(|| OdbcError::ResourceLimitReached("bulk payload size overflow".to_string()))
}

pub(crate) fn write_null_bitmap(out: &mut Vec<u8>, null_bitmap: &Option<Vec<u8>>) {
    if let Some(bm) = null_bitmap {
        out.extend_from_slice(bm);
    }
}
