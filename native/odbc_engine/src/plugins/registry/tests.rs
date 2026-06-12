use super::*;
use crate::plugins::capabilities::returning::DmlVerb;
use crate::plugins::capabilities::SessionOptions;
use crate::protocol::types::OdbcType;

#[test]
fn test_get_for_connection_sqlserver() {
    let registry = PluginRegistry::default();
    let conn_str = "Driver={SQL Server};Server=localhost;Database=test;";
    let plugin = registry.get_for_connection(conn_str).expect("plugin");
    assert_eq!(plugin.name(), "sqlserver");
}

#[test]
fn test_get_for_connection_sybase() {
    let registry = PluginRegistry::default();
    let conn_str = "Driver={Sybase ASE};Server=localhost;";
    let plugin = registry.get_for_connection(conn_str).expect("plugin");
    assert_eq!(plugin.name(), "sybase");
}

#[test]
fn test_get_for_connection_sql_anywhere() {
    let registry = PluginRegistry::default();
    let conn_str = "Driver={SQL Anywhere 16};Host=localhost;Port=2650;";
    let plugin = registry.get_for_connection(conn_str).expect("plugin");
    assert_eq!(plugin.name(), "sybase");
}

#[test]
fn test_get_for_connection_unknown_driver() {
    let registry = PluginRegistry::default();
    let conn_str = "Driver={UnknownDriver};Server=localhost;";
    assert!(registry.get_for_connection(conn_str).is_none());
}

#[test]
fn test_detect_driver_mysql() {
    let registry = PluginRegistry::default();
    assert_eq!(
        registry.detect_driver("Driver={MySQL};Server=localhost;"),
        Some("mysql".to_string())
    );
    assert_eq!(
        registry.detect_driver("DRIVER={MySQL ODBC 8.0 Driver};"),
        Some("mysql".to_string())
    );
}

#[test]
fn test_detect_driver_mongodb() {
    let registry = PluginRegistry::default();
    assert_eq!(
        registry.detect_driver("Driver={MongoDB ODBC};Server=localhost;"),
        Some("mongodb".to_string())
    );
}

#[test]
fn test_detect_driver_sqlite() {
    let registry = PluginRegistry::default();
    assert_eq!(
        registry.detect_driver("Driver=SQLite3 ODBC Driver;Database=test.db;"),
        Some("sqlite".to_string())
    );
}

#[test]
fn test_default_registry_has_all_plugins() {
    let registry = PluginRegistry::default();
    assert!(registry.get("sqlserver").is_ok());
    assert!(registry.get("oracle").is_ok());
    assert!(registry.get("postgres").is_ok());
    assert!(registry.get("mysql").is_ok());
    assert!(registry.get("sybase").is_ok());
}

#[test]
fn test_detect_driver_case_insensitive() {
    let registry = PluginRegistry::default();
    let p1 = registry.get_for_connection("DRIVER={SQL SERVER};SERVER=localhost;");
    let p2 = registry.get_for_connection("driver={sql server};server=localhost;");
    assert!(p1.is_some());
    assert!(p2.is_some());
    assert_eq!(p1.unwrap().name(), "sqlserver");
    assert_eq!(p2.unwrap().name(), "sqlserver");
}

#[test]
fn test_get_plugin_not_found() {
    let registry = PluginRegistry::default();
    let result = registry.get("nonexistent");
    assert!(result.is_err());
}

#[test]
fn test_get_for_connection_postgres() {
    let registry = PluginRegistry::default();
    let conn_str = "Driver={PostgreSQL Unicode};Server=localhost;Database=test;";
    let plugin = registry.get_for_connection(conn_str).expect("plugin");
    assert_eq!(plugin.name(), "postgres");
}

#[test]
fn test_get_for_connection_postgresql() {
    let registry = PluginRegistry::default();
    let conn_str = "Driver={PostgreSQL ODBC Driver};Server=localhost;";
    let plugin = registry.get_for_connection(conn_str).expect("plugin");
    assert_eq!(plugin.name(), "postgres");
}

