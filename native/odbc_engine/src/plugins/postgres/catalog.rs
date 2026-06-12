use super::PostgresPlugin;
use crate::error::Result;
use crate::protocol::ParamValue;

use super::super::capabilities::catalog_provider::{CatalogProvider, CatalogQuery};

impl CatalogProvider for PostgresPlugin {
    // INFORMATION_SCHEMA defaults work; override only foreign keys to use the
    // PG-specific KEY_COLUMN_USAGE join (default doesn't supply this).
    fn list_primary_keys_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        Ok(CatalogQuery::new(
            "SELECT tc.table_schema AS TABLE_SCHEMA, tc.table_name AS TABLE_NAME, \
                    kcu.column_name AS COLUMN_NAME, kcu.ordinal_position AS POSITION \
             FROM information_schema.table_constraints tc \
             JOIN information_schema.key_column_usage kcu \
              ON tc.constraint_name = kcu.constraint_name \
             WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_name = ? \
             ORDER BY kcu.ordinal_position",
            vec![ParamValue::String(table.to_string())],
        ))
    }

    fn list_foreign_keys_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        Ok(CatalogQuery::new(
            "SELECT tc.table_schema AS TABLE_SCHEMA, tc.table_name AS TABLE_NAME, \
                    kcu.column_name AS COLUMN_NAME, ccu.table_schema AS REFERENCED_SCHEMA, \
                    ccu.table_name AS REFERENCED_TABLE, ccu.column_name AS REFERENCED_COLUMN, \
                    kcu.ordinal_position AS POSITION \
             FROM information_schema.table_constraints tc \
             JOIN information_schema.key_column_usage kcu \
              ON tc.constraint_name = kcu.constraint_name \
             JOIN information_schema.constraint_column_usage ccu \
              ON ccu.constraint_name = tc.constraint_name \
             WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_name = ? \
             ORDER BY kcu.ordinal_position",
            vec![ParamValue::String(table.to_string())],
        ))
    }

    fn list_indexes_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        Ok(CatalogQuery::new(
            "SELECT schemaname AS TABLE_SCHEMA, tablename AS TABLE_NAME, indexname AS INDEX_NAME, \
                    NULL AS COLUMN_NAME, 0 AS COLUMN_POSITION, indexdef AS DESCEND \
             FROM pg_indexes WHERE tablename = ?",
            vec![ParamValue::String(table.to_string())],
        ))
    }
}
