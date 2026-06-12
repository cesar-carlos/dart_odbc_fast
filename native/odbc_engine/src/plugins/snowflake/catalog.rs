use super::SnowflakePlugin;
use crate::error::Result;
use crate::protocol::ParamValue;

use super::super::capabilities::catalog_provider::{CatalogProvider, CatalogQuery};

impl CatalogProvider for SnowflakePlugin {
    // Snowflake supports INFORMATION_SCHEMA — defaults are correct for tables/columns.
    // Override to use SHOW PRIMARY KEYS / SHOW IMPORTED KEYS / SHOW INDEXES which
    // are faster than the constraint views.
    fn list_primary_keys_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        Ok(CatalogQuery::new(
            "SELECT table_schema AS TABLE_SCHEMA, table_name AS TABLE_NAME, \
                    column_name AS COLUMN_NAME, key_sequence AS POSITION \
             FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc \
             JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu \
              ON tc.constraint_name = kcu.constraint_name \
             WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_name = ? \
             ORDER BY key_sequence",
            vec![ParamValue::String(table.to_string())],
        ))
    }

    fn list_foreign_keys_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        Ok(CatalogQuery::new(
            "SELECT table_schema AS TABLE_SCHEMA, table_name AS TABLE_NAME, \
                    column_name AS COLUMN_NAME, NULL AS REFERENCED_SCHEMA, \
                    NULL AS REFERENCED_TABLE, NULL AS REFERENCED_COLUMN, key_sequence AS POSITION \
             FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE \
             WHERE table_name = ? ORDER BY key_sequence",
            vec![ParamValue::String(table.to_string())],
        ))
    }

    fn list_indexes_sql(&self, _table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        // Snowflake doesn't expose user-defined indexes (it uses micro-partitions).
        Ok(CatalogQuery::no_params(
            "SELECT NULL AS TABLE_SCHEMA, NULL AS TABLE_NAME, NULL AS INDEX_NAME, \
                    NULL AS COLUMN_NAME, 0 AS COLUMN_POSITION, '' AS DESCEND WHERE 1 = 0",
        ))
    }
}