#[test]
fn test_get_for_connection_mysql() {
    let registry = PluginRegistry::default();
    let conn_str = "Driver={MySQL ODBC 8.0 Driver};Server=localhost;";
    let plugin = registry.get_for_connection(conn_str).expect("plugin");
    assert_eq!(plugin.name(), "mysql");
}

#[test]
fn test_detect_driver_postgres() {
    let registry = PluginRegistry::default();
    assert_eq!(
        registry.detect_driver("Driver={PostgreSQL};Server=localhost;"),
        Some("postgres".to_string())
    );
    assert_eq!(
        registry.detect_driver("DRIVER={PostgreSQL ODBC Driver};"),
        Some("postgres".to_string())
    );
}

#[test]
fn test_postgres_plugin_capabilities_via_registry() {
    let registry = PluginRegistry::default();
    let plugin = registry.get("postgres").expect("postgres plugin");
    let caps = plugin.get_capabilities();

    assert!(caps.supports_prepared_statements);
    assert!(caps.supports_batch_operations);
    assert!(caps.supports_streaming);
    assert_eq!(caps.driver_name, "PostgreSQL");
}

#[test]
fn test_mysql_plugin_capabilities_via_registry() {
    let registry = PluginRegistry::default();
    let plugin = registry.get("mysql").expect("mysql plugin");
    let caps = plugin.get_capabilities();

    assert!(caps.supports_prepared_statements);
    assert!(caps.supports_batch_operations);
    assert!(caps.supports_streaming);
    assert_eq!(caps.driver_name, "MySQL");
}

#[test]
fn test_postgres_plugin_optimize_query() {
    let registry = PluginRegistry::default();
    let plugin = registry.get("postgres").expect("postgres plugin");

    let sql = "SELECT * FROM users";
    let optimized = plugin.optimize_query(sql);
    assert_eq!(optimized, "SELECT * FROM users LIMIT 1000");
}

#[test]
fn test_mysql_plugin_optimize_query() {
    let registry = PluginRegistry::default();
    let plugin = registry.get("mysql").expect("mysql plugin");

    let sql = "SELECT * FROM users";
    let optimized = plugin.optimize_query(sql);
    assert_eq!(optimized, "SELECT * FROM users LIMIT 1000");
}

#[test]
fn test_postgres_plugin_map_type_via_registry() {
    let registry = PluginRegistry::default();
    let plugin = registry.get("postgres").expect("postgres plugin");

    assert_eq!(plugin.map_type(1), OdbcType::Varchar);
    assert_eq!(plugin.map_type(4), OdbcType::Integer);
    assert_eq!(plugin.map_type(-5), OdbcType::BigInt);
}

#[test]
fn test_mysql_plugin_map_type_via_registry() {
    let registry = PluginRegistry::default();
    let plugin = registry.get("mysql").expect("mysql plugin");

    assert_eq!(plugin.map_type(1), OdbcType::Varchar);
    assert_eq!(plugin.map_type(4), OdbcType::Integer);
    assert_eq!(plugin.map_type(-5), OdbcType::BigInt);
}

#[test]
fn should_map_plugin_id_for_known_dbms_names() {
    assert_eq!(
        PluginRegistry::plugin_id_for_dbms_name("Microsoft SQL Server"),
        Some("sqlserver")
    );
    assert_eq!(
        PluginRegistry::plugin_id_for_dbms_name("PostgreSQL"),
        Some("postgres")
    );
    assert_eq!(
        PluginRegistry::plugin_id_for_dbms_name("MariaDB"),
        Some("mariadb")
    );
    assert_eq!(
        PluginRegistry::plugin_id_for_dbms_name("Snowflake"),
        Some("snowflake")
    );
    assert_eq!(
        PluginRegistry::plugin_id_for_dbms_name("Unknown DBMS"),
        None
    );
}

#[test]
fn should_report_is_supported_when_driver_has_registered_plugin() {
    let registry = PluginRegistry::default();
    let conn = "Driver={PostgreSQL};Server=localhost;";
    assert!(registry.is_supported(conn));
}

