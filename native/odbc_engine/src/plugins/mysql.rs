use super::capabilities::bulk_loader::{BulkLoadOptions, BulkLoader};
use super::capabilities::catalog_provider::{CatalogProvider, CatalogQuery};
use super::capabilities::returning::DmlVerb;
use super::capabilities::upsert::{
    effective_update_columns, placeholder_list, quote_columns, validate_upsert_inputs, Upsertable,
};
use super::capabilities::{
    IdentifierQuoter, Returnable, SessionInitializer, SessionOptions, TypeCatalog,
};
use super::driver_plugin::{DriverCapabilities, DriverPlugin, OptimizationRule};
use crate::engine::core::ArrayBinding;
use crate::engine::identifier::{quote_identifier, quote_qualified_default, IdentifierQuoting};
use crate::error::{OdbcError, Result};
use crate::protocol::types::OdbcType;
use crate::protocol::BulkInsertPayload;
use crate::protocol::ParamValue;
use odbc_api::Connection;

pub struct MySqlPlugin;

impl Default for MySqlPlugin {
    fn default() -> Self {
        Self::new()
    }
}

impl MySqlPlugin {
    pub fn new() -> Self {
        Self
    }
}

impl DriverPlugin for MySqlPlugin {
    fn name(&self) -> &str {
        "mysql"
    }

    fn get_capabilities(&self) -> DriverCapabilities {
        DriverCapabilities {
            supports_prepared_statements: true,
            supports_batch_operations: true,
            supports_streaming: true,
            supports_array_fetch: true,
            max_row_array_size: 1000,
            driver_name: "MySQL".to_string(),
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
        let mut optimized = sql.to_string();

        if optimized.contains("SELECT") && !optimized.contains("LIMIT") {
            if let Some(pos) = optimized.rfind(';') {
                optimized.insert_str(pos, " LIMIT 1000");
            } else if !optimized.contains("WHERE") && !optimized.contains("ORDER BY") {
                optimized.push_str(" LIMIT 1000");
            }
        }

        optimized
    }

    fn get_optimization_rules(&self) -> Vec<OptimizationRule> {
        vec![
            OptimizationRule::UsePreparedStatements,
            OptimizationRule::UseBatchOperations,
            OptimizationRule::UseArrayFetch { size: 1000 },
            OptimizationRule::EnableStreaming,
        ]
    }
}

// --- v3.0 capabilities -------------------------------------------------------

impl BulkLoader for MySqlPlugin {
    fn technique(&self) -> &'static str {
        // LOAD DATA LOCAL INFILE streaming is tracked for v3.1 (requires
        // server flag `local_infile=1` plus client-side temp file management).
        // v3.0 uses optimised array-binding multi-row INSERT.
        "array_binding_optimised"
    }

    fn supports_native_bulk(&self) -> bool {
        true
    }

    fn execute_bulk_native(
        &self,
        conn: &Connection<'static>,
        payload: &BulkInsertPayload,
        options: &BulkLoadOptions,
    ) -> Result<usize> {
        let batch = options.batch_size.clamp(1, 2_000);
        let ab = ArrayBinding::new(batch);
        ab.bulk_insert_generic(conn, payload)
    }
}

impl Upsertable for MySqlPlugin {
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
        if updates.is_empty() {
            return Err(OdbcError::ValidationError(
                "MySQL ON DUPLICATE KEY UPDATE requires at least one column to update".to_string(),
            ));
        }
        let mut set_parts = Vec::with_capacity(updates.len());
        for c in &updates {
            // MySQL idiom: col = VALUES(col) (legacy) — equivalent to col = NEW.col on 8.0+.
            let q = quote_identifier(c, IdentifierQuoting::Backtick)?;
            set_parts.push(format!("{q} = VALUES({q})"));
        }
        let set_clause = set_parts.join(", ");
        Ok(format!(
            "INSERT INTO {qtable} ({qcols}) VALUES ({placeholders}) \
             ON DUPLICATE KEY UPDATE {set_clause}"
        ))
    }
}

impl Returnable for MySqlPlugin {
    /// Stock MySQL (5.7/8.x) does not support RETURNING; MariaDB-only path
    /// lives in a (future) `MariaDbPlugin`.
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
            "MySQL does not support RETURNING; use SELECT LAST_INSERT_ID() instead".to_string(),
        ))
    }
}

impl IdentifierQuoter for MySqlPlugin {
    fn quoting_style(&self) -> IdentifierQuoting {
        IdentifierQuoting::Backtick
    }
}

