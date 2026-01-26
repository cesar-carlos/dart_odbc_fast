use crate::protocol::types::OdbcType;

pub struct ColumnBlock {
    pub metadata: ColumnMetadata,
    pub data: ColumnData,
    pub compressed: bool,
    pub compression_type: CompressionType,
}

pub struct ColumnMetadata {
    pub name: String,
    pub odbc_type: OdbcType,
}

pub enum ColumnData {
    Varchar(Vec<Option<Vec<u8>>>),
    Integer(Vec<Option<i32>>),
    BigInt(Vec<Option<i64>>),
    Binary(Vec<Option<Vec<u8>>>),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CompressionType {
    None = 0,
    Zstd = 1,
    Lz4 = 2,
}

impl CompressionType {
    pub fn from_u8(value: u8) -> Self {
        match value {
            1 => CompressionType::Zstd,
            2 => CompressionType::Lz4,
            _ => CompressionType::None,
        }
    }
}

pub struct RowBufferV2 {
    pub columns: Vec<ColumnBlock>,
    pub row_count: usize,
    pub flags: u16,
}

impl RowBufferV2 {
    pub fn new() -> Self {
        Self {
            columns: Vec::new(),
            row_count: 0,
            flags: 0,
        }
    }

    pub fn add_column(&mut self, metadata: ColumnMetadata, data: ColumnData) {
        self.columns.push(ColumnBlock {
            metadata,
            data,
            compressed: false,
            compression_type: CompressionType::None,
        });
    }

    pub fn column_count(&self) -> usize {
        self.columns.len()
    }

    pub fn set_row_count(&mut self, count: usize) {
        self.row_count = count;
    }
}

impl Default for RowBufferV2 {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compression_type_from_u8() {
        assert_eq!(CompressionType::from_u8(0), CompressionType::None);
        assert_eq!(CompressionType::from_u8(1), CompressionType::Zstd);
        assert_eq!(CompressionType::from_u8(2), CompressionType::Lz4);
        assert_eq!(CompressionType::from_u8(99), CompressionType::None);
    }

    #[test]
    fn test_row_buffer_v2_new() {
        let buffer = RowBufferV2::new();
        assert_eq!(buffer.columns.len(), 0);
        assert_eq!(buffer.row_count, 0);
        assert_eq!(buffer.flags, 0);
    }

    #[test]
    fn test_row_buffer_v2_default() {
        let buffer = RowBufferV2::default();
        assert_eq!(buffer.columns.len(), 0);
        assert_eq!(buffer.row_count, 0);
    }

    #[test]
    fn test_row_buffer_v2_add_column() {
        let mut buffer = RowBufferV2::new();
        let metadata = ColumnMetadata {
            name: "id".to_string(),
            odbc_type: OdbcType::Integer,
        };
        let data = ColumnData::Integer(vec![Some(1), Some(2), Some(3)]);

        buffer.add_column(metadata, data);
        assert_eq!(buffer.column_count(), 1);
        assert_eq!(buffer.columns[0].metadata.name, "id");
        assert_eq!(buffer.columns[0].metadata.odbc_type, OdbcType::Integer);
        assert!(!buffer.columns[0].compressed);
        assert_eq!(buffer.columns[0].compression_type, CompressionType::None);
    }

    #[test]
    fn test_row_buffer_v2_set_row_count() {
        let mut buffer = RowBufferV2::new();
        buffer.set_row_count(42);
        assert_eq!(buffer.row_count, 42);
    }

    #[test]
    fn test_row_buffer_v2_multiple_columns() {
        let mut buffer = RowBufferV2::new();

        let metadata1 = ColumnMetadata {
            name: "id".to_string(),
            odbc_type: OdbcType::Integer,
        };
        let data1 = ColumnData::Integer(vec![Some(1), Some(2)]);
        buffer.add_column(metadata1, data1);

        let metadata2 = ColumnMetadata {
            name: "name".to_string(),
            odbc_type: OdbcType::Varchar,
        };
        let data2 = ColumnData::Varchar(vec![Some(b"Alice".to_vec()), Some(b"Bob".to_vec())]);
        buffer.add_column(metadata2, data2);

        assert_eq!(buffer.column_count(), 2);
        assert_eq!(buffer.columns[0].metadata.name, "id");
        assert_eq!(buffer.columns[1].metadata.name, "name");
    }

    #[test]
    fn test_column_data_variant_integer() {
        let data = ColumnData::Integer(vec![Some(42), None, Some(100)]);
        match data {
            ColumnData::Integer(values) => {
                assert_eq!(values.len(), 3);
                assert_eq!(values[0], Some(42));
                assert_eq!(values[1], None);
                assert_eq!(values[2], Some(100));
            }
            _ => panic!("Expected Integer variant"),
        }
    }

    #[test]
    fn test_column_data_variant_bigint() {
        let data = ColumnData::BigInt(vec![Some(1234567890i64), None]);
        match data {
            ColumnData::BigInt(values) => {
                assert_eq!(values.len(), 2);
                assert_eq!(values[0], Some(1234567890));
                assert_eq!(values[1], None);
            }
            _ => panic!("Expected BigInt variant"),
        }
    }

    #[test]
    fn test_column_data_variant_varchar() {
        let data = ColumnData::Varchar(vec![Some(b"test".to_vec()), None, Some(b"data".to_vec())]);
        match data {
            ColumnData::Varchar(values) => {
                assert_eq!(values.len(), 3);
                assert_eq!(values[0], Some(b"test".to_vec()));
                assert_eq!(values[1], None);
                assert_eq!(values[2], Some(b"data".to_vec()));
            }
            _ => panic!("Expected Varchar variant"),
        }
    }

    #[test]
    fn test_column_data_variant_binary() {
        let data = ColumnData::Binary(vec![Some(vec![0x01, 0x02, 0x03]), None]);
        match data {
            ColumnData::Binary(values) => {
                assert_eq!(values.len(), 2);
                assert_eq!(values[0], Some(vec![0x01, 0x02, 0x03]));
                assert_eq!(values[1], None);
            }
            _ => panic!("Expected Binary variant"),
        }
    }
}