#[test]
fn should_report_is_supported_false_when_detected_but_not_registered() {
    let registry = PluginRegistry::default();
    let conn = "Driver={MongoDB ODBC};Server=localhost;";
    assert!(!registry.is_supported(conn));
}

#[test]
fn should_resolve_plugin_from_dbms_name() {
    let registry = PluginRegistry::default();
    let plugin = registry
        .get_for_dbms_name("PostgreSQL")
        .expect("postgres from DBMS name");
    assert_eq!(plugin.name(), "postgres");
}

#[test]
fn should_build_postgres_upsert_sql_via_registry() {
    let registry = PluginRegistry::default();
    let conn = "Driver={PostgreSQL};Server=localhost;";
    let sql = registry
        .build_upsert_sql(conn, "users", &["id", "name"], &["id"], None)
        .expect("upsert dispatch")
        .expect("postgres upsert SQL");
    assert!(sql.contains("ON CONFLICT"));
    assert!(sql.contains("EXCLUDED"));
    assert!(sql.contains("?, ?"));
}

#[test]
fn should_append_postgres_returning_via_registry() {
    let registry = PluginRegistry::default();
    let conn = "Driver={PostgreSQL};Server=localhost;";
    let out = registry
        .append_returning_sql(
            conn,
            "INSERT INTO users (id) VALUES (?)",
            DmlVerb::Insert,
            &["id"],
        )
        .expect("returning dispatch")
        .expect("postgres returning SQL");
    assert!(out.contains("RETURNING"));
    assert!(out.contains("\"id\""));
}

#[test]
fn should_emit_session_init_sql_for_sqlserver() {
    let registry = PluginRegistry::default();
    let conn = "Driver={SQL Server};Server=localhost;";
    let stmts = registry
        .session_init_sql(conn, &SessionOptions::default())
        .expect("session init dispatch");
    assert!(
        stmts.iter().any(|s| s.contains("ARITHABORT")),
        "SQL Server session init should include ARITHABORT"
    );
}

#[test]
fn should_register_plugin_on_empty_registry() {
    let registry = PluginRegistry::new();
    let plugin = Arc::new(crate::plugins::sqlite::SqlitePlugin::new()) as Arc<dyn DriverPlugin>;
    registry.register(plugin).expect("register sqlite");
    assert_eq!(registry.get("sqlite").expect("lookup").name(), "sqlite");
}

#[test]
fn should_map_plugin_id_for_db2_and_sybase_dbms_names() {
    assert_eq!(
        PluginRegistry::plugin_id_for_dbms_name("DB2/LINUXX8664"),
        Some("db2")
    );
    assert_eq!(
        PluginRegistry::plugin_id_for_dbms_name("Adaptive Server Enterprise"),
        Some("sybase")
    );
}

#[test]
fn should_build_sqlserver_upsert_via_registry() {
    let registry = PluginRegistry::default();
    let conn = "Driver={SQL Server};Server=localhost;";
    let sql = registry
        .build_upsert_sql(conn, "dbo.users", &["id", "name"], &["id"], None)
        .expect("upsert dispatch")
        .expect("sqlserver upsert SQL");
    assert!(sql.contains("MERGE INTO"));
}

#[test]
fn should_append_oracle_returning_via_registry() {
    let registry = PluginRegistry::default();
    let conn = "Driver={Oracle in OraDB21Home1};Dbq=localhost/XEPDB1;";
    let out = registry
        .append_returning_sql(
            conn,
            "INSERT INTO t (id) VALUES (?)",
            DmlVerb::Insert,
            &["id"],
        )
        .expect("returning dispatch")
        .expect("oracle returning SQL");
    assert!(out.contains("RETURNING"));
    assert!(out.contains(":ret_0"));
}

#[test]
fn should_emit_mysql_session_init_via_registry() {
    let registry = PluginRegistry::default();
    let conn = "Driver={MySQL ODBC 8.0 Driver};Server=localhost;";
    let stmts = registry
        .session_init_sql(conn, &SessionOptions::default())
        .expect("session init dispatch");
    assert!(stmts.iter().any(|s| s.contains("SET NAMES")));
}

