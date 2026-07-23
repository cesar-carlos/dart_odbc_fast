mod adapters;
mod parsing;
mod query_builders;

use crate::engine::core::shared_row_major_pipeline;
use crate::error::Result;
use crate::handles::CachedConnection;
use adapters::{dispatch_catalog, dispatch_catalog_cached, execute_catalog_query};
use odbc_api::Connection;
pub use parsing::parse_catalog_table_ref;
pub(crate) use parsing::validate_and_parse_table;
pub(crate) use query_builders::{
    information_schema_list_columns_query, information_schema_list_foreign_keys_query,
    information_schema_list_indexes_query, information_schema_list_primary_keys_query,
    information_schema_list_tables_query, information_schema_type_info_sql,
};

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
    let (sql, params) = information_schema_list_tables_query(catalog, schema);

    let pipeline = shared_row_major_pipeline();
    if params.is_empty() {
        pipeline.execute_direct(conn, &sql)
    } else {
        pipeline.execute_with_params(conn, &sql, &params)
    }
}

/// Like [`list_tables`] but reuses [`CachedConnection::engine_id`].
pub fn list_tables_cached(
    cached: &CachedConnection,
    catalog: Option<&str>,
    schema: Option<&str>,
) -> Result<Vec<u8>> {
    let conn = cached.connection();
    if let Some(q) = dispatch_catalog_cached(cached, |p| p.list_tables_sql(catalog, schema)) {
        return execute_catalog_query(conn, q?);
    }
    let (sql, params) = information_schema_list_tables_query(catalog, schema);
    let pipeline = shared_row_major_pipeline();
    if params.is_empty() {
        pipeline.execute_direct(conn, &sql)
    } else {
        pipeline.execute_with_params(conn, &sql, &params)
    }
}

/// Lists columns for a table. Uses the dialect-specific `CatalogProvider`
/// when available; falls back to `INFORMATION_SCHEMA.COLUMNS` otherwise.
pub fn list_columns(conn: &Connection<'static>, table: &str) -> Result<Vec<u8>> {
    let (schema, table_name) = validate_and_parse_table(table)?;
    let schema = schema.as_deref();
    if let Some(q) = dispatch_catalog(conn, |p| p.list_columns_sql(&table_name, schema)) {
        return execute_catalog_query(conn, q?);
    }

    let (sql, params) = information_schema_list_columns_query(&table_name, schema);

    shared_row_major_pipeline().execute_with_params(conn, &sql, &params)
}

/// Like [`list_columns`] but reuses [`CachedConnection::engine_id`].
pub fn list_columns_cached(cached: &CachedConnection, table: &str) -> Result<Vec<u8>> {
    let (schema, table_name) = validate_and_parse_table(table)?;
    let schema = schema.as_deref();
    let conn = cached.connection();
    if let Some(q) = dispatch_catalog_cached(cached, |p| p.list_columns_sql(&table_name, schema)) {
        return execute_catalog_query(conn, q?);
    }
    let (sql, params) = information_schema_list_columns_query(&table_name, schema);
    shared_row_major_pipeline().execute_with_params(conn, &sql, &params)
}

/// Returns distinct data types from INFORMATION_SCHEMA.COLUMNS.
/// Minimal type info for tools; full ODBC SQLGetTypeInfo would require lower-level API.
/// Returns binary protocol (same as odbc_exec_query).
pub fn get_type_info(conn: &Connection<'static>) -> Result<Vec<u8>> {
    shared_row_major_pipeline().execute_direct(conn, information_schema_type_info_sql())
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

    let (sql, params) = information_schema_list_primary_keys_query(&table_name, schema);

    shared_row_major_pipeline().execute_with_params(conn, &sql, &params)
}

/// Like [`list_primary_keys`] but reuses [`CachedConnection::engine_id`].
pub fn list_primary_keys_cached(cached: &CachedConnection, table: &str) -> Result<Vec<u8>> {
    let (schema, table_name) = validate_and_parse_table(table)?;
    let schema = schema.as_deref();
    let conn = cached.connection();
    if let Some(q) =
        dispatch_catalog_cached(cached, |p| p.list_primary_keys_sql(&table_name, schema))
    {
        return execute_catalog_query(conn, q?);
    }
    let (sql, params) = information_schema_list_primary_keys_query(&table_name, schema);
    shared_row_major_pipeline().execute_with_params(conn, &sql, &params)
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

    let (sql, params) = information_schema_list_foreign_keys_query(&table_name, schema);

    shared_row_major_pipeline().execute_with_params(conn, &sql, &params)
}

/// Like [`list_foreign_keys`] but reuses [`CachedConnection::engine_id`].
pub fn list_foreign_keys_cached(cached: &CachedConnection, table: &str) -> Result<Vec<u8>> {
    let (schema, table_name) = validate_and_parse_table(table)?;
    let schema = schema.as_deref();
    let conn = cached.connection();
    if let Some(q) =
        dispatch_catalog_cached(cached, |p| p.list_foreign_keys_sql(&table_name, schema))
    {
        return execute_catalog_query(conn, q?);
    }
    let (sql, params) = information_schema_list_foreign_keys_query(&table_name, schema);
    shared_row_major_pipeline().execute_with_params(conn, &sql, &params)
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
    let (sql, params) = information_schema_list_indexes_query(&table_name, schema);

    shared_row_major_pipeline().execute_with_params(conn, &sql, &params)
}

/// Like [`list_indexes`] but reuses [`CachedConnection::engine_id`].
pub fn list_indexes_cached(cached: &CachedConnection, table: &str) -> Result<Vec<u8>> {
    let (schema, table_name) = validate_and_parse_table(table)?;
    let schema = schema.as_deref();
    let conn = cached.connection();
    if let Some(q) = dispatch_catalog_cached(cached, |p| p.list_indexes_sql(&table_name, schema)) {
        return execute_catalog_query(conn, q?);
    }
    let (sql, params) = information_schema_list_indexes_query(&table_name, schema);
    shared_row_major_pipeline().execute_with_params(conn, &sql, &params)
}
