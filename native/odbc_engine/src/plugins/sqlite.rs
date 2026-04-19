//! SQLite plugin (NEW in v3.0).
//!
//! SQLite is unusual:
//! - dynamic typing (storage classes vs declared types)
//! - no `LIMIT` rewrite needed (file-based, sub-millisecond planning)
//! - `ON CONFLICT` clause supported since 3.24
//! - `RETURNING` supported since 3.35

use super::capabilities::catalog_provider::{CatalogProvider, CatalogQuery};
use super::capabilities::returning::{quote_returning_columns, DmlVerb};
use super::capabilities::upsert::{
    effective_update_columns, placeholder_list, quote_columns, validate_upsert_inputs, Upsertable,
};
use super::capabilities::{
    IdentifierQuoter, Returnable, SessionInitializer, SessionOptions, TypeCatalog,
};
use super::driver_plugin::{DriverCapabilities, DriverPlugin, OptimizationRule};
use crate::engine::identifier::{quote_identifier_default, quote_qualified_default};
use crate::error::Result;
use crate::protocol::types::OdbcType;
use crate::protocol::ParamValue;

pub struct SqlitePlugin;

impl Default for SqlitePlugin {
    fn default() -> Self {
        Self::new()
    }
}

impl SqlitePlugin {
    pub fn new() -> Self {
        Self
    }
}

impl DriverPlugin for SqlitePlugin {
    fn name(&self) -> &str {
        "sqlite"
    }

    fn get_capabilities(&self) -> DriverCapabilities {
        DriverCapabilities {
            supports_prepared_statements: true,
            supports_batch_operations: true,
            supports_streaming: true,
            supports_array_fetch: true,
            max_row_array_size: 1000,
            driver_name: "SQLite".to_string(),
            driver_version: "Unknown".to_string(),
        }
    }

    fn map_type(&self, odbc_type: i16) -> OdbcType {
        // SQLite ODBC drivers (e.g. SQLite ODBC by Christian Werner) usually
        // report storage classes via SQL types; honour the standard mapping.
        OdbcType::from_odbc_sql_type(odbc_type)
    }

    fn optimize_query(&self, sql: &str) -> String {
        // No automatic LIMIT injection: SQLite is file-based and the planner
        // is fast enough that the heuristic LIMIT 1000 used by other drivers
        // would surprise users.
        sql.to_string()
    }

    fn get_optimization_rules(&self) -> Vec<OptimizationRule> {
        vec![
            OptimizationRule::UsePreparedStatements,
            OptimizationRule::UseBatchOperations,
            OptimizationRule::UseArrayFetch { size: 1000 },
        ]
    }
}

impl Upsertable for SqlitePlugin {
    fn build_upsert_sql(
        &self,
        table: &str,
        columns: &[&str],
        conflict_columns: &[&str],
        update_columns: Option<&[&str]>,
    ) -> Result<String> {
        validate_upsert_inputs(table, columns, conflict_columns, update_columns)?;
        let qtable = quote_qualified_default(table)?;
        let qcols = quote_columns(columns)?;
        let qconflict = quote_columns(conflict_columns)?;
        let updates = effective_update_columns(columns, conflict_columns, update_columns);
        let placeholders = placeholder_list(columns.len());

        if updates.is_empty() {
            return Ok(format!(
                "INSERT INTO {qtable} ({qcols}) VALUES ({placeholders}) \
                 ON CONFLICT ({qconflict}) DO NOTHING"
            ));
        }
        let mut set_parts = Vec::with_capacity(updates.len());
        for c in &updates {
            let q = quote_identifier_default(c)?;
            set_parts.push(format!("{q} = excluded.{q}"));
        }
        let set_clause = set_parts.join(", ");
        Ok(format!(
            "INSERT INTO {qtable} ({qcols}) VALUES ({placeholders}) \
             ON CONFLICT ({qconflict}) DO UPDATE SET {set_clause}"
        ))
    }
}

impl Returnable for SqlitePlugin {
    fn supports_returning(&self) -> bool {
        true
    }

