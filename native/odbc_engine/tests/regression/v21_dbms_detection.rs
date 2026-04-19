//! v2.1 — Live DBMS detection via `SQLGetInfo`.
//!
//! `DriverCapabilities::detect_from_connection_string` is the legacy
//! heuristic; it should map common patterns to the right canonical engine
//! id, including the **new** engines added in v2.1.
//!
//! `DriverCapabilities::from_driver_name` must accept the **server-reported**
//! DBMS name (`SQL_DBMS_NAME`) in addition to the canonical id, so that the
//! live `detect()` path on an open connection produces the right engine id.

use odbc_engine::engine::core::{
    DriverCapabilities, ENGINE_BIGQUERY, ENGINE_DB2, ENGINE_MARIADB, ENGINE_MYSQL, ENGINE_POSTGRES,
    ENGINE_REDSHIFT, ENGINE_SNOWFLAKE, ENGINE_SQLITE, ENGINE_SQLSERVER, ENGINE_SYBASE_ASA,
    ENGINE_SYBASE_ASE, ENGINE_UNKNOWN,
};
use odbc_engine::plugins::PluginRegistry;

#[test]
fn dbms_name_microsoft_sql_server_resolves_to_sqlserver_engine() {
    let caps = DriverCapabilities::from_driver_name("Microsoft SQL Server");
    assert_eq!(caps.engine, ENGINE_SQLSERVER);
}

#[test]
fn dbms_name_postgresql_resolves_to_postgres_engine() {
    let caps = DriverCapabilities::from_driver_name("PostgreSQL");
    assert_eq!(caps.engine, ENGINE_POSTGRES);
}

#[test]
fn dbms_name_mariadb_distinguished_from_mysql() {
    assert_eq!(
        DriverCapabilities::from_driver_name("MariaDB").engine,
        ENGINE_MARIADB
    );
    assert_eq!(
        DriverCapabilities::from_driver_name("MySQL").engine,
        ENGINE_MYSQL
    );
}

#[test]
fn dbms_name_sybase_variants_distinguished() {
    assert_eq!(
        DriverCapabilities::from_driver_name("Adaptive Server Anywhere").engine,
        ENGINE_SYBASE_ASA
    );
    assert_eq!(
        DriverCapabilities::from_driver_name("Adaptive Server Enterprise").engine,
        ENGINE_SYBASE_ASE
    );
}

#[test]
fn dbms_name_db2_snowflake_redshift_bigquery_recognised() {
    assert_eq!(
        DriverCapabilities::from_driver_name("IBM Db2").engine,
        ENGINE_DB2
    );
    assert_eq!(
        DriverCapabilities::from_driver_name("Snowflake").engine,
        ENGINE_SNOWFLAKE
    );
    assert_eq!(
        DriverCapabilities::from_driver_name("Amazon Redshift").engine,
        ENGINE_REDSHIFT
    );
    assert_eq!(
        DriverCapabilities::from_driver_name("Google BigQuery").engine,
        ENGINE_BIGQUERY
    );
}

#[test]
fn dbms_name_sqlite_recognised() {
    assert_eq!(
        DriverCapabilities::from_driver_name("SQLite").engine,
        ENGINE_SQLITE
    );
}

#[test]
fn dbms_name_unknown_falls_back_to_unknown_engine() {
    let caps = DriverCapabilities::from_driver_name("CompletelyMadeUpDB v9");
    assert_eq!(caps.engine, ENGINE_UNKNOWN);
}

#[test]
fn registry_maps_server_dbms_name_to_correct_plugin() {
    let registry = PluginRegistry::default();

    assert!(registry
        .get_for_dbms_name("Microsoft SQL Server")
        .is_some_and(|p| p.name() == "sqlserver"));
    assert!(registry
        .get_for_dbms_name("PostgreSQL")
        .is_some_and(|p| p.name() == "postgres"));
    assert!(registry
        .get_for_dbms_name("MySQL")
        .is_some_and(|p| p.name() == "mysql"));
    // MariaDB now has its own dedicated plugin (v3.0).
    assert!(registry
        .get_for_dbms_name("MariaDB")
        .is_some_and(|p| p.name() == "mariadb"));
    assert!(registry
        .get_for_dbms_name("Adaptive Server Anywhere")
        .is_some_and(|p| p.name() == "sybase"));
    assert!(registry
        .get_for_dbms_name("Adaptive Server Enterprise")
        .is_some_and(|p| p.name() == "sybase"));
    // Snowflake gained a dedicated plugin in v3.0.
    assert!(registry
        .get_for_dbms_name("Snowflake")
        .is_some_and(|p| p.name() == "snowflake"));
    assert!(registry.get_for_dbms_name("FantasyDB").is_none());
}

#[test]
fn plugin_id_for_dbms_name_helper_is_canonical() {
    assert_eq!(
        PluginRegistry::plugin_id_for_dbms_name("Microsoft SQL Server"),
        Some("sqlserver")
    );
    assert_eq!(
        PluginRegistry::plugin_id_for_dbms_name("PostgreSQL"),
        Some("postgres")
    );
    assert_eq!(
        PluginRegistry::plugin_id_for_dbms_name("MySQL"),
        Some("mysql")
    );
    assert_eq!(
        PluginRegistry::plugin_id_for_dbms_name("MariaDB"),
        Some("mariadb")
    );
    assert_eq!(
        PluginRegistry::plugin_id_for_dbms_name("Adaptive Server Anywhere"),
        Some("sybase")
    );
    assert_eq!(
        PluginRegistry::plugin_id_for_dbms_name("Adaptive Server Enterprise"),
        Some("sybase")
    );
    assert_eq!(
        PluginRegistry::plugin_id_for_dbms_name("Snowflake"),
        Some("snowflake")
    );
}

#[test]
fn capabilities_engine_field_exposed_in_json() {
    let caps = DriverCapabilities::from_driver_name("PostgreSQL");
    let json = caps.to_json().expect("json");
    assert!(
        json.contains("\"engine\":\"postgres\""),
        "engine field missing from JSON: {json}"
    );
}
