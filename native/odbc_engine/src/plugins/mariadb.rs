//! MariaDB plugin (NEW in v3.0).
//!
//! MariaDB is wire-compatible with MySQL but adds:
//! - `RETURNING` clause (MariaDB 10.5+)
//! - `INSERT ... ON DUPLICATE KEY UPDATE` (same as MySQL)
//!
//! Until v3.0 the registry mapped MariaDB to the MySQL plugin; this dedicated
//! plugin enables RETURNING and provides MariaDB-specific type mapping.

use super::capabilities::catalog_provider::CatalogProvider;
use super::capabilities::returning::{quote_returning_columns, DmlVerb};
use super::capabilities::upsert::{
    effective_update_columns, placeholder_list, quote_columns, validate_upsert_inputs, Upsertable,
};
use super::capabilities::{
    IdentifierQuoter, Returnable, SessionInitializer, SessionOptions, TypeCatalog,
};
use super::driver_plugin::{DriverCapabilities, DriverPlugin, OptimizationRule};
use crate::engine::identifier::{quote_identifier, quote_qualified_default, IdentifierQuoting};
use crate::error::Result;
use crate::protocol::types::OdbcType;

pub struct MariaDbPlugin;

impl Default for MariaDbPlugin {
    fn default() -> Self {
        Self::new()
    }
}

impl MariaDbPlugin {
    pub fn new() -> Self {
        Self
    }
}

impl DriverPlugin for MariaDbPlugin {
    fn name(&self) -> &str {
        "mariadb"
    }

    fn get_capabilities(&self) -> DriverCapabilities {
        DriverCapabilities {
            supports_prepared_statements: true,
            supports_batch_operations: true,
            supports_streaming: true,
            supports_array_fetch: true,
            max_row_array_size: 1500,
            driver_name: "MariaDB".to_string(),
            driver_version: "Unknown".to_string(),
        }
    }

    fn map_type(&self, odbc_type: i16) -> OdbcType {
        OdbcType::from_odbc_sql_type(odbc_type)
    }

    fn optimize_query(&self, sql: &str) -> String {
        let mut optimized = sql.to_string();
        if optimized.contains("SELECT") && !optimized.to_uppercase().contains(" LIMIT") {
            if let Some(pos) = optimized.rfind(';') {
                optimized.insert_str(pos, " LIMIT 1000");
            } else if !optimized.to_uppercase().contains(" WHERE")
                && !optimized.to_uppercase().contains(" ORDER BY")
            {
                optimized.push_str(" LIMIT 1000");
            }
        }
        optimized
    }

    fn get_optimization_rules(&self) -> Vec<OptimizationRule> {
        vec![
            OptimizationRule::UsePreparedStatements,
            OptimizationRule::UseBatchOperations,
            OptimizationRule::UseArrayFetch { size: 1500 },
            OptimizationRule::EnableStreaming,
        ]
    }
}

impl Upsertable for MariaDbPlugin {
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
        let updates = effective_update_columns(columns, conflict_columns, update_columns);
        let placeholders = placeholder_list(columns.len());

        let set_parts = updates
            .iter()
            .map(|c| -> Result<String> {
                let q = quote_identifier(c, IdentifierQuoting::Backtick)?;
                Ok(format!("{q} = VALUES({q})"))
            })
            .collect::<Result<Vec<_>>>()?;
        let set_clause = if set_parts.is_empty() {
            "id = id".to_string()
        } else {
            set_parts.join(", ")
        };
        Ok(format!(
            "INSERT INTO {qtable} ({qcols}) VALUES ({placeholders}) \
             ON DUPLICATE KEY UPDATE {set_clause}"
        ))
    }
}