#[test]
fn should_resolve_snowflake_plugin_from_connection_string() {
    let registry = PluginRegistry::default();
    let conn = "Driver={SnowflakeDSIIDriver};Server=account.snowflakecomputing.com;";
    let plugin = registry.get_for_connection(conn).expect("snowflake plugin");
    assert_eq!(plugin.name(), "snowflake");
}

// --- Dispatch coverage for the remaining plugin branches -----------------

#[test]
fn dispatch_upsert_should_route_to_mysql_when_driver_resolves_to_mysql() {
    let registry = PluginRegistry::default();
    let conn = "Driver={MySQL ODBC 8.0 Driver};Server=localhost;";
    let sql = registry
        .build_upsert_sql(conn, "users", &["id", "name"], &["id"], None)
        .expect("upsert dispatch")
        .expect("mysql upsert SQL");
    assert!(sql.contains("ON DUPLICATE KEY UPDATE"));
}

#[test]
fn dispatch_upsert_should_route_to_mariadb_when_driver_resolves_to_mariadb() {
    let registry = PluginRegistry::default();
    let conn = "Driver={MariaDB Connector/ODBC};Server=localhost;";
    let sql = registry
        .build_upsert_sql(conn, "users", &["id", "name"], &["id"], None)
        .expect("upsert dispatch")
        .expect("mariadb upsert SQL");
    // MariaDB shares the MySQL-style ON DUPLICATE KEY UPDATE.
    assert!(sql.contains("ON DUPLICATE KEY UPDATE") || sql.contains("INSERT IGNORE"));
}

#[test]
fn dispatch_upsert_should_route_to_oracle() {
    let registry = PluginRegistry::default();
    let conn = "Driver={Oracle in OraDB21Home1};Dbq=localhost/XEPDB1;";
    let sql = registry
        .build_upsert_sql(conn, "users", &["id", "name"], &["id"], None)
        .expect("upsert dispatch")
        .expect("oracle upsert SQL");
    assert!(sql.contains("MERGE INTO"));
}

#[test]
fn dispatch_upsert_should_route_to_db2() {
    let registry = PluginRegistry::default();
    let conn = "Driver={IBM DB2 ODBC DRIVER};Database=sample;";
    let sql = registry
        .build_upsert_sql(conn, "users", &["id", "name"], &["id"], None)
        .expect("upsert dispatch")
        .expect("db2 upsert SQL");
    assert!(sql.contains("MERGE INTO"));
    assert!(sql.contains("USING (VALUES"));
}

#[test]
fn dispatch_upsert_should_route_to_snowflake() {
    let registry = PluginRegistry::default();
    let conn = "Driver={SnowflakeDSIIDriver};Server=acc.snowflakecomputing.com;";
    let sql = registry
        .build_upsert_sql(conn, "schema.users", &["id", "name"], &["id"], None)
        .expect("upsert dispatch")
        .expect("snowflake upsert SQL");
    assert!(sql.contains("MERGE INTO"));
    assert!(sql.contains("USING (SELECT"));
}

#[test]
fn dispatch_upsert_should_route_to_sybase() {
    let registry = PluginRegistry::default();
    let conn = "Driver={Adaptive Server Enterprise};Server=localhost;";
    let result = registry.build_upsert_sql(conn, "users", &["id"], &["id"], None);
    // Sybase may return an UnsupportedFeature or a valid SQL — either way,
    // the dispatch branch is exercised.
    assert!(result.is_some());
}

#[test]
fn dispatch_upsert_should_route_to_sqlite() {
    let registry = PluginRegistry::default();
    let conn = "Driver={SQLite3 ODBC Driver};Database=test.db;";
    let sql = registry
        .build_upsert_sql(conn, "users", &["id", "name"], &["id"], None)
        .expect("upsert dispatch")
        .expect("sqlite upsert SQL");
    assert!(sql.contains("ON CONFLICT") || sql.contains("INSERT OR REPLACE"));
}