impl TypeCatalog for MySqlPlugin {
    fn map_type_extended(&self, sql_type: i16, type_name: Option<&str>) -> OdbcType {
        if let Some(name) = type_name {
            let lower = name.trim().to_ascii_lowercase();
            match lower.as_str() {
                "json" => return OdbcType::Json,
                "tinyint(1)" | "boolean" | "bool" => return OdbcType::Boolean,
                "smallint" | "smallint unsigned" => return OdbcType::SmallInt,
                "float" => return OdbcType::Float,
                "double" | "double precision" | "real" => return OdbcType::Double,
                "blob" | "tinyblob" | "mediumblob" | "longblob" | "varbinary" => {
                    return OdbcType::Binary
                }
                "time" => return OdbcType::Time,
                _ => {}
            }
        }
        self.map_type(sql_type)
    }
}

impl CatalogProvider for MySqlPlugin {
    // INFORMATION_SCHEMA defaults work; provide PK/FK/indexes via SHOW INDEXES
    // because MySQL's INFORMATION_SCHEMA constraint views are slow.
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
             FROM INFORMATION_SCHEMA.STATISTICS \
             WHERE TABLE_NAME = ? ORDER BY INDEX_NAME, SEQ_IN_INDEX",
            vec![ParamValue::String(table.to_string())],
        ))
    }
}

impl SessionInitializer for MySqlPlugin {
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
    fn test_mysql_plugin_new() {
        let plugin = MySqlPlugin::new();
        assert_eq!(plugin.name(), "mysql");
    }

    #[test]
    fn test_mysql_plugin_default() {
        let plugin = MySqlPlugin;
        assert_eq!(plugin.name(), "mysql");
    }

    #[test]
    fn test_mysql_plugin_name() {
        let plugin = MySqlPlugin::new();
        assert_eq!(plugin.name(), "mysql");
    }

    #[test]
    fn test_mysql_plugin_capabilities() {
        let plugin = MySqlPlugin::new();
        let caps = plugin.get_capabilities();

        assert!(caps.supports_prepared_statements);
        assert!(caps.supports_batch_operations);
        assert!(caps.supports_streaming);
        assert!(caps.supports_array_fetch);
        assert_eq!(caps.max_row_array_size, 1000);
        assert_eq!(caps.driver_name, "MySQL");
        assert_eq!(caps.driver_version, "Unknown");
    }

    #[test]
    fn test_mysql_plugin_map_type() {
        let plugin = MySqlPlugin::new();

        assert_eq!(plugin.map_type(1), OdbcType::Varchar);
        assert_eq!(plugin.map_type(4), OdbcType::Integer);
        assert_eq!(plugin.map_type(-5), OdbcType::BigInt);
        assert_eq!(plugin.map_type(3), OdbcType::Decimal);
        assert_eq!(plugin.map_type(9), OdbcType::Date);
        assert_eq!(plugin.map_type(11), OdbcType::Timestamp);
        assert_eq!(plugin.map_type(-2), OdbcType::Binary);
        assert_eq!(plugin.map_type(99), OdbcType::Varchar);
    }

    #[test]
    fn test_mysql_plugin_optimize_query_select_without_limit() {
        let plugin = MySqlPlugin::new();

        let sql = "SELECT * FROM users";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users LIMIT 1000");
    }

    #[test]
    fn test_mysql_plugin_optimize_query_select_with_semicolon() {
        let plugin = MySqlPlugin::new();

        let sql = "SELECT * FROM users;";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users LIMIT 1000;");
    }

    #[test]
    fn test_mysql_plugin_optimize_query_already_has_limit() {
        let plugin = MySqlPlugin::new();

        let sql = "SELECT * FROM users LIMIT 500";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users LIMIT 500");
    }

    #[test]
    fn test_mysql_plugin_optimize_query_with_where() {
        let plugin = MySqlPlugin::new();

        let sql = "SELECT * FROM users WHERE id > 10";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users WHERE id > 10");
    }

    #[test]
    fn test_mysql_plugin_optimize_query_with_order_by() {
        let plugin = MySqlPlugin::new();

        let sql = "SELECT * FROM users ORDER BY name";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users ORDER BY name");
    }

    #[test]
    fn test_mysql_plugin_get_optimization_rules() {
        let plugin = MySqlPlugin::new();
        let rules = plugin.get_optimization_rules();

        assert_eq!(rules.len(), 4);
        assert!(matches!(rules[0], OptimizationRule::UsePreparedStatements));
        assert!(matches!(rules[1], OptimizationRule::UseBatchOperations));
        assert!(matches!(
            rules[2],
            OptimizationRule::UseArrayFetch { size: 1000 }
        ));
        assert!(matches!(rules[3], OptimizationRule::EnableStreaming));
    }

