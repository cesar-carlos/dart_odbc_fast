#[cfg(test)]
mod tests {
    use odbc_engine::protocol::*;

    #[test]
    fn test_columnar_buffer_creation() {
        let mut buffer = RowBufferV2::new();
        assert_eq!(buffer.column_count(), 0);
        assert_eq!(buffer.row_count, 0);

        buffer.set_row_count(10);
        assert_eq!(buffer.row_count, 10);
    }

    #[test]
    fn test_compression_type() {
        assert_eq!(CompressionType::from_u8(0), CompressionType::None);
        assert_eq!(CompressionType::from_u8(1), CompressionType::Zstd);
        assert_eq!(CompressionType::from_u8(2), CompressionType::Lz4);
    }

    #[test]
    fn test_arena_allocator() {
        let mut arena = Arena::new(1024);
        let ptr = arena.allocate(100);
        assert!(!ptr.is_null());

        let ptr2 = arena.allocate(200);
        assert!(!ptr2.is_null());
    }

    #[test]
    fn test_row_buffer_to_columnar() {
        let mut v1 = RowBuffer::new();
        v1.add_column("id".to_string(), OdbcType::Integer);
        v1.add_column("name".to_string(), OdbcType::Varchar);

        let row1 = vec![Some(1i32.to_le_bytes().to_vec()), Some(b"Alice".to_vec())];
        v1.add_row(row1);

        let v2 = row_buffer_to_columnar(&v1);
        assert_eq!(v2.column_count(), 2);
        assert_eq!(v2.row_count, 1);
    }
}
