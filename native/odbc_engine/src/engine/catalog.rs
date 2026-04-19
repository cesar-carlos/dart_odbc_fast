use crate::engine::core::QueryPipeline;
use crate::error::{OdbcError, Result};
use crate::plugins::capabilities::catalog_provider::CatalogQuery;
use crate::protocol::ParamValue;
use odbc_api::Connection;
use std::sync::Arc;

lazy_static::lazy_static! {
    static ref PIPELINE: Arc<QueryPipeline> = Arc::new(QueryPipeline::new(100));
}

/// Resolve the dialect-specific `CatalogQuery` for the live connection. Falls
/// back to the supplied default when no `CatalogProvider` plugin matches.
///
/// `live_query` is invoked with `&dyn CatalogProvider` *if* the connection's
/// DBMS name maps to a registered plugin that implements the trait. This is
/// what makes `list_tables` work on Oracle/Sybase/SQLite/Db2 (which do NOT
/// have `INFORMATION_SCHEMA`) without changing the FFI signature.
fn dispatch_catalog<F>(conn: &Connection<'static>, live_query: F) -> Option<Result<CatalogQuery>>
where
    F: FnOnce(
        &dyn crate::plugins::capabilities::catalog_provider::CatalogProvider,
    ) -> Result<CatalogQuery>,
{
    use crate::engine::core::DriverCapabilities;
    use crate::plugins::{
        capabilities::catalog_provider::CatalogProvider, db2::Db2Plugin, mariadb::MariaDbPlugin,
        mysql::MySqlPlugin, oracle::OraclePlugin, postgres::PostgresPlugin,
        snowflake::SnowflakePlugin, sqlite::SqlitePlugin, sqlserver::SqlServerPlugin,
        sybase::SybasePlugin, PluginRegistry,
    };

    // 1. Ask the live connection who it is via `SQLGetInfo(SQL_DBMS_NAME)`.
    let dbms_name = conn.database_management_system_name().ok()?;
    let caps = DriverCapabilities::from_driver_name(&dbms_name);
    let plugin_id = PluginRegistry::plugin_id_for_dbms_name(&caps.driver_name)?;

    // 2. Dispatch to the concrete plugin (each implements `CatalogProvider`).
    let q = match plugin_id {
        "sqlserver" => live_query(&SqlServerPlugin::new() as &dyn CatalogProvider),
        "postgres" => live_query(&PostgresPlugin::new() as &dyn CatalogProvider),
        "mysql" => live_query(&MySqlPlugin::new() as &dyn CatalogProvider),
        "mariadb" => live_query(&MariaDbPlugin::new() as &dyn CatalogProvider),
        "oracle" => live_query(&OraclePlugin::new() as &dyn CatalogProvider),
        "sybase" => live_query(&SybasePlugin::new() as &dyn CatalogProvider),
        "sqlite" => live_query(&SqlitePlugin::new() as &dyn CatalogProvider),
        "db2" => live_query(&Db2Plugin::new() as &dyn CatalogProvider),
        "snowflake" => live_query(&SnowflakePlugin::new() as &dyn CatalogProvider),
        _ => return None,
    };
    Some(q)
}

fn execute_catalog_query(conn: &Connection<'static>, q: CatalogQuery) -> Result<Vec<u8>> {
    if q.params.is_empty() {
        PIPELINE.execute_direct(conn, &q.sql)
    } else {
        PIPELINE.execute_with_params(conn, &q.sql, &q.params)
    }
}

/// Lists tables. Uses the dialect-specific `CatalogProvider` of the
/// connection's plugin (Oracle ALL_TABLES, Sybase sysobjects, SQLite
/// sqlite_master, Db2 SYSCAT, ...) when available, falling back to
/// `INFORMATION_SCHEMA` for engines without a registered plugin.
///
/// Returns binary protocol (same as `odbc_exec_query`).
pub fn list_tables(
    conn: &Connection<'static>,
    catalog: Option<&str>,
    schema: Option<&str>,
) -> Result<Vec<u8>> {
    if let Some(q) = dispatch_catalog(conn, |p| p.list_tables_sql(catalog, schema)) {
        return execute_catalog_query(conn, q?);
    }

    // Fallback: legacy INFORMATION_SCHEMA path used when no plugin matches.
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

/// Lists columns for a table. Uses the dialect-specific `CatalogProvider`
/// when available; falls back to `INFORMATION_SCHEMA.COLUMNS` otherwise.
pub fn list_columns(conn: &Connection<'static>, table: &str) -> Result<Vec<u8>> {
    let (schema, table_name) = validate_and_parse_table(table)?;
    let schema = schema.as_deref();
    if let Some(q) = dispatch_catalog(conn, |p| p.list_columns_sql(&table_name, schema)) {
        return execute_catalog_query(conn, q?);
    }

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

/// Lists primary keys for a table from INFORMATION_SCHEMA.
/// table: TABLE_NAME (and optionally TABLE_SCHEMA via "schema.table").
/// Returns binary protocol (same as odbc_exec_query).
/// Result columns: TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, CONSTRAINT_NAME
pub fn list_primary_keys(conn: &Connection<'static>, table: &str) -> Result<Vec<u8>> {
    let (schema, table_name) = validate_and_parse_table(table)?;
    let schema = schema.as_deref();
    if let Some(q) = dispatch_catalog(conn, |p| p.list_primary_keys_sql(&table_name, schema)) {
        return execute_catalog_query(conn, q?);
    }

    let (sql, params): (String, Vec<ParamValue>) = if let Some(sch) = schema {
        (
            "SELECT \
                kcu.TABLE_NAME, \
                kcu.COLUMN_NAME, \
                kcu.ORDINAL_POSITION, \
                tc.CONSTRAINT_NAME \
             FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc \
             JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu \
                ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME \
                AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA \
                AND tc.TABLE_NAME = kcu.TABLE_NAME \
             WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY' \
                AND tc.TABLE_SCHEMA = ? \
                AND tc.TABLE_NAME = ? \
             ORDER BY kcu.ORDINAL_POSITION"
                .to_string(),
            vec![
                ParamValue::String(sch.to_string()),
                ParamValue::String(table_name),
            ],
        )
    } else {
        (
            "SELECT \
                kcu.TABLE_NAME, \
                kcu.COLUMN_NAME, \
                kcu.ORDINAL_POSITION, \
                tc.CONSTRAINT_NAME \
             FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc \
             JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu \
                ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME \
                AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA \
                AND tc.TABLE_NAME = kcu.TABLE_NAME \
             WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY' \
                AND tc.TABLE_NAME = ? \
             ORDER BY kcu.ORDINAL_POSITION"
                .to_string(),
            vec![ParamValue::String(table_name)],
        )
    };

    PIPELINE.execute_with_params(conn, &sql, &params)
}

/// Lists foreign keys for a table from INFORMATION_SCHEMA.
/// table: TABLE_NAME (and optionally TABLE_SCHEMA via "schema.table").
/// Returns binary protocol (same as odbc_exec_query).
/// Result columns: CONSTRAINT_NAME, FROM_TABLE, FROM_COLUMN, TO_TABLE, TO_COLUMN, UPDATE_RULE, DELETE_RULE
pub fn list_foreign_keys(conn: &Connection<'static>, table: &str) -> Result<Vec<u8>> {
    let (schema, table_name) = validate_and_parse_table(table)?;
    let schema = schema.as_deref();
    if let Some(q) = dispatch_catalog(conn, |p| p.list_foreign_keys_sql(&table_name, schema)) {
        return execute_catalog_query(conn, q?);
    }

    let (sql, params): (String, Vec<ParamValue>) = if let Some(sch) = schema {
        (
            "SELECT \
                rc.CONSTRAINT_NAME, \
                kcu1.TABLE_NAME AS FROM_TABLE, \
                kcu1.COLUMN_NAME AS FROM_COLUMN, \
                kcu2.TABLE_NAME AS TO_TABLE, \
                kcu2.COLUMN_NAME AS TO_COLUMN, \
                rc.UPDATE_RULE, \
                rc.DELETE_RULE \
             FROM INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS rc \
             JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu1 \
                ON rc.CONSTRAINT_NAME = kcu1.CONSTRAINT_NAME \
                AND rc.CONSTRAINT_SCHEMA = kcu1.CONSTRAINT_SCHEMA \
             JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu2 \
                ON rc.UNIQUE_CONSTRAINT_NAME = kcu2.CONSTRAINT_NAME \
                AND rc.UNIQUE_CONSTRAINT_SCHEMA = kcu2.CONSTRAINT_SCHEMA \
                AND kcu1.ORDINAL_POSITION = kcu2.ORDINAL_POSITION \
             WHERE kcu1.TABLE_SCHEMA = ? \
                AND kcu1.TABLE_NAME = ? \
             ORDER BY rc.CONSTRAINT_NAME, kcu1.ORDINAL_POSITION"
                .to_string(),
            vec![
                ParamValue::String(sch.to_string()),
                ParamValue::String(table_name),
            ],
        )
    } else {
        (
            "SELECT \
                rc.CONSTRAINT_NAME, \
                kcu1.TABLE_NAME AS FROM_TABLE, \
                kcu1.COLUMN_NAME AS FROM_COLUMN, \
                kcu2.TABLE_NAME AS TO_TABLE, \
                kcu2.COLUMN_NAME AS TO_COLUMN, \
                rc.UPDATE_RULE, \
                rc.DELETE_RULE \
             FROM INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS rc \
             JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu1 \
                ON rc.CONSTRAINT_NAME = kcu1.CONSTRAINT_NAME \
                AND rc.CONSTRAINT_SCHEMA = kcu1.CONSTRAINT_SCHEMA \
             JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu2 \
                ON rc.UNIQUE_CONSTRAINT_NAME = kcu2.CONSTRAINT_NAME \
                AND rc.UNIQUE_CONSTRAINT_SCHEMA = kcu2.CONSTRAINT_SCHEMA \
                AND kcu1.ORDINAL_POSITION = kcu2.ORDINAL_POSITION \
             WHERE kcu1.TABLE_NAME = ? \
             ORDER BY rc.CONSTRAINT_NAME, kcu1.ORDINAL_POSITION"
                .to_string(),
            vec![ParamValue::String(table_name)],
        )
    };

    PIPELINE.execute_with_params(conn, &sql, &params)
}

/// Lists indexes for a table.
/// table: TABLE_NAME (and optionally TABLE_SCHEMA via "schema.table").
/// Returns binary protocol (same as odbc_exec_query).
/// Result columns: INDEX_NAME, TABLE_NAME, COLUMN_NAME, IS_UNIQUE, IS_PRIMARY, ORDINAL_POSITION
///
/// Note: INFORMATION_SCHEMA doesn't have a standard INDEXES view, so this implementation
/// uses database-specific queries. For maximum portability, we construct a union query
/// that works across SQL Server, PostgreSQL, MySQL, and Oracle.
pub fn list_indexes(conn: &Connection<'static>, table: &str) -> Result<Vec<u8>> {
    let (schema, table_name) = validate_and_parse_table(table)?;
    let schema = schema.as_deref();
    if let Some(q) = dispatch_catalog(conn, |p| p.list_indexes_sql(&table_name, schema)) {
        return execute_catalog_query(conn, q?);
    }

    // Unified query that works across major databases
    // We return indexes from constraints (PKs and unique constraints) as a baseline
    // Note: This is a simplified version; full index metadata would require database-specific queries
    let (sql, params): (String, Vec<ParamValue>) = if let Some(sch) = schema {
        (
            "SELECT \
                tc.CONSTRAINT_NAME AS INDEX_NAME, \
                kcu.TABLE_NAME, \
                kcu.COLUMN_NAME, \
                CASE WHEN tc.CONSTRAINT_TYPE = 'UNIQUE' THEN 1 ELSE 0 END AS IS_UNIQUE, \
                CASE WHEN tc.CONSTRAINT_TYPE = 'PRIMARY KEY' THEN 1 ELSE 0 END AS IS_PRIMARY, \
                kcu.ORDINAL_POSITION \
             FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc \
             JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu \
                ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME \
                AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA \
                AND tc.TABLE_NAME = kcu.TABLE_NAME \
             WHERE (tc.CONSTRAINT_TYPE = 'PRIMARY KEY' OR tc.CONSTRAINT_TYPE = 'UNIQUE') \
                AND tc.TABLE_SCHEMA = ? \
                AND tc.TABLE_NAME = ? \
             ORDER BY tc.CONSTRAINT_NAME, kcu.ORDINAL_POSITION"
                .to_string(),
            vec![
                ParamValue::String(sch.to_string()),
                ParamValue::String(table_name),
            ],
        )
    } else {
        (
            "SELECT \
                tc.CONSTRAINT_NAME AS INDEX_NAME, \
                kcu.TABLE_NAME, \
                kcu.COLUMN_NAME, \
                CASE WHEN tc.CONSTRAINT_TYPE = 'UNIQUE' THEN 1 ELSE 0 END AS IS_UNIQUE, \
                CASE WHEN tc.CONSTRAINT_TYPE = 'PRIMARY KEY' THEN 1 ELSE 0 END AS IS_PRIMARY, \
                kcu.ORDINAL_POSITION \
             FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc \
             JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu \
                ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME \
                AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA \
                AND tc.TABLE_NAME = kcu.TABLE_NAME \
             WHERE (tc.CONSTRAINT_TYPE = 'PRIMARY KEY' OR tc.CONSTRAINT_TYPE = 'UNIQUE') \
                AND tc.TABLE_NAME = ? \
             ORDER BY tc.CONSTRAINT_NAME, kcu.ORDINAL_POSITION"
                .to_string(),
            vec![ParamValue::String(table_name)],
        )
    };

    PIPELINE.execute_with_params(conn, &sql, &params)
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

    #[test]
    fn test_validate_and_parse_table_multiple_dots_uses_last_as_separator() {
        let (schema, name) = validate_and_parse_table("cat.schema.mytable").unwrap();
        assert_eq!(schema.as_deref(), Some("cat.schema"));
        assert_eq!(name, "mytable");
    }

    #[test]
    fn test_validate_and_parse_table_single_char_table() {
        let (schema, name) = validate_and_parse_table("x").unwrap();
        assert!(schema.is_none());
        assert_eq!(name, "x");
    }

    // Note: Full integration tests for list_primary_keys, list_foreign_keys, and list_indexes
    // are in the E2E test suite (tests/e2e_multi_db) which runs against real databases.
    // Unit tests here focus on input validation and query construction logic.
}
