use super::capabilities::catalog_provider::{CatalogProvider, CatalogQuery};
use super::capabilities::returning::DmlVerb;
use super::capabilities::upsert::Upsertable;
use super::capabilities::{
    IdentifierQuoter, Returnable, SessionInitializer, SessionOptions, TypeCatalog,
};
use super::driver_plugin::{DriverCapabilities, DriverPlugin, OptimizationRule};
use crate::engine::identifier::IdentifierQuoting;
use crate::error::{OdbcError, Result};
use crate::protocol::types::OdbcType;
use crate::protocol::ParamValue;

pub struct SybasePlugin;

impl Default for SybasePlugin {
    fn default() -> Self {
        Self::new()
    }
}

impl SybasePlugin {
    pub fn new() -> Self {
        Self
    }
}

impl DriverPlugin for SybasePlugin {
    fn name(&self) -> &str {
        "sybase"
    }

    fn get_capabilities(&self) -> DriverCapabilities {
        DriverCapabilities {
            supports_prepared_statements: true,
            supports_batch_operations: true,
            supports_streaming: true,
            supports_array_fetch: true,
            max_row_array_size: 500,
            driver_name: "Sybase".to_string(),
            driver_version: "Unknown".to_string(),
        }
    }

    fn map_type(&self, odbc_type: i16) -> OdbcType {
        match odbc_type {
            1 => OdbcType::Varchar,
            4 => OdbcType::Integer,
            -5 => OdbcType::BigInt,
            3 => OdbcType::Decimal,
            9 => OdbcType::Date,
            11 => OdbcType::Timestamp,
            -2 => OdbcType::Binary,
            _ => OdbcType::Varchar,
        }
    }

    fn optimize_query(&self, sql: &str) -> String {
        sql.to_string()
    }

    fn get_optimization_rules(&self) -> Vec<OptimizationRule> {
        vec![
            OptimizationRule::UsePreparedStatements,
            OptimizationRule::UseBatchOperations,
            OptimizationRule::UseArrayFetch { size: 500 },
            OptimizationRule::EnableStreaming,
        ]
    }
}

// --- v3.0 capabilities -------------------------------------------------------

impl Upsertable for SybasePlugin {
    /// Sybase ASE has no portable single-statement UPSERT; ASA supports MERGE
    /// from version 12+. The base `SybasePlugin` is conservative and rejects;
    /// callers that know they target ASA can use the dedicated `SybaseAsaPlugin`
    /// (added in v3.0 phase 5).
    fn build_upsert_sql(
        &self,
        _table: &str,
        _columns: &[&str],
        _conflict_columns: &[&str],
        _update_columns: Option<&[&str]>,
    ) -> Result<String> {
        Err(OdbcError::UnsupportedFeature(
            "Generic Sybase plugin does not implement UPSERT; \
             use SybaseAsaPlugin (MERGE-capable) when targeting SQL Anywhere"
                .to_string(),
        ))
    }
}

impl Returnable for SybasePlugin {
    fn supports_returning(&self) -> bool {
        false
    }

    fn append_returning_clause(
        &self,
        _sql: &str,
        _verb: DmlVerb,
        _columns: &[&str],
    ) -> Result<String> {
        Err(OdbcError::UnsupportedFeature(
            "Sybase does not support RETURNING; use SELECT @@IDENTITY (ASE) instead".to_string(),
        ))
    }
}

impl IdentifierQuoter for SybasePlugin {
    fn quoting_style(&self) -> IdentifierQuoting {
        // ASE uses brackets / "double quotes" (with QUOTED_IDENTIFIER ON);
        // ASA accepts both. Default to brackets since they're always safe in ASE.
        IdentifierQuoting::Brackets
    }
}

impl TypeCatalog for SybasePlugin {
    fn map_type_extended(&self, sql_type: i16, type_name: Option<&str>) -> OdbcType {
        if let Some(name) = type_name {
            let lower = name.trim().to_ascii_lowercase();
            match lower.as_str() {
                "money" | "smallmoney" => return OdbcType::Money,
                "bit" => return OdbcType::Boolean,
                "tinyint" | "smallint" => return OdbcType::SmallInt,
                "real" => return OdbcType::Float,
                "float" | "double precision" => return OdbcType::Double,
                "image" | "varbinary" | "binary" => return OdbcType::Binary,
                "nvarchar" | "nchar" | "univarchar" | "unichar" => return OdbcType::NVarchar,
                "time" => return OdbcType::Time,
                _ => {}
            }
        }
        self.map_type(sql_type)
    }
}

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

impl SessionInitializer for SybasePlugin {
    fn initialization_sql(&self, opts: &SessionOptions) -> Vec<String> {
        let mut out = vec![
            "SET QUOTED_IDENTIFIER ON".to_string(),
            "SET CHAINED OFF".to_string(),
        ];
        for raw in &opts.extra_sql {
            out.push(raw.clone());
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sybase_plugin_new() {
        let plugin = SybasePlugin::new();
        assert_eq!(plugin.name(), "sybase");
    }

    #[test]
    fn test_sybase_plugin_default() {
        let plugin = SybasePlugin;
        assert_eq!(plugin.name(), "sybase");
    }

    #[test]
    fn test_sybase_plugin_name() {
        let plugin = SybasePlugin::new();
        assert_eq!(plugin.name(), "sybase");
    }

    #[test]
    fn test_sybase_plugin_capabilities() {
        let plugin = SybasePlugin::new();
        let caps = plugin.get_capabilities();

        assert!(caps.supports_prepared_statements);
        assert!(caps.supports_batch_operations);
        assert!(caps.supports_streaming);
        assert!(caps.supports_array_fetch);
        assert_eq!(caps.max_row_array_size, 500);
        assert_eq!(caps.driver_name, "Sybase");
        assert_eq!(caps.driver_version, "Unknown");
    }

    #[test]
    fn test_sybase_plugin_map_type() {
        let plugin = SybasePlugin::new();

        assert_eq!(plugin.map_type(1), OdbcType::Varchar);
        assert_eq!(plugin.map_type(4), OdbcType::Integer);
        assert_eq!(plugin.map_type(-5), OdbcType::BigInt);
        assert_eq!(plugin.map_type(3), OdbcType::Decimal);
        assert_eq!(plugin.map_type(9), OdbcType::Date);
        assert_eq!(plugin.map_type(11), OdbcType::Timestamp);
        assert_eq!(plugin.map_type(-2), OdbcType::Binary);
        assert_eq!(plugin.map_type(99), OdbcType::Varchar); // Default case
    }

    #[test]
    fn test_sybase_plugin_optimize_query_no_change() {
        let plugin = SybasePlugin::new();

        let sql = "SELECT * FROM users";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users");
    }

    #[test]
    fn test_sybase_plugin_optimize_query_preserves_original() {
        let plugin = SybasePlugin::new();

        let sql = "SELECT id, name FROM users WHERE id > 10";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT id, name FROM users WHERE id > 10");
    }

    #[test]
    fn test_sybase_plugin_get_optimization_rules() {
        let plugin = SybasePlugin::new();
        let rules = plugin.get_optimization_rules();

        assert_eq!(rules.len(), 4);
        assert!(matches!(rules[0], OptimizationRule::UsePreparedStatements));
        assert!(matches!(rules[1], OptimizationRule::UseBatchOperations));
        assert!(matches!(
            rules[2],
            OptimizationRule::UseArrayFetch { size: 500 }
        ));
        assert!(matches!(rules[3], OptimizationRule::EnableStreaming));
    }
}
