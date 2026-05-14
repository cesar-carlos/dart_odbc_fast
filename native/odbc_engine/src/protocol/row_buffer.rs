use crate::protocol::types::OdbcType;

pub struct ColumnMetadata {
    pub name: String,
    pub odbc_type: OdbcType,
}

pub struct RowBuffer {
    pub columns: Vec<ColumnMetadata>,
    pub rows: Vec<Vec<Option<Vec<u8>>>>,
}

impl RowBuffer {
    pub fn new() -> Self {
        Self {
            columns: Vec::new(),
            rows: Vec::new(),
        }
    }

    pub fn add_column(&mut self, name: String, odbc_type: OdbcType) {
        self.columns.push(ColumnMetadata { name, odbc_type });
    }

    pub fn add_row(&mut self, row: Vec<Option<Vec<u8>>>) {
        self.rows.push(row);
    }

    pub fn row_count(&self) -> usize {
        self.rows.len()
    }

    pub fn column_count(&self) -> usize {
        self.columns.len()
    }
}

impl Default for RowBuffer {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::types::OdbcType;

    #[test]
    fn new_buffer_has_zero_rows_and_columns() {
        let b = RowBuffer::new();
        assert_eq!(b.row_count(), 0);
        assert_eq!(b.column_count(), 0);
    }

    #[test]
    fn default_matches_new() {
        assert_eq!(
            RowBuffer::default().column_count(),
            RowBuffer::new().column_count()
        );
    }

    #[test]
    fn add_column_and_row_update_counts() {
        let mut b = RowBuffer::new();
        b.add_column("c".to_string(), OdbcType::Integer);
        assert_eq!(b.column_count(), 1);
        b.add_row(vec![None]);
        assert_eq!(b.row_count(), 1);
    }
}
