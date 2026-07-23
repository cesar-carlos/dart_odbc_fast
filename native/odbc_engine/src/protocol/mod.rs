pub mod bound_param;
pub mod bulk_insert;
pub mod columnar;
pub mod columnar_encoder;
pub mod compression;
pub mod converter;
pub mod decoder;
pub mod encoder;
pub mod multi_result;
pub mod param_value;
pub mod row_buffer;
pub mod types;

// EXPERIMENTAL (`columnar-v2` feature): only header constants and placeholder
// benches exist today. Not wired into the main query/stream encode-decode
// pipeline. See `columnar_v2.rs` and `doc/notes/columnar_protocol_sketch.md`.
#[cfg(feature = "columnar-v2")]
pub mod columnar_v2;

pub use bound_param::{
    deserialize_param_buffer, input_params_from_buffer, is_directed_param_buffer, BoundParam,
    ParamDirection, ParamList,
};
pub use bulk_insert::{
    bulk_rows_from_vecs, parse_bulk_insert_payload, serialize_bulk_insert_payload,
    serialize_bulk_insert_payload_v2, BulkCellBytes, BulkColumnData, BulkColumnSpec,
    BulkColumnType, BulkInsertPayload, BulkTimestamp,
};
pub use columnar::{ColumnBlock, ColumnData, ColumnMetadata, CompressionType, RowBufferV2};
pub use columnar_encoder::ColumnarEncoder;
pub use compression::{compress, decompress};
pub use converter::row_buffer_to_columnar;
pub use decoder::{BinaryProtocolDecoder, ColumnInfo, DecodedResult};
pub use encoder::RowBufferEncoder;
pub use multi_result::{
    decode_multi, encode_multi, encode_row_count_only, try_encode_multi, MultiResultItem,
    MultiResultWriter, MULTI_RESULT_MAGIC, MULTI_RESULT_VERSION,
};
pub use param_value::{
    deserialize_params, has_null_param, max_param_string_len, param_count_exceeds_limit,
    param_value_to_input_parameter, param_values_to_input_params,
    param_values_to_input_params_with_descriptions, param_values_to_input_params_with_inference,
    param_values_to_strings, serialize_params, ParamValue,
};
pub use row_buffer::RowBuffer;
pub use types::{cell_bytes_from_slice, CellBytes, OdbcType};
