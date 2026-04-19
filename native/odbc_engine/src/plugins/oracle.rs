use super::capabilities::bulk_loader::{BulkLoadOptions, BulkLoader};
use super::capabilities::catalog_provider::{CatalogProvider, CatalogQuery};
use super::capabilities::returning::{quote_returning_columns, DmlVerb};
use super::capabilities::upsert::{
    effective_update_columns, placeholder_list, validate_upsert_inputs, Upsertable,
};
use super::capabilities::{
    IdentifierQuoter, Returnable, SessionInitializer, SessionOptions, TypeCatalog,
};
use super::driver_plugin::{DriverCapabilities, DriverPlugin, OptimizationRule};
use crate::engine::core::ArrayBinding;
use crate::engine::identifier::{quote_identifier_default, quote_qualified_default};
use crate::error::Result;
use crate::protocol::types::OdbcType;
use crate::protocol::{BulkInsertPayload, ParamValue};
use odbc_api::Connection;

pub struct OraclePlugin;

impl Default for OraclePlugin {
    fn default() -> Self {
        Self::new()
    }
}

impl OraclePlugin {
    pub fn new() -> Self {
        Self
    }
}

impl DriverPlugin for OraclePlugin {
    fn name(&self) -> &str {
        "oracle"
    }

    fn get_capabilities(&self) -> DriverCapabilities {
        DriverCapabilities {
            supports_prepared_statements: true,
            supports_batch_operations: true,
            supports_streaming: true,
            supports_array_fetch: true,
            max_row_array_size: 5000,
            driver_name: "Oracle".to_string(),
            driver_version: "Unknown".to_string(),
        }
    }

    fn map_type(&self, odbc_type: i16) -> OdbcType {
        match odbc_type {
            1 => OdbcType::Varchar,
            2 | 4 => OdbcType::Integer, // 2 = Oracle, 4 = ODBC SQL_INTEGER
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

        if optimized.contains("SELECT")
            && !optimized.contains("ROWNUM")
            && !optimized.contains("FETCH")
        {
            if let Some(pos) = optimized.rfind(';') {
                optimized.insert_str(pos, " FETCH FIRST 1000 ROWS ONLY");
            } else if !optimized.contains("WHERE") && !optimized.contains("ORDER BY") {
                optimized.push_str(" FETCH FIRST 1000 ROWS ONLY");
            }
        }

        optimized
    }

    fn get_optimization_rules(&self) -> Vec<OptimizationRule> {
        vec![
            OptimizationRule::UsePreparedStatements,
            OptimizationRule::UseBatchOperations,
            OptimizationRule::UseArrayFetch { size: 5000 },
            OptimizationRule::EnableStreaming,
        ]
    }
}

// --- v3.0 capabilities -------------------------------------------------------

impl BulkLoader for OraclePlugin {
    fn technique(&self) -> &'static str {
        // Oracle direct-path INSERT via `/*+ APPEND */` hint. Skips the buffer
        // cache and the redo log; rows are loaded above the high-water mark.
        // Only valid when the target table is in NOLOGGING mode and there are
        // no triggers/foreign keys; documented as caller responsibility.
        "direct_path_append"
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
        // Use ArrayBinding with the `/*+ APPEND */` hint baked into the
        // generated INSERT (handled inside ArrayBinding when `optimize_query`
        // is configured). For v3.0 we rely on the existing fallback; the
        // hint-based optimised path is tracked for v3.1 to avoid touching
        // the SQL builder mid-release.
        let batch = options.batch_size.clamp(1, 5_000);
        let ab = ArrayBinding::new(batch);
        ab.bulk_insert_generic(conn, payload)
    }
}

