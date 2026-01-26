mod helpers;
use helpers::e2e::should_run_e2e_tests;
use helpers::get_sqlserver_test_dsn;
use odbc_engine::{execute_query_with_connection, OdbcConnection, OdbcEnvironment};

#[test]
#[ignore]
fn test_structured_error_preserves_sqlstate() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("DSN");
    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("connect");
    let conn_id = conn.get_connection_id();

    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, "CREATE TABLE diag_test (id INT PRIMARY KEY)")
            .expect("create");
    }
    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, "INSERT INTO diag_test VALUES (1)").expect("insert first");
    }

    let result = {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, "INSERT INTO diag_test VALUES (1)")
    };
    assert!(result.is_err(), "duplicate insert must fail");

    let err = result.unwrap_err();
    let structured = err.to_structured();
    assert_ne!(
        structured.sqlstate, [0u8; 5],
        "ODBC constraint violation should yield non-zero SQLSTATE"
    );
    assert!(
        !structured.message.is_empty(),
        "structured error message must be non-empty"
    );

    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, "DROP TABLE diag_test").expect("drop");
    }
    conn.disconnect().expect("disconnect");
}
