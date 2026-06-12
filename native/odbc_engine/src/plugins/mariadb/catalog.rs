use super::MariaDbPlugin;
use crate::error::Result;
use crate::protocol::ParamValue;

use super::super::capabilities::catalog_provider::{CatalogProvider, CatalogQuery};

// MariaDB shares the MySQL catalog implementation (same INFORMATION_SCHEMA shape)
// — implements the trait via the default INFORMATION_SCHEMA helpers.
impl CatalogProvider for MariaDbPlugin {
    fn list_primary_keys_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        Ok(CatalogQuery::new(
            "SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION AS POSITION \
             FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE \
             WHERE CONSTRAINT_NAME = 'PRIMARY' AND TABLE_NAME = ? \
             ORDER BY ORDINAL_POSITION",
            vec![ParamValue::String(table.to_string())],
        ))
    }

    fn list_foreign_keys_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        Ok(CatalogQuery::new(
            "SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_SCHEMA AS REFERENCED_SCHEMA, \
                    REFERENCED_TABLE_NAME AS REFERENCED_TABLE, REFERENCED_COLUMN_NAME AS REFERENCED_COLUMN, \
                    ORDINAL_POSITION AS POSITION \
             FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE \
             WHERE REFERENCED_TABLE_NAME IS NOT NULL AND TABLE_NAME = ? \
             ORDER BY ORDINAL_POSITION",
            vec![ParamValue::String(table.to_string())],
        ))
    }

    fn list_indexes_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        Ok(CatalogQuery::new(
            "SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, COLUMN_NAME, SEQ_IN_INDEX AS COLUMN_POSITION, \
                    CASE WHEN NON_UNIQUE = 0 THEN 'UNIQUE' ELSE 'NON-UNIQUE' END AS DESCEND \
             FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_NAME = ? \
             ORDER BY INDEX_NAME, SEQ_IN_INDEX",
            vec![ParamValue::String(table.to_string())],
        ))
    }
}
