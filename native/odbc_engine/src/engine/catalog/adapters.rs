use crate::engine::core::shared_row_major_pipeline;
use crate::engine::core::{
    ENGINE_DB2, ENGINE_MARIADB, ENGINE_MYSQL, ENGINE_ORACLE, ENGINE_POSTGRES, ENGINE_SNOWFLAKE,
    ENGINE_SQLITE, ENGINE_SQLSERVER, ENGINE_SYBASE_ASA, ENGINE_SYBASE_ASE,
};
use crate::engine::dbms_info::detect_engine_id;
use crate::error::Result;
use crate::handles::CachedConnection;
use crate::plugins::capabilities::catalog_provider::CatalogQuery;
use odbc_api::Connection;

/// Resolve the dialect-specific `CatalogQuery` for a known engine id.
///
/// Prefer this when the caller already has [`CachedConnection::engine_id`].
pub(crate) fn dispatch_catalog_for_engine<F>(
    engine_id: &str,
    live_query: F,
) -> Option<Result<CatalogQuery>>
where
    F: FnOnce(
        &dyn crate::plugins::capabilities::catalog_provider::CatalogProvider,
    ) -> Result<CatalogQuery>,
{
    use crate::plugins::capabilities::catalog_provider::CatalogProvider;
    use crate::plugins::{
        db2::Db2Plugin, mariadb::MariaDbPlugin, mysql::MySqlPlugin, oracle::OraclePlugin,
        postgres::PostgresPlugin, snowflake::SnowflakePlugin, sqlite::SqlitePlugin,
        sqlserver::SqlServerPlugin, sybase::SybasePlugin,
    };

    let q = match engine_id {
        ENGINE_SQLSERVER => live_query(&SqlServerPlugin::new() as &dyn CatalogProvider),
        ENGINE_POSTGRES => live_query(&PostgresPlugin::new() as &dyn CatalogProvider),
        ENGINE_MYSQL => live_query(&MySqlPlugin::new() as &dyn CatalogProvider),
        ENGINE_MARIADB => live_query(&MariaDbPlugin::new() as &dyn CatalogProvider),
        ENGINE_ORACLE => live_query(&OraclePlugin::new() as &dyn CatalogProvider),
        ENGINE_SYBASE_ASE | ENGINE_SYBASE_ASA => {
            live_query(&SybasePlugin::new() as &dyn CatalogProvider)
        }
        ENGINE_SQLITE => live_query(&SqlitePlugin::new() as &dyn CatalogProvider),
        ENGINE_DB2 => live_query(&Db2Plugin::new() as &dyn CatalogProvider),
        ENGINE_SNOWFLAKE => live_query(&SnowflakePlugin::new() as &dyn CatalogProvider),
        _ => return None,
    };
    Some(q)
}

/// Resolve the dialect-specific `CatalogQuery` for the live connection.
///
/// Uses a thin `SQL_DBMS_NAME` detect when no cached engine id is available.
pub(crate) fn dispatch_catalog<F>(
    conn: &Connection<'static>,
    live_query: F,
) -> Option<Result<CatalogQuery>>
where
    F: FnOnce(
        &dyn crate::plugins::capabilities::catalog_provider::CatalogProvider,
    ) -> Result<CatalogQuery>,
{
    let engine_id = detect_engine_id(conn).ok()?;
    dispatch_catalog_for_engine(engine_id, live_query)
}

/// Like [`dispatch_catalog`] but reuses [`CachedConnection::engine_id`].
pub(crate) fn dispatch_catalog_cached<F>(
    cached: &CachedConnection,
    live_query: F,
) -> Option<Result<CatalogQuery>>
where
    F: FnOnce(
        &dyn crate::plugins::capabilities::catalog_provider::CatalogProvider,
    ) -> Result<CatalogQuery>,
{
    let engine_id = cached.engine_id().ok()?;
    dispatch_catalog_for_engine(engine_id, live_query)
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