impl Returnable for MariaDbPlugin {
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

impl IdentifierQuoter for MariaDbPlugin {
    fn quoting_style(&self) -> IdentifierQuoting {
        IdentifierQuoting::Backtick
    }
}

impl TypeCatalog for MariaDbPlugin {
    fn map_type_extended(&self, sql_type: i16, type_name: Option<&str>) -> OdbcType {
        if let Some(name) = type_name {
            let lower = name.trim().to_ascii_lowercase();
            match lower.as_str() {
                "json" | "longtext" if lower.contains("json") => return OdbcType::Json,
                "json" => return OdbcType::Json,
                "tinyint(1)" | "boolean" | "bool" => return OdbcType::Boolean,
                "uuid" => return OdbcType::Uuid, // MariaDB 10.7+
                "double" | "double precision" | "real" => return OdbcType::Double,
                "blob" | "tinyblob" | "mediumblob" | "longblob" | "varbinary" => {
                    return OdbcType::Binary
                }
                _ => {}
            }
        }
        self.map_type(sql_type)
    }
}

// MariaDB shares the MySQL catalog implementation (same INFORMATION_SCHEMA shape)
// — implements the trait via the default INFORMATION_SCHEMA helpers.
impl CatalogProvider for MariaDbPlugin {
    fn list_primary_keys_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        Ok(CatalogQuery::new(
            "SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION AS POSITION \
             FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE \
             WHERE CONSTRAINT_NAME = 'PRIMARY' AND TABLE_NAME = ? \
             ORDER BY ORDINAL_POSITION",
            vec![crate::protocol::ParamValue::String(table.to_string())],
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
            vec![crate::protocol::ParamValue::String(table.to_string())],
        ))
    }

    fn list_indexes_sql(&self, table: &str, _schema: Option<&str>) -> Result<CatalogQuery> {
        Ok(CatalogQuery::new(
            "SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, COLUMN_NAME, SEQ_IN_INDEX AS COLUMN_POSITION, \
                    CASE WHEN NON_UNIQUE = 0 THEN 'UNIQUE' ELSE 'NON-UNIQUE' END AS DESCEND \
             FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_NAME = ? \
             ORDER BY INDEX_NAME, SEQ_IN_INDEX",
            vec![crate::protocol::ParamValue::String(table.to_string())],
        ))
    }
}

// Bring CatalogQuery into scope for the impl above.
use super::capabilities::catalog_provider::CatalogQuery;

impl SessionInitializer for MariaDbPlugin {
    fn initialization_sql(&self, opts: &SessionOptions) -> Vec<String> {
        let mut out = Vec::new();
        let charset = opts.charset.as_deref().unwrap_or("utf8mb4");
        out.push(format!("SET NAMES {}", charset.replace('\'', "")));
        if let Some(tz) = opts.timezone.as_deref() {
            out.push(format!("SET time_zone = '{}'", tz.replace('\'', "''")));
        }
        if let Some(schema) = opts.schema.as_deref() {
            if let Ok(q) = quote_identifier(schema, IdentifierQuoting::Backtick) {
                out.push(format!("USE {q}"));
            }
        }
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
    fn name_is_mariadb() {
        assert_eq!(MariaDbPlugin::new().name(), "mariadb");
    }

    #[test]
    fn supports_returning() {
        let p = MariaDbPlugin::new();
        assert!(p.supports_returning());
    }

    #[test]
    fn upsert_uses_on_duplicate_key_with_backticks() {
        let p = MariaDbPlugin::new();
        let sql = p
            .build_upsert_sql("u", &["id", "name"], &["id"], None)
            .unwrap();
        assert!(sql.contains("ON DUPLICATE KEY UPDATE"));
        assert!(sql.contains("`name` = VALUES(`name`)"));
    }

    #[test]
    fn upsert_with_no_updates_uses_self_assignment() {
        let p = MariaDbPlugin::new();
        let sql = p.build_upsert_sql("u", &["id"], &["id"], None).unwrap();
        assert!(sql.contains("ON DUPLICATE KEY UPDATE"));
    }

    #[test]
    fn type_catalog_recognises_uuid_as_uuid() {
        let p = MariaDbPlugin::new();
        assert_eq!(p.map_type_extended(1, Some("UUID")), OdbcType::Uuid);
    }
}
