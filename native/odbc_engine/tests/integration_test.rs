use odbc_engine::*;

mod helpers;

#[test]
#[ignore] // Run with: cargo test -- --ignored; requires ODBC_TEST_DSN or SQL Server env vars
fn test_connection_lifecycle() {
    odbc_engine::test_helpers::load_dotenv();
    let conn_str = helpers::get_sqlserver_test_dsn()
        .expect("Set ODBC_TEST_DSN or SQLSERVER_TEST_* env vars for this test");
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to init");

    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect");

    conn.disconnect().expect("Failed to disconnect");
}