    #[test]
    fn test_mysql_plugin_optimize_query_insert() {
        let plugin = MySqlPlugin::new();

        let sql = "INSERT INTO users (name, email) VALUES ('John', 'john@example.com')";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(
            optimized,
            "INSERT INTO users (name, email) VALUES ('John', 'john@example.com')"
        );
    }

    #[test]
    fn test_mysql_plugin_optimize_query_update() {
        let plugin = MySqlPlugin::new();

        let sql = "UPDATE users SET name = 'Jane' WHERE id = 1";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "UPDATE users SET name = 'Jane' WHERE id = 1");
    }

    #[test]
    fn test_mysql_plugin_optimize_query_delete() {
        let plugin = MySqlPlugin::new();

        let sql = "DELETE FROM users WHERE id = 1";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "DELETE FROM users WHERE id = 1");
    }

    #[test]
    fn should_build_upsert_sql_with_on_duplicate_key_update() {
        let plugin = MySqlPlugin::new();
        let sql = plugin
            .build_upsert_sql("users", &["id", "name"], &["id"], None)
            .expect("valid upsert");
        assert!(sql.contains("ON DUPLICATE KEY UPDATE"));
        assert!(sql.contains("`name` = VALUES(`name`)"));
    }

    #[test]
    fn should_quote_identifiers_with_backticks() {
        let plugin = MySqlPlugin::new();
        assert_eq!(plugin.quote("order").unwrap(), "`order`");
    }

    #[test]
    #[allow(
        clippy::default_constructed_unit_structs,
        reason = "intentional: exercises the impl Default for MySqlPlugin"
    )]
    fn default_constructor_should_produce_named_plugin() {
        let plugin = MySqlPlugin::default();
        assert_eq!(plugin.name(), "mysql");
    }

    #[test]
    fn bulk_loader_should_advertise_array_binding_technique() {
        let plugin = MySqlPlugin::new();
        assert_eq!(plugin.technique(), "array_binding_optimised");
        assert!(plugin.supports_native_bulk());
    }

    #[test]
    fn returnable_should_be_unsupported_with_explanatory_error() {
        let plugin = MySqlPlugin::new();
        assert!(!plugin.supports_returning());
        let err = plugin
            .append_returning_clause("INSERT INTO t (a) VALUES (?)", DmlVerb::Insert, &["a"])
            .unwrap_err();
        match err {
            OdbcError::UnsupportedFeature(msg) => {
                assert!(msg.contains("RETURNING"));
                assert!(msg.contains("LAST_INSERT_ID"));
            }
            other => panic!("expected UnsupportedFeature, got {other:?}"),
        }
    }

    #[test]
    fn upsert_should_reject_when_every_column_is_a_conflict_column() {
        let plugin = MySqlPlugin::new();
        let err = plugin
            .build_upsert_sql("t", &["id"], &["id"], None)
            .unwrap_err();
        match err {
            OdbcError::ValidationError(msg) => {
                assert!(msg.contains("at least one column to update"));
            }
            other => panic!("expected ValidationError, got {other:?}"),
        }
    }

    #[test]
    fn type_catalog_should_map_json_by_type_name() {
        let plugin = MySqlPlugin::new();
        assert_eq!(plugin.map_type_extended(1, Some("json")), OdbcType::Json);
    }

    #[test]
    fn type_catalog_should_map_tinyint_one_as_boolean() {
        let plugin = MySqlPlugin::new();
        assert_eq!(
            plugin.map_type_extended(4, Some("tinyint(1)")),
            OdbcType::Boolean,
        );
        assert_eq!(
            plugin.map_type_extended(4, Some("boolean")),
            OdbcType::Boolean,
        );
        assert_eq!(plugin.map_type_extended(4, Some("bool")), OdbcType::Boolean);
    }

    #[test]
    fn type_catalog_should_map_numeric_aliases() {
        let plugin = MySqlPlugin::new();
        assert_eq!(
            plugin.map_type_extended(0, Some("smallint")),
            OdbcType::SmallInt,
        );
        assert_eq!(plugin.map_type_extended(0, Some("float")), OdbcType::Float);
        assert_eq!(
            plugin.map_type_extended(0, Some("double")),
            OdbcType::Double
        );
        assert_eq!(plugin.map_type_extended(0, Some("real")), OdbcType::Double);
    }

    #[test]
    fn type_catalog_should_map_blob_family_as_binary() {
        let plugin = MySqlPlugin::new();
        for name in &["blob", "tinyblob", "mediumblob", "longblob", "varbinary"] {
            assert_eq!(plugin.map_type_extended(0, Some(name)), OdbcType::Binary);
        }
    }

    #[test]
    fn type_catalog_should_fall_back_to_map_type_when_name_unrecognised() {
        let plugin = MySqlPlugin::new();
        // type_name is unknown — should defer to map_type(1) => Varchar
        assert_eq!(
            plugin.map_type_extended(1, Some("not_a_real_type")),
            OdbcType::Varchar,
        );
        // type_name absent — same fallback
        assert_eq!(plugin.map_type_extended(4, None), OdbcType::Integer);
    }

    #[test]
    fn catalog_provider_should_build_primary_key_query_with_table_param() {
        let plugin = MySqlPlugin::new();
        let q = plugin
            .list_primary_keys_sql("users", None)
            .expect("valid catalog query");
        assert!(q.sql.contains("INFORMATION_SCHEMA.KEY_COLUMN_USAGE"));
        assert!(q.sql.contains("CONSTRAINT_NAME = 'PRIMARY'"));
        assert_eq!(q.params.len(), 1);
        assert!(matches!(&q.params[0], ParamValue::String(s) if s == "users"));
    }

    #[test]
    fn catalog_provider_should_build_foreign_key_query_with_table_param() {
        let plugin = MySqlPlugin::new();
        let q = plugin
            .list_foreign_keys_sql("orders", None)
            .expect("valid catalog query");
        assert!(q.sql.contains("REFERENCED_TABLE_NAME IS NOT NULL"));
        assert_eq!(q.params.len(), 1);
        assert!(matches!(&q.params[0], ParamValue::String(s) if s == "orders"));
    }

    #[test]
    fn catalog_provider_should_build_index_query_with_table_param() {
        let plugin = MySqlPlugin::new();
        let q = plugin
            .list_indexes_sql("users", None)
            .expect("valid catalog query");
        assert!(q.sql.contains("INFORMATION_SCHEMA.STATISTICS"));
        assert!(q.sql.contains("SEQ_IN_INDEX"));
        assert_eq!(q.params.len(), 1);
    }

    #[test]
    fn session_initializer_should_default_to_utf8mb4_charset() {
        let plugin = MySqlPlugin::new();
        let stmts = plugin.initialization_sql(&SessionOptions::default());
        assert!(stmts.iter().any(|s| s == "SET NAMES utf8mb4"));
    }

    #[test]
    fn session_initializer_should_emit_timezone_when_provided() {
        let plugin = MySqlPlugin::new();
        let opts = SessionOptions {
            timezone: Some("UTC".to_string()),
            ..Default::default()
        };
        let stmts = plugin.initialization_sql(&opts);
        assert!(stmts.iter().any(|s| s.contains("SET time_zone = 'UTC'")));
    }

    #[test]
    fn session_initializer_should_escape_single_quotes_in_timezone() {
        let plugin = MySqlPlugin::new();
        let opts = SessionOptions {
            timezone: Some("America/Sao_Paulo'; DROP".to_string()),
            ..Default::default()
        };
        let stmts = plugin.initialization_sql(&opts);
        let tz_stmt = stmts
            .iter()
            .find(|s| s.starts_with("SET time_zone"))
            .expect("timezone statement emitted");
        // Single quote in payload should be doubled, never closed prematurely.
        assert!(tz_stmt.contains("America/Sao_Paulo''; DROP"));
    }

    #[test]
    fn session_initializer_should_emit_use_statement_for_schema() {
        let plugin = MySqlPlugin::new();
        let opts = SessionOptions {
            schema: Some("app_db".to_string()),
            ..Default::default()
        };
        let stmts = plugin.initialization_sql(&opts);
        assert!(stmts.iter().any(|s| s == "USE `app_db`"));
    }

    #[test]
    fn session_initializer_should_append_extra_sql_verbatim() {
        let plugin = MySqlPlugin::new();
        let opts = SessionOptions {
            extra_sql: vec!["SET sql_mode = 'STRICT_ALL_TABLES'".to_string()],
            ..Default::default()
        };
        let stmts = plugin.initialization_sql(&opts);
        assert!(stmts
            .iter()
            .any(|s| s == "SET sql_mode = 'STRICT_ALL_TABLES'"));
    }

    #[test]
    fn identifier_quoter_should_use_backtick_style() {
        let plugin = MySqlPlugin::new();
        assert_eq!(plugin.quoting_style(), IdentifierQuoting::Backtick);
    }
}
