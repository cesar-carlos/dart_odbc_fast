use super::BulkColumnType;

#[test]
fn bulk_column_type_tag_roundtrip_all_variants() {
    for t in [
        BulkColumnType::I32,
        BulkColumnType::I64,
        BulkColumnType::Text,
        BulkColumnType::Decimal,
        BulkColumnType::Binary,
        BulkColumnType::Timestamp,
    ] {
        let tag = t.to_tag();
        assert_eq!(BulkColumnType::from_tag(tag).unwrap(), t);
    }
}
