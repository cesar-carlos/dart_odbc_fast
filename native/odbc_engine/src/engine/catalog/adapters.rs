use crate::engine::core::shared_row_major_pipeline;
use crate::error::Result;
use crate::plugins::capabilities::catalog_provider::CatalogQuery;
use odbc_api::Connection;

/// Resolve the dialect-specific `CatalogQuery` for the live connection. Falls
/// back to the supplied default when no `CatalogProvider` plugin matches.
///
/// `live_query` is invoked with `&dyn CatalogProvider` *if* the connection's
/// DBMS name maps to a registered plugin that implements the trait. This is
/// what makes `list_tables` work on Oracle/Sybase/SQLite/Db2 (which do NOT
/// have `INFORMATION_SCHEMA`) without changing the FFI signature.
pub(crate) fn dispatch_catalog<F>(
    conn: &Connection<'static>,
    live_query: F,
) -> Option<Result<CatalogQuery>>
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

pub(crate) fn execute_catalog_query(
    conn: &Connection<'static>,
    q: CatalogQuery,
) -> Result<Vec<u8>> {
    let pipeline = shared_row_major_pipeline();
    if q.params.is_empty() {
        pipeline.execute_direct(conn, &q.sql)
    } else {
        pipeline.execute_with_params(conn, &q.sql, &q.params)
    }
}
