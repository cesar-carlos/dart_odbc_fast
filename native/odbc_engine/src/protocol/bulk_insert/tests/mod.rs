//! Bulk insert unit tests (split from the former monolithic `bulk_insert/tests.rs`).

pub(super) use super::common::{
    BulkColumnType, BulkPayloadWire, BULK_V2_MAGIC, BULK_V2_VERSION, MAX_BULK_CELL_LEN,
    MAX_BULK_COLUMNS, MAX_BULK_ROWS, TAG_BINARY, TAG_I32, TAG_I64, TAG_TEXT,
};
pub(super) use super::legacy::trim_legacy_nul_padded_cell;
pub(super) use super::{
    estimate_serialized_payload_size, is_null, is_null_strict, null_bitmap_size,
    parse_bulk_insert_payload, serialize_bulk_insert_payload, serialize_bulk_insert_payload_v2,
    BulkColumnData, BulkColumnSpec, BulkInsertPayload, BulkTimestamp,
};

mod column_types;
mod estimate;
mod legacy_wire;
mod null_bitmap;
mod roundtrip;
mod v2;
mod validation;
