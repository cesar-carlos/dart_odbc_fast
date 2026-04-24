//! Keeps `test/fixtures/columnar_v2_int32_zstd.golden` in sync with
//! [ColumnarEncoder] zstd output (one integer column, 30 rows) for Dart
//! integration tests. Regenerate: `UPDATE_GOLDEN=1 cargo test -p odbc_engine
//! columnar_v2_zstd_golden_matches_rust_encoder -- --ignored`.

use odbc_engine::protocol::{ColumnData, ColumnMetadata, ColumnarEncoder, OdbcType, RowBufferV2};
use std::path::PathBuf;

fn build_v2_int_zstd() -> Vec<u8> {
    let mut buffer = RowBufferV2::new();
    let rows: Vec<_> = (0i32..30).map(Some).collect();
    buffer.set_row_count(30);
    let metadata = ColumnMetadata {
        name: "n".to_string(),
        odbc_type: OdbcType::Integer,
    };
    buffer.add_column(metadata, ColumnData::Integer(rows));
    let vec = ColumnarEncoder::encode(&buffer, true).expect("encode");
    // single column raw > 100 bytes so zstd path is used
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

/// Fails if the committed-on-disk bytes drift from the encoder. Regenerate:
/// `UPDATE_GOLDEN=1 cargo test -p odbc_engine columnar_v2_zstd_golden_matches_rust_encoder -- --exact`
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
    assert_eq!(
        on_disk, actual,
        "golden out of date; run with UPDATE_GOLDEN=1 from native/odbc_engine"
    );
}