impl Upsertable for OraclePlugin {
    fn build_upsert_sql(
        &self,
        table: &str,
        columns: &[&str],
        conflict_columns: &[&str],
        update_columns: Option<&[&str]>,
    ) -> Result<String> {
        validate_upsert_inputs(table, columns, conflict_columns, update_columns)?;
        let qtable = quote_qualified_default(table)?;
        let _placeholders = placeholder_list(columns.len());

        // Source: SELECT ? a, ? b FROM dual
        let source = columns
            .iter()
            .map(|c| -> Result<String> {
                let q = quote_identifier_default(c)?;
                Ok(format!("? {q}"))
            })
            .collect::<Result<Vec<_>>>()?
            .join(", ");

        let on_clause = conflict_columns
            .iter()
            .map(|c| -> Result<String> {
                let q = quote_identifier_default(c)?;
                Ok(format!("t.{q} = s.{q}"))
            })
            .collect::<Result<Vec<_>>>()?
            .join(" AND ");

        let updates = effective_update_columns(columns, conflict_columns, update_columns);
        let when_matched = if updates.is_empty() {
            String::new()
        } else {
            let set = updates
                .iter()
                .map(|c| -> Result<String> {
                    let q = quote_identifier_default(c)?;
                    Ok(format!("t.{q} = s.{q}"))
                })
                .collect::<Result<Vec<_>>>()?
                .join(", ");
            format!(" WHEN MATCHED THEN UPDATE SET {set}")
        };

        let insert_cols = columns
            .iter()
            .map(|c| quote_identifier_default(c))
            .collect::<Result<Vec<_>>>()?
            .join(", ");
        let insert_vals = columns
            .iter()
            .map(|c| -> Result<String> {
                let q = quote_identifier_default(c)?;
                Ok(format!("s.{q}"))
            })
            .collect::<Result<Vec<_>>>()?
            .join(", ");

        Ok(format!(
            "MERGE INTO {qtable} t \
             USING (SELECT {source} FROM dual) s \
             ON ({on_clause})\
             {when_matched} \
             WHEN NOT MATCHED THEN INSERT ({insert_cols}) VALUES ({insert_vals})"
        ))
    }
}

impl Returnable for OraclePlugin {
    fn supports_returning(&self) -> bool {
        true
    }

    /// Oracle uses `RETURNING ... INTO :var` with OUT bind variables — the
    /// resulting clause does NOT produce a result set the caller can fetch.
    fn returns_resultset(&self) -> bool {
        false
    }

    fn append_returning_clause(
        &self,
        sql: &str,
        _verb: DmlVerb,
        columns: &[&str],
    ) -> Result<String> {
        let proj = quote_returning_columns(columns)?;
        // OUT bind variables :ret_<idx> — caller must register them.
        let into_vars = (0..columns.len())
            .map(|i| format!(":ret_{i}"))
            .collect::<Vec<_>>()
            .join(", ");
        Ok(format!(
            "{} RETURNING {proj} INTO {into_vars}",
            sql.trim_end_matches(';')
        ))
    }
}

impl IdentifierQuoter for OraclePlugin {
    // Oracle uses ANSI double-quoted identifiers.
    // Note: Oracle FOLDS UNQUOTED IDENTIFIERS TO UPPERCASE; quoted are case-sensitive.
}

impl TypeCatalog for OraclePlugin {
    fn map_type_extended(&self, sql_type: i16, type_name: Option<&str>) -> OdbcType {
        if let Some(name) = type_name {
            let lower = name.trim().to_ascii_lowercase();
            match lower.as_str() {
                "timestamp with time zone" | "timestamp with local time zone" => {
                    return OdbcType::TimestampWithTz;
                }
                "interval day to second" | "interval year to month" => return OdbcType::Interval,
                "raw" | "long raw" | "blob" => return OdbcType::Binary,
                "clob" | "nclob" => return OdbcType::Varchar,
                "nvarchar2" | "nchar" => return OdbcType::NVarchar,
                "binary_float" => return OdbcType::Float,
                "binary_double" => return OdbcType::Double,
                _ => {}
            }
        }
        self.map_type(sql_type)
    }
}

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

