use crate::engine::core::QueryPipeline;
use crate::error::{OdbcError, Result};
use crate::protocol::ParamValue;
use odbc_api::Connection;
use std::sync::Arc;

lazy_static::lazy_static! {
    static ref PIPELINE: Arc<QueryPipeline> = Arc::new(QueryPipeline::new(100));
}

/// Lists tables from INFORMATION_SCHEMA.TABLES.
/// Uses catalog/schema filters when provided (non-empty); empty or null = no filter.
/// Returns binary protocol (same as odbc_exec_query).
pub fn list_tables(
    conn: &Connection<'static>,
    catalog: Option<&str>,
    schema: Option<&str>,
) -> Result<Vec<u8>> {
    let cat = catalog.unwrap_or("").trim();
    let sch = schema.unwrap_or("").trim();

    let (sql, params): (String, Vec<ParamValue>) = if cat.is_empty() && sch.is_empty() {
        (
            "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE \
             FROM INFORMATION_SCHEMA.TABLES \
             WHERE TABLE_TYPE IN ('BASE TABLE','VIEW') \
             ORDER BY TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME"
                .to_string(),
            vec![],
        )
    } else if !cat.is_empty() && sch.is_empty() {
        (
            "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE \
             FROM INFORMATION_SCHEMA.TABLES \
             WHERE TABLE_TYPE IN ('BASE TABLE','VIEW') AND TABLE_CATALOG = ? \
             ORDER BY TABLE_SCHEMA, TABLE_NAME"
                .to_string(),
            vec![ParamValue::String(cat.to_string())],
        )
    } else if cat.is_empty() && !sch.is_empty() {
        (
            "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE \
             FROM INFORMATION_SCHEMA.TABLES \
             WHERE TABLE_TYPE IN ('BASE TABLE','VIEW') AND TABLE_SCHEMA = ? \
             ORDER BY TABLE_NAME"
                .to_string(),
            vec![ParamValue::String(sch.to_string())],
        )
    } else {
        (
            "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE \
             FROM INFORMATION_SCHEMA.TABLES \
             WHERE TABLE_TYPE IN ('BASE TABLE','VIEW') \
             AND TABLE_CATALOG = ? AND TABLE_SCHEMA = ? \
             ORDER BY TABLE_NAME"
                .to_string(),
            vec![
                ParamValue::String(cat.to_string()),
                ParamValue::String(sch.to_string()),
            ],
        )
    };

    if params.is_empty() {
        PIPELINE.execute_direct(conn, &sql)
    } else {
        PIPELINE.execute_with_params(conn, &sql, &params)
    }
}

pub(crate) fn validate_and_parse_table(table: &str) -> Result<(Option<String>, String)> {
    let table = table.trim();
    if table.is_empty() {
        return Err(OdbcError::ValidationError(
            "Table name cannot be empty".to_string(),
        ));
    }
    let (schema, table_name) = if let Some(dot) = table.rfind('.') {
        let s = table[..dot].trim().to_string();
        let t = table[dot + 1..].trim();
        if t.is_empty() {
            return Err(OdbcError::ValidationError(
                "Invalid table name (empty after schema)".to_string(),
            ));
        }
        (Some(s), t.to_string())
    } else {
        (None, table.to_string())
    };
    Ok((schema, table_name))
}

/// Lists columns for a table from INFORMATION_SCHEMA.COLUMNS.
/// table: TABLE_NAME (and optionally TABLE_SCHEMA via "schema.table").
/// Returns binary protocol (same as odbc_exec_query).
pub fn list_columns(conn: &Connection<'static>, table: &str) -> Result<Vec<u8>> {
    let (schema, table_name) = validate_and_parse_table(table)?;
    let schema = schema.as_deref();

    let (sql, params): (String, Vec<ParamValue>) = if let Some(sch) = schema {
        (
            "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, \
             ORDINAL_POSITION, DATA_TYPE, IS_NULLABLE \
             FROM INFORMATION_SCHEMA.COLUMNS \
             WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? \
             ORDER BY ORDINAL_POSITION"
                .to_string(),
            vec![
                ParamValue::String(sch.to_string()),
                ParamValue::String(table_name),
            ],
        )
    } else {
        (
            "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, \
             ORDINAL_POSITION, DATA_TYPE, IS_NULLABLE \
             FROM INFORMATION_SCHEMA.COLUMNS \
             WHERE TABLE_NAME = ? \
             ORDER BY TABLE_SCHEMA, ORDINAL_POSITION"
                .to_string(),
            vec![ParamValue::String(table_name)],
        )
    };

    PIPELINE.execute_with_params(conn, &sql, &params)
}

/// Returns distinct data types from INFORMATION_SCHEMA.COLUMNS.
/// Minimal type info for tools; full ODBC SQLGetTypeInfo would require lower-level API.
/// Returns binary protocol (same as odbc_exec_query).
pub fn get_type_info(conn: &Connection<'static>) -> Result<Vec<u8>> {
    let sql = "SELECT DISTINCT DATA_TYPE AS type_name \
               FROM INFORMATION_SCHEMA.COLUMNS \
               ORDER BY type_name";
    PIPELINE.execute_direct(conn, sql)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_and_parse_table_empty() {
        let r = validate_and_parse_table("");
        assert!(r.is_err());
        let r = validate_and_parse_table("   ");
        assert!(r.is_err());
    }

    #[test]
    fn test_validate_and_parse_table_name_only() {
        let (schema, name) = validate_and_parse_table("mytable").unwrap();
        assert!(schema.is_none());
        assert_eq!(name, "mytable");
    }

    #[test]
    fn test_validate_and_parse_table_schema_dot_table() {
        let (schema, name) = validate_and_parse_table("dbo.mytable").unwrap();
        assert_eq!(schema.as_deref(), Some("dbo"));
        assert_eq!(name, "mytable");
    }

    #[test]
    fn test_validate_and_parse_table_empty_after_dot() {
        let r = validate_and_parse_table("dbo.");
        assert!(r.is_err());
    }

    #[test]
    fn test_validate_and_parse_table_trimmed_schema_and_table() {
        let (schema, name) = validate_and_parse_table("  dbo  .  mytable  ").unwrap();
        assert_eq!(schema.as_deref(), Some("dbo"));
        assert_eq!(name, "mytable");
    }
}
