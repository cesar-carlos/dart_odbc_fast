use super::SqlitePlugin;
use crate::error::Result;
use crate::protocol::ParamValue;

use super::super::capabilities::catalog_provider::{CatalogProvider, CatalogQuery};

impl CatalogProvider for SqlitePlugin {
    fn list_tables_sql(
        &self,
        _catalog: Option<&str>,
        _schema: Option<&str>,
    ) -> Result<CatalogQuery> {
        // SQLite has neither catalogs nor schemas (only "main" + attached dbs).
        Ok(CatalogQuery::no_params(
            "SELECT NULL AS TABLE_CATALOG, NULL AS TABLE_SCHEMA, name AS TABLE_NAME, \
                    UPPER(type) AS TABLE_TYPE \
             FROM sqlite_master WHERE type IN ('table','view') \
             ORDER BY name",
        ))
    }

    fn list_columns_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        let table = table.trim().to_string();
        if table.is_empty() {
            return Err(crate::error::OdbcError::ValidationError(
                "Table name cannot be empty".to_string(),
            ));
        }
        // pragma_table_info expects the table name as a parameter when used as a virtual table.
        Ok(CatalogQuery::new(
            "SELECT NULL AS TABLE_CATALOG, NULL AS TABLE_SCHEMA, ? AS TABLE_NAME, \
                    name AS COLUMN_NAME, cid + 1 AS ORDINAL_POSITION, type AS DATA_TYPE, \
                    CASE WHEN [notnull] = 0 THEN 'YES' ELSE 'NO' END AS IS_NULLABLE, \
                    dflt_value AS COLUMN_DEFAULT \
             FROM pragma_table_info(?) ORDER BY cid",
            vec![ParamValue::String(table.clone()), ParamValue::String(table)],
        ))
    }

    fn list_primary_keys_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        let table = table.trim().to_string();
        Ok(CatalogQuery::new(
            "SELECT NULL AS TABLE_SCHEMA, ? AS TABLE_NAME, name AS COLUMN_NAME, pk AS POSITION \
             FROM pragma_table_info(?) WHERE pk > 0 ORDER BY pk",
            vec![ParamValue::String(table.clone()), ParamValue::String(table)],
        ))
    }

    fn list_foreign_keys_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        let table = table.trim().to_string();
        Ok(CatalogQuery::new(
            "SELECT NULL AS TABLE_SCHEMA, ? AS TABLE_NAME, [from] AS COLUMN_NAME, \
                    NULL AS REFERENCED_SCHEMA, [table] AS REFERENCED_TABLE, [to] AS REFERENCED_COLUMN, \
                    seq AS POSITION \
             FROM pragma_foreign_key_list(?) ORDER BY id, seq",
            vec![
                ParamValue::String(table.clone()),
                ParamValue::String(table),
            ],
        ))
    }

    fn list_indexes_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        let table = table.trim().to_string();
        Ok(CatalogQuery::new(
            "SELECT NULL AS TABLE_SCHEMA, ? AS TABLE_NAME, name AS INDEX_NAME, \
                    NULL AS COLUMN_NAME, seq AS COLUMN_POSITION, \
                    CASE WHEN [unique] = 1 THEN 'UNIQUE' ELSE 'NON-UNIQUE' END AS DESCEND \
             FROM pragma_index_list(?) ORDER BY seq",
            vec![ParamValue::String(table.clone()), ParamValue::String(table)],
        ))
    }
}
