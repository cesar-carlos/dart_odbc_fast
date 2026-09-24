//! Checks that the committed Dart fixture and the current Rust encoder carry
//! the same wire metadata and decompressed cells. zstd frames need not be
//! byte-identical when the compression context is reused.

use odbc_engine::protocol::{
    columnar_encoder::COMPRESSION_THRESHOLD_BYTES, ColumnData, ColumnMetadata, ColumnarEncoder,
    OdbcType, RowBufferV2,
};
use std::path::PathBuf;

fn build_v2_int_zstd() -> Vec<u8> {
    let mut buffer = RowBufferV2::new();
    // Each integer cell is 5 bytes (1 null-flag + 4 value). Use enough rows so
    // the raw payload strictly exceeds COMPRESSION_THRESHOLD_BYTES and the zstd
    // path is always taken, regardless of future threshold adjustments.
    let row_count = (COMPRESSION_THRESHOLD_BYTES / 5) + 10;
    let rows: Vec<_> = (0i32..row_count as i32).map(Some).collect();
    buffer.set_row_count(row_count);
    let metadata = ColumnMetadata {
        name: "n".to_string(),
        odbc_type: OdbcType::Integer,
    };
    buffer.add_column(metadata, ColumnData::Integer(rows));
    let vec = ColumnarEncoder::encode(&buffer, true).expect("encode");
    assert!(
        vec.windows(2).any(|w| w == [1, 1]),
        "expected zstd flag (1) and algorithm 1 in output"
    );
    vec
}

#[test]
fn columnar_v2_zstd_golden_encodes() {
    let v = build_v2_int_zstd();
    assert!(v.len() > 50);
    let magic = u32::from_le_bytes([v[0], v[1], v[2], v[3]]);
    assert_eq!(magic, 0x4F44_4243);
}

fn decoded_column_payload(encoded: &[u8]) -> Vec<u8> {
    assert_eq!(&encoded[..4], &0x4F44_4243u32.to_le_bytes());
    assert_eq!(encoded[14], 1, "columnar compression enabled");
    let payload_size = u32::from_le_bytes(encoded[15..19].try_into().expect("payload size"));
    assert_eq!(payload_size as usize, encoded.len() - 19);
    let name_len = u16::from_le_bytes(encoded[21..23].try_into().expect("name length")) as usize;
    let flag_pos = 23 + name_len;
    assert_eq!(encoded[flag_pos], 1, "column compressed");
    assert_eq!(encoded[flag_pos + 1], 1, "zstd algorithm");
    let len_pos = flag_pos + 2;
    let compressed_len = u32::from_le_bytes(
        encoded[len_pos..len_pos + 4]
            .try_into()
            .expect("column size"),
    ) as usize;
    let data_start = len_pos + 4;
    assert_eq!(data_start + compressed_len, encoded.len());
    zstd::decode_all(&encoded[data_start..]).expect("valid zstd frame")
}

/// A different valid zstd frame is compatible: compare protocol metadata and
/// the exact decompressed cells rather than the compressor's byte choices.
#[test]
fn columnar_v2_zstd_golden_matches_rust_encoder() {
    let actual = build_v2_int_zstd();
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fixture = root.join("../../test/fixtures/columnar_v2_int32_zstd.golden");
    if std::env::var("UPDATE_GOLDEN").ok().as_deref() == Some("1") {
        if let Some(parent) = fixture.parent() {
            std::fs::create_dir_all(parent).expect("create fixtures dir");
        }
        std::fs::write(&fixture, &actual).expect("write golden");
        eprintln!("Wrote {} ({} bytes)", fixture.display(), actual.len());
        return;
    }
    let on_disk = std::fs::read(&fixture).unwrap_or_else(|e| {
        panic!(
            "Missing {}; run: UPDATE_GOLDEN=1 cargo test ... -- --ignored: {e}",
            fixture.display()
        )
    });
    assert_eq!(&on_disk[..15], &actual[..15], "wire header changed");
    assert_eq!(&on_disk[19..25], &actual[19..25], "column metadata changed");
    assert_eq!(
        decoded_column_payload(&on_disk),
        decoded_column_payload(&actual)
    );
}
