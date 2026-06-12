use super::OraclePlugin;
use crate::error::Result;
use crate::protocol::ParamValue;

use super::super::capabilities::catalog_provider::{CatalogProvider, CatalogQuery};

impl CatalogProvider for OraclePlugin {
    fn list_tables_sql(
        &self,
        _catalog: Option<&str>,
        schema: Option<&str>,
    ) -> Result<CatalogQuery> {
        // Oracle has no INFORMATION_SCHEMA. Use ALL_TABLES (cross-schema if user has perms);
        // when `schema` is empty, prefer USER_TABLES (current user's objects).
        match schema {
            Some(s) if !s.trim().is_empty() => Ok(CatalogQuery::new(
                "SELECT NULL AS TABLE_CATALOG, OWNER AS TABLE_SCHEMA, TABLE_NAME, \
                        'BASE TABLE' AS TABLE_TYPE \
                 FROM ALL_TABLES \
                 WHERE OWNER = ? \
                 ORDER BY TABLE_NAME",
                vec![ParamValue::String(s.trim().to_string())],
            )),
            _ => Ok(CatalogQuery::no_params(
                "SELECT NULL AS TABLE_CATALOG, USER AS TABLE_SCHEMA, TABLE_NAME, \
                        'BASE TABLE' AS TABLE_TYPE \
                 FROM USER_TABLES ORDER BY TABLE_NAME",
            )),
        }
    }

    fn list_columns_sql(&self, table: &str, schema: Option<&str>) -> Result<CatalogQuery> {
        let table = table.trim().to_string();
        if table.is_empty() {
            return Err(crate::error::OdbcError::ValidationError(
                "Table name cannot be empty".to_string(),
            ));
        }
        match schema {
            Some(s) if !s.trim().is_empty() => Ok(CatalogQuery::new(
                "SELECT NULL AS TABLE_CATALOG, OWNER AS TABLE_SCHEMA, TABLE_NAME, \
                        COLUMN_NAME, COLUMN_ID AS ORDINAL_POSITION, DATA_TYPE, \
                        NULLABLE AS IS_NULLABLE, DATA_DEFAULT AS COLUMN_DEFAULT \
                 FROM ALL_TAB_COLUMNS \
                 WHERE TABLE_NAME = ? AND OWNER = ? \
                 ORDER BY COLUMN_ID",
                vec![
                    ParamValue::String(table),
                    ParamValue::String(s.trim().to_string()),
                ],
            )),
            _ => Ok(CatalogQuery::new(
                "SELECT NULL AS TABLE_CATALOG, USER AS TABLE_SCHEMA, TABLE_NAME, \
                        COLUMN_NAME, COLUMN_ID AS ORDINAL_POSITION, DATA_TYPE, \
                        NULLABLE AS IS_NULLABLE, DATA_DEFAULT AS COLUMN_DEFAULT \
                 FROM USER_TAB_COLUMNS WHERE TABLE_NAME = ? ORDER BY COLUMN_ID",
                vec![ParamValue::String(table)],
            )),
        }
    }

    fn list_primary_keys_sql(&self, table: &str, schema: Option<&str>) -> Result<CatalogQuery> {
        let table = table.trim().to_string();
        match schema {
            Some(s) if !s.trim().is_empty() => Ok(CatalogQuery::new(
                "SELECT cc.OWNER AS TABLE_SCHEMA, cc.TABLE_NAME, cc.COLUMN_NAME, cc.POSITION \
                 FROM ALL_CONSTRAINTS c \
                 JOIN ALL_CONS_COLUMNS cc ON c.OWNER = cc.OWNER \
                  AND c.CONSTRAINT_NAME = cc.CONSTRAINT_NAME \
                 WHERE c.CONSTRAINT_TYPE = 'P' AND c.TABLE_NAME = ? AND c.OWNER = ? \
                 ORDER BY cc.POSITION",
                vec![
                    ParamValue::String(table),
                    ParamValue::String(s.trim().to_string()),
                ],
            )),
            _ => Ok(CatalogQuery::new(
                "SELECT USER AS TABLE_SCHEMA, cc.TABLE_NAME, cc.COLUMN_NAME, cc.POSITION \
                 FROM USER_CONSTRAINTS c \
                 JOIN USER_CONS_COLUMNS cc ON c.CONSTRAINT_NAME = cc.CONSTRAINT_NAME \
                 WHERE c.CONSTRAINT_TYPE = 'P' AND c.TABLE_NAME = ? \
                 ORDER BY cc.POSITION",
                vec![ParamValue::String(table)],
            )),
        }
    }

    fn list_foreign_keys_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        Ok(CatalogQuery::new(
            "SELECT a.OWNER AS TABLE_SCHEMA, a.TABLE_NAME, a.COLUMN_NAME, \
                    c_pk.OWNER AS REFERENCED_SCHEMA, c_pk.TABLE_NAME AS REFERENCED_TABLE, \
                    b.COLUMN_NAME AS REFERENCED_COLUMN, a.POSITION \
             FROM ALL_CONS_COLUMNS a \
             JOIN ALL_CONSTRAINTS c ON a.OWNER = c.OWNER AND a.CONSTRAINT_NAME = c.CONSTRAINT_NAME \
             JOIN ALL_CONSTRAINTS c_pk ON c.R_OWNER = c_pk.OWNER \
                  AND c.R_CONSTRAINT_NAME = c_pk.CONSTRAINT_NAME \
             JOIN ALL_CONS_COLUMNS b ON c_pk.OWNER = b.OWNER \
                  AND c_pk.CONSTRAINT_NAME = b.CONSTRAINT_NAME AND a.POSITION = b.POSITION \
             WHERE c.CONSTRAINT_TYPE = 'R' AND a.TABLE_NAME = ? \
             ORDER BY a.POSITION",
            vec![ParamValue::String(table.to_string())],
        ))
    }

    fn list_indexes_sql(&self, table: &str, schema: Option<&str>) -> Result<CatalogQuery> {
        let table = table.trim().to_string();
        match schema {
            Some(s) if !s.trim().is_empty() => Ok(CatalogQuery::new(
                "SELECT INDEX_OWNER AS TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, COLUMN_NAME, \
                        COLUMN_POSITION, DESCEND \
                 FROM ALL_IND_COLUMNS \
                 WHERE TABLE_NAME = ? AND INDEX_OWNER = ? \
                 ORDER BY INDEX_NAME, COLUMN_POSITION",
                vec![
                    ParamValue::String(table),
                    ParamValue::String(s.trim().to_string()),
                ],
            )),
            _ => Ok(CatalogQuery::new(
                "SELECT USER AS TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, COLUMN_NAME, \
                        COLUMN_POSITION, DESCEND \
                 FROM USER_IND_COLUMNS WHERE TABLE_NAME = ? \
                 ORDER BY INDEX_NAME, COLUMN_POSITION",
                vec![ParamValue::String(table)],
            )),
        }
    }
}
