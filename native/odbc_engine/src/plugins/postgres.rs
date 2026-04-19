use super::capabilities::bulk_loader::{BulkLoadOptions, BulkLoader};
use super::capabilities::catalog_provider::{CatalogProvider, CatalogQuery};
use super::capabilities::returning::{quote_returning_columns, DmlVerb};
use super::capabilities::upsert::{
    effective_update_columns, placeholder_list, quote_columns, validate_upsert_inputs, Upsertable,
};
use super::capabilities::{
    IdentifierQuoter, Returnable, SessionInitializer, SessionOptions, TypeCatalog,
};
use super::driver_plugin::{DriverCapabilities, DriverPlugin, OptimizationRule};
use crate::engine::core::ArrayBinding;
use crate::engine::identifier::{
    quote_identifier_default, quote_qualified_default, IdentifierQuoting,
};
use crate::error::Result;
use crate::protocol::types::OdbcType;
use crate::protocol::BulkInsertPayload;
use crate::protocol::ParamValue;
use odbc_api::Connection;

pub struct PostgresPlugin;

impl Default for PostgresPlugin {
    fn default() -> Self {
        Self::new()
    }
}

impl PostgresPlugin {
    pub fn new() -> Self {
        Self
    }
}

impl DriverPlugin for PostgresPlugin {
    fn name(&self) -> &str {
        "postgres"
    }

    fn get_capabilities(&self) -> DriverCapabilities {
        DriverCapabilities {
            supports_prepared_statements: true,
            supports_batch_operations: true,
            supports_streaming: true,
            supports_array_fetch: true,
            max_row_array_size: 1000,
            driver_name: "PostgreSQL".to_string(),
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

impl BulkLoader for PostgresPlugin {
    fn technique(&self) -> &'static str {
        // The native COPY-binary streaming path is tracked for v3.1 (requires
        // raw odbc_sys SQLPutData chunking + binary header authoring).
        // v3.0 falls back to optimised array-binding INSERT.
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
        // PostgreSQL benefits from large array-binding batches; default to
        // 5_000 rows per network round-trip when the caller passes the
        // standard 10k.
        let batch = options.batch_size.clamp(1, 5_000);
        let ab = ArrayBinding::new(batch);
        ab.bulk_insert_generic(conn, payload)
    }
}

impl Upsertable for PostgresPlugin {
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

        // PostgreSQL ON CONFLICT ... DO UPDATE SET col = EXCLUDED.col
        if updates.is_empty() {
            // No columns to update -> degrade to ON CONFLICT DO NOTHING.
            return Ok(format!(
                "INSERT INTO {qtable} ({qcols}) VALUES ({placeholders}) \
                 ON CONFLICT ({qconflict}) DO NOTHING"
            ));
        }
        let mut set_parts = Vec::with_capacity(updates.len());
        for c in &updates {
            let q = quote_identifier_default(c)?;
            set_parts.push(format!("{q} = EXCLUDED.{q}"));
        }
        let set_clause = set_parts.join(", ");
        Ok(format!(
            "INSERT INTO {qtable} ({qcols}) VALUES ({placeholders}) \
             ON CONFLICT ({qconflict}) DO UPDATE SET {set_clause}"
        ))
    }
}

impl Returnable for PostgresPlugin {
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

impl IdentifierQuoter for PostgresPlugin {
    fn quoting_style(&self) -> IdentifierQuoting {
        IdentifierQuoting::DoubleQuote
    }
}

impl TypeCatalog for PostgresPlugin {
    fn map_type_extended(&self, sql_type: i16, type_name: Option<&str>) -> OdbcType {
        if let Some(name) = type_name {
            let lower = name.trim().to_ascii_lowercase();
            match lower.as_str() {
                "json" | "jsonb" => return OdbcType::Json,
                "uuid" => return OdbcType::Uuid,
                "timestamptz" | "timestamp with time zone" => return OdbcType::TimestampWithTz,
                "bool" | "boolean" => return OdbcType::Boolean,
                "int2" | "smallint" => return OdbcType::SmallInt,
                "float4" | "real" => return OdbcType::Float,
                "float8" | "double precision" => return OdbcType::Double,
                "bytea" => return OdbcType::Binary,
                "interval" => return OdbcType::Interval,
                "time" | "timetz" => return OdbcType::Time,
                _ => {}
            }
        }
        self.map_type(sql_type)
    }
}

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

impl SessionInitializer for PostgresPlugin {
    fn initialization_sql(&self, opts: &SessionOptions) -> Vec<String> {
        let mut out = Vec::new();
        if let Some(name) = opts.application_name.as_deref() {
            // PG accepts SET application_name with single-quoted literals.
            out.push(format!(
                "SET application_name = '{}'",
                name.replace('\'', "''")
            ));
        }
        if let Some(tz) = opts.timezone.as_deref() {
            out.push(format!("SET TIME ZONE '{}'", tz.replace('\'', "''")));
        }
        if let Some(schema) = opts.schema.as_deref() {
            // Validate schema as identifier; quote with double quotes.
            if let Ok(quoted) = quote_identifier_default(schema) {
                out.push(format!("SET search_path TO {quoted}"));
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
    fn test_postgres_plugin_new() {
        let plugin = PostgresPlugin::new();
        assert_eq!(plugin.name(), "postgres");
    }

    #[test]
    fn test_postgres_plugin_default() {
        let plugin = PostgresPlugin;
        assert_eq!(plugin.name(), "postgres");
    }

    #[test]
    fn test_postgres_plugin_name() {
        let plugin = PostgresPlugin::new();
        assert_eq!(plugin.name(), "postgres");
    }

    #[test]
    fn test_postgres_plugin_capabilities() {
        let plugin = PostgresPlugin::new();
        let caps = plugin.get_capabilities();

        assert!(caps.supports_prepared_statements);
        assert!(caps.supports_batch_operations);
        assert!(caps.supports_streaming);
        assert!(caps.supports_array_fetch);
        assert_eq!(caps.max_row_array_size, 1000);
        assert_eq!(caps.driver_name, "PostgreSQL");
        assert_eq!(caps.driver_version, "Unknown");
    }

    #[test]
    fn test_postgres_plugin_map_type() {
        let plugin = PostgresPlugin::new();

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
    fn test_postgres_plugin_optimize_query_select_without_limit() {
        let plugin = PostgresPlugin::new();

        let sql = "SELECT * FROM users";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users LIMIT 1000");
    }

    #[test]
    fn test_postgres_plugin_optimize_query_select_with_semicolon() {
        let plugin = PostgresPlugin::new();

        let sql = "SELECT * FROM users;";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users LIMIT 1000;");
    }

    #[test]
    fn test_postgres_plugin_optimize_query_already_has_limit() {
        let plugin = PostgresPlugin::new();

        let sql = "SELECT * FROM users LIMIT 500";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users LIMIT 500");
    }

    #[test]
    fn test_postgres_plugin_optimize_query_with_where() {
        let plugin = PostgresPlugin::new();

        let sql = "SELECT * FROM users WHERE id > 10";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users WHERE id > 10");
    }

    #[test]
    fn test_postgres_plugin_optimize_query_with_order_by() {
        let plugin = PostgresPlugin::new();

        let sql = "SELECT * FROM users ORDER BY name";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users ORDER BY name");
    }

    #[test]
    fn test_postgres_plugin_get_optimization_rules() {
        let plugin = PostgresPlugin::new();
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
}
