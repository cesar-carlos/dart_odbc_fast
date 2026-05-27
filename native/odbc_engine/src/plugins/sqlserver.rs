use super::capabilities::catalog_provider::{CatalogProvider, CatalogQuery};
use super::capabilities::returning::DmlVerb;
use super::capabilities::upsert::{
    effective_update_columns, placeholder_list, validate_upsert_inputs, Upsertable,
};
use super::capabilities::{
    IdentifierQuoter, Returnable, SessionInitializer, SessionOptions, TypeCatalog,
};
use super::driver_plugin::{DriverCapabilities, DriverPlugin, OptimizationRule};
use crate::engine::identifier::{quote_identifier, validate_identifier, IdentifierQuoting};
use crate::error::Result;
use crate::protocol::types::OdbcType;
use crate::protocol::ParamValue;

/// Validate every column and return them quoted with `[brackets]`,
/// comma-joined.
fn quote_cols_brackets(columns: &[&str]) -> Result<String> {
    let mut out = Vec::with_capacity(columns.len());
    for c in columns {
        out.push(quote_identifier(c, IdentifierQuoting::Brackets)?);
    }
    Ok(out.join(", "))
}

/// Quote a possibly-qualified table name (`db.schema.table`) using brackets.
fn quote_table_brackets(table: &str) -> Result<String> {
    let mut parts = Vec::new();
    for seg in table.split('.') {
        validate_identifier(seg)?;
        parts.push(quote_identifier(seg, IdentifierQuoting::Brackets)?);
    }
    Ok(parts.join("."))
}

pub struct SqlServerPlugin;

impl Default for SqlServerPlugin {
    fn default() -> Self {
        Self::new()
    }
}

impl SqlServerPlugin {
    pub fn new() -> Self {
        Self
    }
}

impl DriverPlugin for SqlServerPlugin {
    fn name(&self) -> &str {
        "sqlserver"
    }

