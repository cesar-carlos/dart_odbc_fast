use super::SqlServerPlugin;
use crate::error::Result;
use crate::protocol::ParamValue;

use super::super::capabilities::catalog_provider::{CatalogProvider, CatalogQuery};

impl CatalogProvider for SqlServerPlugin {
    // Default INFORMATION_SCHEMA queries work; override only PK/FK/indexes
    // because INFORMATION_SCHEMA's PK reports are awkward in SQL Server —
    // sys.* DMVs are richer.
    fn list_primary_keys_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        Ok(CatalogQuery::new(
            "SELECT s.name AS TABLE_SCHEMA, t.name AS TABLE_NAME, c.name AS COLUMN_NAME, \
                    ic.key_ordinal AS POSITION \
             FROM sys.indexes i \
             JOIN sys.tables t ON i.object_id = t.object_id \
             JOIN sys.schemas s ON t.schema_id = s.schema_id \
             JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id \
             JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id \
             WHERE i.is_primary_key = 1 AND t.name = ? \
             ORDER BY ic.key_ordinal",
            vec![ParamValue::String(table.to_string())],
        ))
    }

    fn list_foreign_keys_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        Ok(CatalogQuery::new(
            "SELECT sch.name AS TABLE_SCHEMA, t.name AS TABLE_NAME, fc.name AS COLUMN_NAME, \
                    rsch.name AS REFERENCED_SCHEMA, rt.name AS REFERENCED_TABLE, \
                    rc.name AS REFERENCED_COLUMN, fkc.constraint_column_id AS POSITION \
             FROM sys.foreign_keys fk \
             JOIN sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id \
             JOIN sys.tables t ON fk.parent_object_id = t.object_id \
             JOIN sys.schemas sch ON t.schema_id = sch.schema_id \
             JOIN sys.columns fc ON fkc.parent_object_id = fc.object_id \
              AND fkc.parent_column_id = fc.column_id \
             JOIN sys.tables rt ON fk.referenced_object_id = rt.object_id \
             JOIN sys.schemas rsch ON rt.schema_id = rsch.schema_id \
             JOIN sys.columns rc ON fkc.referenced_object_id = rc.object_id \
              AND fkc.referenced_column_id = rc.column_id \
             WHERE t.name = ? ORDER BY fkc.constraint_column_id",
            vec![ParamValue::String(table.to_string())],
        ))
    }

    fn list_indexes_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        Ok(CatalogQuery::new(
            "SELECT s.name AS TABLE_SCHEMA, t.name AS TABLE_NAME, i.name AS INDEX_NAME, \
                    c.name AS COLUMN_NAME, ic.key_ordinal AS COLUMN_POSITION, \
                    CASE WHEN i.is_unique = 1 THEN 'UNIQUE' ELSE 'NON-UNIQUE' END AS DESCEND \
             FROM sys.indexes i \
             JOIN sys.tables t ON i.object_id = t.object_id \
             JOIN sys.schemas s ON t.schema_id = s.schema_id \
             JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id \
             JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id \
             WHERE t.name = ? AND i.type > 0 \
             ORDER BY i.name, ic.key_ordinal",
            vec![ParamValue::String(table.to_string())],
        ))
    }
}