    fn append_returning_clause(
        &self,
        sql: &str,
        _verb: DmlVerb,
        columns: &[&str],
    ) -> Result<String> {
        let proj = quote_returning_columns(columns)?;
        Ok(format!("{} RETURNING {proj}", sql.trim_end_matches(';')))
    }
}

impl IdentifierQuoter for SqlitePlugin {
    // SQLite accepts double-quotes (ANSI) and backticks (MySQL-compat) and
    // brackets (T-SQL-compat). Default to double-quotes.
}

impl TypeCatalog for SqlitePlugin {
    fn map_type_extended(&self, sql_type: i16, type_name: Option<&str>) -> OdbcType {
        if let Some(name) = type_name {
            // SQLite's "type affinity" — five storage classes derive from
            // declared types.
            let lower = name.trim().to_ascii_lowercase();
            if lower.contains("int") {
                return OdbcType::Integer;
            }
            if lower.contains("char") || lower.contains("text") || lower.contains("clob") {
                return OdbcType::Varchar;
            }
            if lower.contains("blob") {
                return OdbcType::Binary;
            }
            if lower.contains("real") || lower.contains("floa") || lower.contains("doub") {
                return OdbcType::Double;
            }
            if lower == "boolean" || lower == "bool" {
                return OdbcType::Boolean;
            }
            // Numeric / decimal affinity defaults to Decimal.
            return OdbcType::Decimal;
        }
        self.map_type(sql_type)
    }
}

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

impl SessionInitializer for SqlitePlugin {
    fn initialization_sql(&self, opts: &SessionOptions) -> Vec<String> {
        let mut out = vec![
            "PRAGMA foreign_keys = ON".to_string(),
            "PRAGMA journal_mode = WAL".to_string(),
            "PRAGMA synchronous = NORMAL".to_string(),
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
    fn name_is_sqlite() {
        assert_eq!(SqlitePlugin::new().name(), "sqlite");
    }

    #[test]
    fn optimize_query_is_identity() {
        let p = SqlitePlugin::new();
        assert_eq!(p.optimize_query("SELECT * FROM t"), "SELECT * FROM t");
    }

    #[test]
    fn upsert_uses_excluded_qualifier() {
        let p = SqlitePlugin::new();
        let sql = p
            .build_upsert_sql("users", &["id", "name"], &["id"], None)
            .unwrap();
        assert!(sql.contains("ON CONFLICT (\"id\")"));
        assert!(sql.contains("DO UPDATE SET \"name\" = excluded.\"name\""));
    }

    #[test]
    fn upsert_with_no_update_columns_does_nothing() {
        let p = SqlitePlugin::new();
        let sql = p.build_upsert_sql("t", &["id"], &["id"], None).unwrap();
        assert!(sql.contains("DO NOTHING"));
    }

    #[test]
    fn returning_appended_after_dml() {
        let p = SqlitePlugin::new();
        let r = p
            .append_returning_clause("INSERT INTO t (a) VALUES (?)", DmlVerb::Insert, &["id"])
            .unwrap();
        assert!(r.ends_with("RETURNING \"id\""));
    }

    #[test]
    fn type_catalog_recognises_sqlite_storage_classes() {
        let p = SqlitePlugin::new();
        assert_eq!(p.map_type_extended(1, Some("INTEGER")), OdbcType::Integer);
        assert_eq!(p.map_type_extended(1, Some("VARCHAR")), OdbcType::Varchar);
        assert_eq!(p.map_type_extended(1, Some("BLOB")), OdbcType::Binary);
        assert_eq!(p.map_type_extended(1, Some("REAL")), OdbcType::Double);
        assert_eq!(p.map_type_extended(1, Some("BOOLEAN")), OdbcType::Boolean);
    }

    #[test]
    fn session_init_sets_pragmas() {
        let p = SqlitePlugin::new();
        let stmts = p.initialization_sql(&SessionOptions::default());
        assert!(stmts.iter().any(|s| s.contains("foreign_keys")));
        assert!(stmts.iter().any(|s| s.contains("journal_mode")));
    }
}