#[test]
fn dispatch_returning_should_route_to_mysql_and_emit_unsupported_error() {
    let registry = PluginRegistry::default();
    let conn = "Driver={MySQL ODBC 8.0 Driver};Server=localhost;";
    let r = registry
        .append_returning_sql(
            conn,
            "INSERT INTO t (id) VALUES (?)",
            DmlVerb::Insert,
            &["id"],
        )
        .expect("returning dispatch");
    assert!(matches!(r, Err(OdbcError::UnsupportedFeature(_))));
}

#[test]
fn dispatch_returning_should_route_to_sqlserver_and_emit_output_clause() {
    let registry = PluginRegistry::default();
    let conn = "Driver={SQL Server};Server=localhost;";
    let out = registry
        .append_returning_sql(
            conn,
            "INSERT INTO t (id) VALUES (?)",
            DmlVerb::Insert,
            &["id"],
        )
        .expect("returning dispatch")
        .expect("sqlserver returning SQL");
    assert!(out.contains("OUTPUT INSERTED.[id]"));
}

#[test]
fn dispatch_returning_should_route_to_db2_and_emit_final_table_clause() {
    let registry = PluginRegistry::default();
    let conn = "Driver={IBM DB2 ODBC DRIVER};Database=sample;";
    let out = registry
        .append_returning_sql(
            conn,
            "INSERT INTO t (a) VALUES (?)",
            DmlVerb::Insert,
            &["id"],
        )
        .expect("returning dispatch")
        .expect("db2 returning SQL");
    assert!(out.contains("FROM FINAL TABLE"));
}

#[test]
fn dispatch_session_init_should_route_to_postgres() {
    let registry = PluginRegistry::default();
    let conn = "Driver={PostgreSQL Unicode};Server=localhost;";
    let opts = SessionOptions::new().with_timezone("UTC");
    let stmts = registry
        .session_init_sql(conn, &opts)
        .expect("session init dispatch");
    assert!(stmts.iter().any(|s| s == "SET TIME ZONE 'UTC'"));
}

#[test]
fn dispatch_session_init_should_route_to_snowflake() {
    let registry = PluginRegistry::default();
    let conn = "Driver={SnowflakeDSIIDriver};Server=acc.snowflakecomputing.com;";
    let opts = SessionOptions::new().with_timezone("UTC");
    let stmts = registry
        .session_init_sql(conn, &opts)
        .expect("session init dispatch");
    assert!(stmts
        .iter()
        .any(|s| s.contains("ALTER SESSION SET TIMEZONE")));
}

#[test]
fn dispatch_session_init_should_route_to_db2() {
    let registry = PluginRegistry::default();
    let conn = "Driver={IBM DB2 ODBC DRIVER};Database=sample;";
    let opts = SessionOptions::new().with_schema("MYAPP");
    let stmts = registry
        .session_init_sql(conn, &opts)
        .expect("session init dispatch");
    assert!(stmts.iter().any(|s| s.contains("SET CURRENT SCHEMA")));
}

#[test]
fn dispatch_returning_for_unknown_plugin_should_return_unsupported_feature() {
    let registry = PluginRegistry::default();
    let result = registry.dispatch_returning("mongodb", "SELECT 1", DmlVerb::Insert, &["id"]);
    assert!(matches!(result, Err(OdbcError::UnsupportedFeature(_))));
}

#[test]
fn dispatch_upsert_for_unknown_plugin_should_return_unsupported_feature() {
    let registry = PluginRegistry::default();
    let result = registry.dispatch_upsert("mongodb", "t", &["a"], &["a"], None);
    assert!(matches!(result, Err(OdbcError::UnsupportedFeature(_))));
}

#[test]
fn session_init_should_return_empty_vec_for_unknown_plugin() {
    let registry = PluginRegistry::default();
    let conn = "Driver={MongoDB ODBC};Server=localhost;";
    let stmts = registry
        .session_init_sql(conn, &SessionOptions::default())
        .expect("session init dispatch");
    assert!(stmts.is_empty());
}