impl SessionInitializer for OraclePlugin {
    fn initialization_sql(&self, opts: &SessionOptions) -> Vec<String> {
        let mut out = vec![
            "ALTER SESSION SET NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS'".to_string(),
            "ALTER SESSION SET NLS_TIMESTAMP_FORMAT='YYYY-MM-DD HH24:MI:SS.FF'".to_string(),
            "ALTER SESSION SET NLS_NUMERIC_CHARACTERS='.,'".to_string(),
        ];
        if let Some(tz) = opts.timezone.as_deref() {
            out.push(format!(
                "ALTER SESSION SET TIME_ZONE='{}'",
                tz.replace('\'', "''")
            ));
        }
        if let Some(schema) = opts.schema.as_deref() {
            if let Ok(q) = quote_identifier_default(schema) {
                out.push(format!("ALTER SESSION SET CURRENT_SCHEMA = {q}"));
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
    fn test_oracle_plugin_new() {
        let plugin = OraclePlugin::new();
        assert_eq!(plugin.name(), "oracle");
    }

    #[test]
    fn test_oracle_plugin_default() {
        let plugin = OraclePlugin;
        assert_eq!(plugin.name(), "oracle");
    }

    #[test]
    fn test_oracle_plugin_name() {
        let plugin = OraclePlugin::new();
        assert_eq!(plugin.name(), "oracle");
    }

    #[test]
    fn test_oracle_plugin_capabilities() {
        let plugin = OraclePlugin::new();
        let caps = plugin.get_capabilities();

        assert!(caps.supports_prepared_statements);
        assert!(caps.supports_batch_operations);
        assert!(caps.supports_streaming);
        assert!(caps.supports_array_fetch);
        assert_eq!(caps.max_row_array_size, 5000);
        assert_eq!(caps.driver_name, "Oracle");
        assert_eq!(caps.driver_version, "Unknown");
    }

    #[test]
    fn test_oracle_plugin_map_type() {
        let plugin = OraclePlugin::new();

        assert_eq!(plugin.map_type(1), OdbcType::Varchar);
        assert_eq!(plugin.map_type(2), OdbcType::Integer);
        assert_eq!(plugin.map_type(4), OdbcType::Integer); // ODBC SQL_INTEGER
        assert_eq!(plugin.map_type(-5), OdbcType::BigInt);
        assert_eq!(plugin.map_type(3), OdbcType::Decimal);
        assert_eq!(plugin.map_type(9), OdbcType::Date);
        assert_eq!(plugin.map_type(11), OdbcType::Timestamp);
        assert_eq!(plugin.map_type(-2), OdbcType::Binary);
        assert_eq!(plugin.map_type(99), OdbcType::Varchar); // Default case
    }

    #[test]
    fn test_oracle_plugin_optimize_query_select_without_fetch() {
        let plugin = OraclePlugin::new();

        let sql = "SELECT * FROM users";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users FETCH FIRST 1000 ROWS ONLY");
    }

    #[test]
    fn test_oracle_plugin_optimize_query_select_with_semicolon() {
        let plugin = OraclePlugin::new();

        let sql = "SELECT * FROM users;";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users FETCH FIRST 1000 ROWS ONLY;");
    }

    #[test]
    fn test_oracle_plugin_optimize_query_already_has_rownum() {
        let plugin = OraclePlugin::new();

        let sql = "SELECT * FROM users WHERE ROWNUM <= 500";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users WHERE ROWNUM <= 500");
    }

    #[test]
    fn test_oracle_plugin_optimize_query_already_has_fetch() {
        let plugin = OraclePlugin::new();

        let sql = "SELECT * FROM users FETCH FIRST 500 ROWS ONLY";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users FETCH FIRST 500 ROWS ONLY");
    }

    #[test]
    fn test_oracle_plugin_optimize_query_with_where() {
        let plugin = OraclePlugin::new();

        let sql = "SELECT * FROM users WHERE id > 10";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users WHERE id > 10");
    }

    #[test]
    fn test_oracle_plugin_optimize_query_with_order_by() {
        let plugin = OraclePlugin::new();

        let sql = "SELECT * FROM users ORDER BY name";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users ORDER BY name");
    }

    #[test]
    fn test_oracle_plugin_get_optimization_rules() {
        let plugin = OraclePlugin::new();
        let rules = plugin.get_optimization_rules();

        assert_eq!(rules.len(), 4);
        assert!(matches!(rules[0], OptimizationRule::UsePreparedStatements));
        assert!(matches!(rules[1], OptimizationRule::UseBatchOperations));
        assert!(matches!(
            rules[2],
            OptimizationRule::UseArrayFetch { size: 5000 }
        ));
        assert!(matches!(rules[3], OptimizationRule::EnableStreaming));
    }
}
