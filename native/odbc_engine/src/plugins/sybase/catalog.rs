use super::SybasePlugin;
use crate::error::Result;
use crate::protocol::ParamValue;

use super::super::capabilities::catalog_provider::{CatalogProvider, CatalogQuery};

impl CatalogProvider for SybasePlugin {
    fn list_tables_sql(
        &self,
        _catalog: Option<&str>,
        _schema: Option<&str>,
    ) -> Result<CatalogQuery> {
        // Sybase ASE catalog via sysobjects (type 'U' = user table, 'V' = view).
        Ok(CatalogQuery::no_params(
            "SELECT db_name() AS TABLE_CATALOG, user_name(uid) AS TABLE_SCHEMA, \
                    name AS TABLE_NAME, \
                    CASE type WHEN 'U' THEN 'BASE TABLE' WHEN 'V' THEN 'VIEW' ELSE type END AS TABLE_TYPE \
             FROM sysobjects WHERE type IN ('U','V') ORDER BY name",
        ))
    }

    fn list_columns_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        let table = table.trim().to_string();
        Ok(CatalogQuery::new(
            "SELECT db_name() AS TABLE_CATALOG, user_name(o.uid) AS TABLE_SCHEMA, \
                    o.name AS TABLE_NAME, c.name AS COLUMN_NAME, c.colid AS ORDINAL_POSITION, \
                    type_name(c.usertype) AS DATA_TYPE, \
                    CASE WHEN (c.status & 8) = 0 THEN 'NO' ELSE 'YES' END AS IS_NULLABLE, \
                    NULL AS COLUMN_DEFAULT \
             FROM sysobjects o JOIN syscolumns c ON o.id = c.id \
             WHERE o.name = ? AND o.type = 'U' ORDER BY c.colid",
            vec![ParamValue::String(table)],
        ))
    }

    fn list_primary_keys_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        // Sybase ASE: primary key columns are derived from sysindexes + syscolumns.
        Ok(CatalogQuery::new(
            "SELECT user_name(o.uid) AS TABLE_SCHEMA, o.name AS TABLE_NAME, \
                    c.name AS COLUMN_NAME, ik.colid AS POSITION \
             FROM sysobjects o \
             JOIN sysindexes i ON o.id = i.id AND i.status & 2048 = 2048 \
             JOIN sysindexkeys ik ON i.id = ik.id AND i.indid = ik.indid \
             JOIN syscolumns c ON ik.id = c.id AND ik.colid = c.colid \
             WHERE o.name = ? ORDER BY ik.colid",
            vec![ParamValue::String(table.to_string())],
        ))
    }

    fn list_foreign_keys_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        Ok(CatalogQuery::new(
            "SELECT user_name(o.uid) AS TABLE_SCHEMA, o.name AS TABLE_NAME, \
                    fc.name AS COLUMN_NAME, user_name(po.uid) AS REFERENCED_SCHEMA, \
                    po.name AS REFERENCED_TABLE, pc.name AS REFERENCED_COLUMN, \
                    1 AS POSITION \
             FROM sysreferences r \
             JOIN sysobjects o ON r.tableid = o.id \
             JOIN sysobjects po ON r.reftabid = po.id \
             JOIN syscolumns fc ON r.tableid = fc.id AND r.fokey1 = fc.colid \
             JOIN syscolumns pc ON r.reftabid = pc.id AND r.refkey1 = pc.colid \
             WHERE o.name = ?",
            vec![ParamValue::String(table.to_string())],
        ))
    }

    fn list_indexes_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        Ok(CatalogQuery::new(
            "SELECT user_name(o.uid) AS TABLE_SCHEMA, o.name AS TABLE_NAME, \
                    i.name AS INDEX_NAME, c.name AS COLUMN_NAME, ik.colid AS COLUMN_POSITION, \
                    CASE WHEN i.status & 2 = 2 THEN 'UNIQUE' ELSE 'NON-UNIQUE' END AS DESCEND \
             FROM sysobjects o JOIN sysindexes i ON o.id = i.id \
             JOIN sysindexkeys ik ON i.id = ik.id AND i.indid = ik.indid \
             JOIN syscolumns c ON ik.id = c.id AND ik.colid = c.colid \
             WHERE o.name = ? AND i.indid > 0 ORDER BY i.name, ik.colid",
            vec![ParamValue::String(table.to_string())],
        ))
    }
}
