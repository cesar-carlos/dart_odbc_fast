//! Driver-specific catalog SQL.
//!
//! Replaces hard-coded `INFORMATION_SCHEMA.*` queries with dialect-aware
//! lookups (`ALL_TABLES` for Oracle, `sysobjects` for Sybase ASE,
//! `sqlite_master` for SQLite, `SYSCAT.TABLES` for Db2, ...).

use crate::error::Result;
use crate::protocol::ParamValue;

/// A fully-built catalog query: SQL string + ordered parameters.
#[derive(Debug, Clone)]
pub struct CatalogQuery {
    pub sql: String,
    pub params: Vec<ParamValue>,
}

impl CatalogQuery {
    pub fn new(sql: impl Into<String>, params: Vec<ParamValue>) -> Self {
        Self {
            sql: sql.into(),
            params,
        }
    }

    pub fn no_params(sql: impl Into<String>) -> Self {
        Self::new(sql, Vec::new())
    }
}

/// Default `INFORMATION_SCHEMA`-based queries (works for SQL Server, PG,
/// MySQL/MariaDB). Plugins for engines without `INFORMATION_SCHEMA` (Oracle,
/// Sybase ASE, SQLite, Db2) override these methods.
pub mod defaults {
    use super::*;
    use crate::protocol::ParamValue;

    pub fn list_tables(catalog: Option<&str>, schema: Option<&str>) -> Result<CatalogQuery> {
        let cat = catalog.unwrap_or("").trim();
        let sch = schema.unwrap_or("").trim();
        match (cat.is_empty(), sch.is_empty()) {
            (true, true) => Ok(CatalogQuery::no_params(
                "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE \
                 FROM INFORMATION_SCHEMA.TABLES \
                 WHERE TABLE_TYPE IN ('BASE TABLE','VIEW') \
                 ORDER BY TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME",
            )),
            (false, true) => Ok(CatalogQuery::new(
                "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE \
                 FROM INFORMATION_SCHEMA.TABLES \
                 WHERE TABLE_TYPE IN ('BASE TABLE','VIEW') AND TABLE_CATALOG = ? \
                 ORDER BY TABLE_SCHEMA, TABLE_NAME",
                vec![ParamValue::String(cat.to_string())],
            )),
            (true, false) => Ok(CatalogQuery::new(
                "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE \
                 FROM INFORMATION_SCHEMA.TABLES \
                 WHERE TABLE_TYPE IN ('BASE TABLE','VIEW') AND TABLE_SCHEMA = ? \
                 ORDER BY TABLE_NAME",
                vec![ParamValue::String(sch.to_string())],
            )),
            (false, false) => Ok(CatalogQuery::new(
                "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE \
                 FROM INFORMATION_SCHEMA.TABLES \
                 WHERE TABLE_TYPE IN ('BASE TABLE','VIEW') \
                 AND TABLE_CATALOG = ? AND TABLE_SCHEMA = ? \
                 ORDER BY TABLE_NAME",
                vec![
                    ParamValue::String(cat.to_string()),
                    ParamValue::String(sch.to_string()),
                ],
            )),
        }
    }

    pub fn list_columns(table: &str, schema: Option<&str>) -> Result<CatalogQuery> {
        let table = table.trim().to_string();
        if table.is_empty() {
            return Err(crate::error::OdbcError::ValidationError(
                "Table name cannot be empty".to_string(),
            ));
        }
        match schema {
            Some(s) if !s.trim().is_empty() => Ok(CatalogQuery::new(
                "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, \
                        ORDINAL_POSITION, DATA_TYPE, IS_NULLABLE, COLUMN_DEFAULT \
                 FROM INFORMATION_SCHEMA.COLUMNS \
                 WHERE TABLE_NAME = ? AND TABLE_SCHEMA = ? \
                 ORDER BY ORDINAL_POSITION",
                vec![
                    ParamValue::String(table),
                    ParamValue::String(s.trim().to_string()),
                ],
            )),
            _ => Ok(CatalogQuery::new(
                "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, \
                        ORDINAL_POSITION, DATA_TYPE, IS_NULLABLE, COLUMN_DEFAULT \
                 FROM INFORMATION_SCHEMA.COLUMNS \
                 WHERE TABLE_NAME = ? \
                 ORDER BY ORDINAL_POSITION",
                vec![ParamValue::String(table)],
            )),
        }
    }
}

/// Capability trait for engines whose catalog queries differ from the
/// `INFORMATION_SCHEMA` baseline.
///
/// All methods have INFORMATION_SCHEMA-based defaults; plugins for engines
/// without that view (Oracle, Sybase, SQLite, Db2) override what they need.
pub trait CatalogProvider: Send + Sync {
    fn list_tables_sql(&self, catalog: Option<&str>, schema: Option<&str>) -> Result<CatalogQuery> {
        defaults::list_tables(catalog, schema)
    }
    fn list_columns_sql(&self, table: &str, schema: Option<&str>) -> Result<CatalogQuery> {
        defaults::list_columns(table, schema)
    }
    fn list_primary_keys_sql(&self, table: &str, schema: Option<&str>) -> Result<CatalogQuery>;
    fn list_foreign_keys_sql(&self, table: &str, schema: Option<&str>) -> Result<CatalogQuery>;
    fn list_indexes_sql(&self, table: &str, schema: Option<&str>) -> Result<CatalogQuery>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_query_no_params_is_empty() {
        let q = CatalogQuery::no_params("SELECT 1");
        assert_eq!(q.sql, "SELECT 1");
        assert!(q.params.is_empty());
    }

    #[test]
    fn catalog_query_carries_params() {
        let q = CatalogQuery::new(
            "SELECT * FROM t WHERE x = ?",
            vec![ParamValue::String("a".to_string())],
        );
        assert_eq!(q.sql, "SELECT * FROM t WHERE x = ?");
        assert_eq!(q.params.len(), 1);
    }
}
