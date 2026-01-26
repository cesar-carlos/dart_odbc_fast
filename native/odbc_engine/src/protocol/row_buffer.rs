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
