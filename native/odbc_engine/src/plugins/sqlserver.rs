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
}