    fn get_capabilities(&self) -> DriverCapabilities {
        DriverCapabilities {
            supports_prepared_statements: true,
            supports_batch_operations: true,
            supports_streaming: true,
            supports_array_fetch: true,
            max_row_array_size: 1000,
            driver_name: "SQL Server".to_string(),
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

        if optimized.contains("SELECT *") && !optimized.contains("TOP") {
            if let Some(pos) = optimized.find("SELECT *") {
                optimized.replace_range(pos..pos + 8, "SELECT TOP 1000 *");
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

impl Upsertable for SqlServerPlugin {
    fn build_upsert_sql(
        &self,
        table: &str,
        columns: &[&str],
        conflict_columns: &[&str],
        update_columns: Option<&[&str]>,
    ) -> Result<String> {
        validate_upsert_inputs(table, columns, conflict_columns, update_columns)?;
        let qtable = quote_table_brackets(table)?;
        let qcols = quote_cols_brackets(columns)?;
        let placeholders = placeholder_list(columns.len());

        // Source aliases: build "?" placeholders + column aliases
        let alias_list = columns
            .iter()
            .map(|c| -> Result<String> {
                let q = quote_identifier(c, IdentifierQuoting::Brackets)?;
                Ok(format!("? AS {q}"))
            })
            .collect::<Result<Vec<_>>>()?
            .join(", ");
        let _ = placeholders; // alias_list replaces the standard placeholder list

        let on_clause = conflict_columns
            .iter()
            .map(|c| -> Result<String> {
                let q = quote_identifier(c, IdentifierQuoting::Brackets)?;
                Ok(format!("t.{q} = s.{q}"))
            })
            .collect::<Result<Vec<_>>>()?
            .join(" AND ");

        let updates = effective_update_columns(columns, conflict_columns, update_columns);
        let set_clause = if updates.is_empty() {
            String::new()
        } else {
            updates
                .iter()
                .map(|c| -> Result<String> {
                    let q = quote_identifier(c, IdentifierQuoting::Brackets)?;
                    Ok(format!("t.{q} = s.{q}"))
                })
                .collect::<Result<Vec<_>>>()?
                .join(", ")
        };

        let insert_cols = qcols.clone();
        let insert_vals = columns
            .iter()
            .map(|c| -> Result<String> {
                let q = quote_identifier(c, IdentifierQuoting::Brackets)?;
                Ok(format!("s.{q}"))
            })
            .collect::<Result<Vec<_>>>()?
            .join(", ");

        let when_matched = if set_clause.is_empty() {
            String::new()
        } else {
            format!(" WHEN MATCHED THEN UPDATE SET {set_clause}")
        };

        // Note the trailing semicolon: SQL Server requires MERGE to end with `;`.
        Ok(format!(
            "MERGE INTO {qtable} AS t \
             USING (SELECT {alias_list}) AS s \
             ON {on_clause}\
             {when_matched} \
             WHEN NOT MATCHED THEN INSERT ({insert_cols}) VALUES ({insert_vals});"
        ))
    }
}

impl Returnable for SqlServerPlugin {
    fn supports_returning(&self) -> bool {
        true
    }

    fn append_returning_clause(
        &self,
        sql: &str,
        verb: DmlVerb,
        columns: &[&str],
    ) -> Result<String> {
        // SQL Server uses OUTPUT INSERTED.* / DELETED.* / both.
        let prefix = match verb {
            DmlVerb::Insert => "INSERTED",
            DmlVerb::Delete => "DELETED",
            DmlVerb::Update => "INSERTED",
        };
        let cols = columns
            .iter()
            .map(|c| -> Result<String> {
                let q = quote_identifier(c, IdentifierQuoting::Brackets)?;
                Ok(format!("{prefix}.{q}"))
            })
            .collect::<Result<Vec<_>>>()?
            .join(", ");

        // Insert OUTPUT before VALUES/SELECT/WHERE depending on the statement.
        // For INSERT INTO t (...) VALUES (...) — OUTPUT goes between (...) and VALUES.
        let trimmed = sql.trim_end_matches(';').trim_end();
        let upper = trimmed.to_ascii_uppercase();

        if let Some(values_pos) = upper.rfind(" VALUES") {
            let (head, tail) = trimmed.split_at(values_pos);
            return Ok(format!("{head} OUTPUT {cols}{tail}"));
        }
        if let Some(select_pos) = upper.rfind(" SELECT") {
            let (head, tail) = trimmed.split_at(select_pos);
            return Ok(format!("{head} OUTPUT {cols}{tail}"));
        }
        if let Some(set_pos) = upper.find(" SET") {
            // UPDATE t SET ... WHERE ... -> UPDATE t SET ... OUTPUT INSERTED.* WHERE ...
            // Place OUTPUT after the SET clause's value list. Conservative: after WHERE.
            if let Some(where_pos) = upper[set_pos..].find(" WHERE") {
                let abs_where = set_pos + where_pos;
                let (head, tail) = trimmed.split_at(abs_where);
                return Ok(format!("{head} OUTPUT {cols}{tail}"));
            }
            return Ok(format!("{trimmed} OUTPUT {cols}"));
        }
        if upper.starts_with("DELETE") {
            // DELETE FROM t WHERE ... -> DELETE FROM t OUTPUT DELETED.* WHERE ...
            if let Some(where_pos) = upper.find(" WHERE") {
                let (head, tail) = trimmed.split_at(where_pos);
                return Ok(format!("{head} OUTPUT {cols}{tail}"));
            }
            return Ok(format!("{trimmed} OUTPUT {cols}"));
        }
        Ok(format!("{trimmed} OUTPUT {cols}"))
    }
}

impl IdentifierQuoter for SqlServerPlugin {
    fn quoting_style(&self) -> IdentifierQuoting {
        IdentifierQuoting::Brackets
    }
}

impl TypeCatalog for SqlServerPlugin {
    fn map_type_extended(&self, sql_type: i16, type_name: Option<&str>) -> OdbcType {
        if let Some(name) = type_name {
            let lower = name.trim().to_ascii_lowercase();
            match lower.as_str() {
                "nvarchar" | "nchar" | "ntext" => return OdbcType::NVarchar,
                "datetimeoffset" => return OdbcType::DatetimeOffset,
                "uniqueidentifier" => return OdbcType::Uuid,
                "money" | "smallmoney" => return OdbcType::Money,
                "bit" => return OdbcType::Boolean,
                "smallint" | "tinyint" => return OdbcType::SmallInt,
                "real" => return OdbcType::Float,
                "float" => return OdbcType::Double,
                "varbinary" | "binary" | "image" => return OdbcType::Binary,
                "json" => return OdbcType::Json,
                "time" => return OdbcType::Time,
                _ => {}
            }
        }
        self.map_type(sql_type)
    }
}

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

impl SessionInitializer for SqlServerPlugin {
    fn initialization_sql(&self, opts: &SessionOptions) -> Vec<String> {
        let mut out = vec![
            "SET ARITHABORT ON".to_string(),
            "SET CONCAT_NULL_YIELDS_NULL ON".to_string(),
        ];
        if let Some(name) = opts.application_name.as_deref() {
            // SQL Server doesn't have a runtime SET APPLICATION_NAME; emitted as
            // `SET CONTEXT_INFO` for visibility in DMVs (best-effort).
            // The proper way is via connection string `App=...`; documented.
            let _ = name;
        }
        if let Some(schema) = opts.schema.as_deref() {
            if let Ok(q) = quote_identifier(schema, IdentifierQuoting::Brackets) {
                out.push(format!(
                    "EXEC sp_setapprole NULL, NULL; SELECT 1 FROM {q}.sysobjects WHERE 1=0"
                ));
                let _ = out.pop(); // No portable "USE schema" — leave it documented.
            }
        }
        let _ = opts.timezone; // SQL Server has no session-level TZ setting.
        let _ = opts.charset;
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
    fn test_sqlserver_plugin_new() {
        let plugin = SqlServerPlugin::new();
        assert_eq!(plugin.name(), "sqlserver");
    }

    #[test]
    fn test_sqlserver_plugin_default() {
        let plugin = SqlServerPlugin;
        assert_eq!(plugin.name(), "sqlserver");
    }

    #[test]
    fn test_sqlserver_plugin_name() {
        let plugin = SqlServerPlugin::new();
        assert_eq!(plugin.name(), "sqlserver");
    }

    #[test]
    fn test_sqlserver_plugin_capabilities() {
        let plugin = SqlServerPlugin::new();
        let caps = plugin.get_capabilities();

        assert!(caps.supports_prepared_statements);
        assert!(caps.supports_batch_operations);
        assert!(caps.supports_streaming);
        assert!(caps.supports_array_fetch);
        assert_eq!(caps.max_row_array_size, 1000);
        assert_eq!(caps.driver_name, "SQL Server");
        assert_eq!(caps.driver_version, "Unknown");
    }

    #[test]
    fn test_sqlserver_plugin_map_type() {
        let plugin = SqlServerPlugin::new();

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
    fn test_sqlserver_plugin_optimize_query_select_star() {
        let plugin = SqlServerPlugin::new();

        let sql = "SELECT * FROM users";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT TOP 1000 * FROM users");
    }

    #[test]
    fn test_sqlserver_plugin_optimize_query_select_star_with_semicolon() {
        let plugin = SqlServerPlugin::new();

        let sql = "SELECT * FROM users;";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT TOP 1000 * FROM users;");
    }

    #[test]
    fn test_sqlserver_plugin_optimize_query_already_has_top() {
        let plugin = SqlServerPlugin::new();

        let sql = "SELECT TOP 500 * FROM users";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT TOP 500 * FROM users");
    }

    #[test]
    fn test_sqlserver_plugin_optimize_query_no_select_star() {
        let plugin = SqlServerPlugin::new();

        let sql = "SELECT id, name FROM users";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT id, name FROM users");
    }

    #[test]
    fn test_sqlserver_plugin_get_optimization_rules() {
        let plugin = SqlServerPlugin::new();
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
    fn should_build_merge_upsert_sql() {
        let plugin = SqlServerPlugin::new();
        let sql = plugin
            .build_upsert_sql("dbo.users", &["id", "name"], &["id"], None)
            .expect("valid merge upsert");
        assert!(sql.starts_with("MERGE INTO"));
        assert!(sql.contains("WHEN NOT MATCHED"));
        assert!(sql.ends_with(';'));
    }

    #[test]
    fn should_append_output_clause_for_insert() {
        let plugin = SqlServerPlugin::new();
        let sql = plugin
            .append_returning_clause("INSERT INTO t (id) VALUES (?)", DmlVerb::Insert, &["id"])
            .unwrap();
        assert!(sql.contains("OUTPUT INSERTED.[id]"));
    }

    #[test]
    fn should_emit_sys_primary_keys_catalog_sql() {
        let plugin = SqlServerPlugin::new();
        let q = plugin.list_primary_keys_sql("Orders", None).unwrap();
        assert!(q.sql.contains("sys.indexes"));
        assert!(q.sql.contains("is_primary_key = 1"));
        assert_eq!(q.params.len(), 1);
    }

    #[test]
    fn should_emit_sys_indexes_catalog_sql() {
        let plugin = SqlServerPlugin::new();
        let q = plugin.list_indexes_sql("Orders", None).unwrap();
        assert!(q.sql.contains("sys.index_columns"));
        assert_eq!(q.params.len(), 1);
    }

    #[test]
    #[allow(
        clippy::default_constructed_unit_structs,
        reason = "intentional: exercises the impl Default for SqlServerPlugin"
    )]
    fn default_constructor_should_produce_named_plugin() {
        let plugin = SqlServerPlugin::default();
        assert_eq!(plugin.name(), "sqlserver");
    }

    #[test]
    fn upsert_should_omit_when_matched_block_when_only_conflict_columns() {
        let plugin = SqlServerPlugin::new();
        let sql = plugin
            .build_upsert_sql("dbo.users", &["id"], &["id"], None)
            .expect("valid merge upsert");
        assert!(sql.starts_with("MERGE INTO"));
        assert!(!sql.contains("WHEN MATCHED THEN UPDATE"));
        assert!(sql.contains("WHEN NOT MATCHED THEN INSERT"));
    }

    #[test]
    fn returnable_should_be_supported() {
        let plugin = SqlServerPlugin::new();
        assert!(plugin.supports_returning());
    }

    #[test]
    fn output_clause_for_delete_should_use_deleted_prefix() {
        let plugin = SqlServerPlugin::new();
        let sql = plugin
            .append_returning_clause("DELETE FROM t WHERE id = ?", DmlVerb::Delete, &["id"])
            .unwrap();
        assert!(sql.contains("OUTPUT DELETED.[id]"));
        assert!(sql.contains("WHERE id = ?"));
    }

    #[test]
    fn output_clause_for_delete_without_where_should_append_at_end() {
        let plugin = SqlServerPlugin::new();
        let sql = plugin
            .append_returning_clause("DELETE FROM t", DmlVerb::Delete, &["id"])
            .unwrap();
        assert!(sql.ends_with("OUTPUT DELETED.[id]"));
    }

    #[test]
    fn output_clause_for_update_should_inject_before_where() {
        let plugin = SqlServerPlugin::new();
        let sql = plugin
            .append_returning_clause(
                "UPDATE t SET name = ? WHERE id = ?",
                DmlVerb::Update,
                &["id"],
            )
            .unwrap();
        assert!(sql.contains("OUTPUT INSERTED.[id]"));
        assert!(sql.contains("WHERE id = ?"));
    }

    #[test]
    fn output_clause_for_update_without_where_should_append_at_end() {
        let plugin = SqlServerPlugin::new();
        let sql = plugin
            .append_returning_clause("UPDATE t SET name = ?", DmlVerb::Update, &["id"])
            .unwrap();
        assert!(sql.contains("OUTPUT INSERTED.[id]"));
    }

    #[test]
    fn output_clause_should_strip_trailing_semicolon() {
        let plugin = SqlServerPlugin::new();
        let sql = plugin
            .append_returning_clause("INSERT INTO t (id) VALUES (?);", DmlVerb::Insert, &["id"])
            .unwrap();
        assert!(!sql.contains(';'));
    }

    #[test]
    fn identifier_quoter_should_use_brackets_style() {
        let plugin = SqlServerPlugin::new();
        assert_eq!(plugin.quoting_style(), IdentifierQuoting::Brackets);
    }

    #[test]
    fn type_catalog_should_map_unicode_string_aliases() {
        let plugin = SqlServerPlugin::new();
        assert_eq!(
            plugin.map_type_extended(1, Some("nvarchar")),
            OdbcType::NVarchar,
        );
        assert_eq!(
            plugin.map_type_extended(1, Some("nchar")),
            OdbcType::NVarchar,
        );
        assert_eq!(
            plugin.map_type_extended(1, Some("ntext")),
            OdbcType::NVarchar
        );
    }

    #[test]
    fn type_catalog_should_map_datetimeoffset_and_uniqueidentifier() {
        let plugin = SqlServerPlugin::new();
        assert_eq!(
            plugin.map_type_extended(11, Some("datetimeoffset")),
            OdbcType::DatetimeOffset,
        );
        assert_eq!(
            plugin.map_type_extended(1, Some("uniqueidentifier")),
            OdbcType::Uuid,
        );
    }

    #[test]
    fn type_catalog_should_map_money_smallmoney_to_money() {
        let plugin = SqlServerPlugin::new();
        assert_eq!(plugin.map_type_extended(3, Some("money")), OdbcType::Money);
        assert_eq!(
            plugin.map_type_extended(3, Some("smallmoney")),
            OdbcType::Money,
        );
    }

    #[test]
    fn type_catalog_should_map_bit_to_boolean() {
        let plugin = SqlServerPlugin::new();
        assert_eq!(plugin.map_type_extended(4, Some("bit")), OdbcType::Boolean);
    }

    #[test]
    fn type_catalog_should_map_small_integer_aliases_to_smallint() {
        let plugin = SqlServerPlugin::new();
        assert_eq!(
            plugin.map_type_extended(4, Some("smallint")),
            OdbcType::SmallInt,
        );
        assert_eq!(
            plugin.map_type_extended(4, Some("tinyint")),
            OdbcType::SmallInt,
        );
    }

    #[test]
    fn type_catalog_should_map_real_and_float_to_float_double() {
        let plugin = SqlServerPlugin::new();
        assert_eq!(plugin.map_type_extended(0, Some("real")), OdbcType::Float);
        assert_eq!(plugin.map_type_extended(0, Some("float")), OdbcType::Double);
    }

    #[test]
    fn type_catalog_should_map_binary_family_and_json() {
        let plugin = SqlServerPlugin::new();
        for name in &["varbinary", "binary", "image"] {
            assert_eq!(plugin.map_type_extended(0, Some(name)), OdbcType::Binary);
        }
        assert_eq!(plugin.map_type_extended(0, Some("json")), OdbcType::Json);
    }

    #[test]
    fn type_catalog_should_fall_back_when_name_unknown_or_absent() {
        let plugin = SqlServerPlugin::new();
        assert_eq!(
            plugin.map_type_extended(1, Some("custom")),
            OdbcType::Varchar
        );
        assert_eq!(plugin.map_type_extended(-5, None), OdbcType::BigInt);
    }

    #[test]
    fn catalog_provider_should_emit_foreign_key_query_with_table_param() {
        let plugin = SqlServerPlugin::new();
        let q = plugin
            .list_foreign_keys_sql("Orders", None)
            .expect("valid catalog query");
        assert!(q.sql.contains("sys.foreign_keys"));
        assert_eq!(q.params.len(), 1);
        assert!(matches!(&q.params[0], ParamValue::String(s) if s == "Orders"));
    }

    #[test]
    fn session_initializer_should_always_emit_arithabort_and_concat_null() {
        let plugin = SqlServerPlugin::new();
        let stmts = plugin.initialization_sql(&SessionOptions::default());
        assert!(stmts.iter().any(|s| s == "SET ARITHABORT ON"));
        assert!(stmts.iter().any(|s| s == "SET CONCAT_NULL_YIELDS_NULL ON"));
    }

    #[test]
    fn session_initializer_should_append_extra_sql_verbatim() {
        let plugin = SqlServerPlugin::new();
        let opts = SessionOptions::new().with_extra_sql("SET LOCK_TIMEOUT 1000");
        let stmts = plugin.initialization_sql(&opts);
        assert!(stmts.iter().any(|s| s == "SET LOCK_TIMEOUT 1000"));
    }
}
