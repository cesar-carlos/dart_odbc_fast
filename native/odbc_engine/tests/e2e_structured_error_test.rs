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
        let conn_arc = h.get_connection(conn_id).unwrap();
        let c = conn_arc.lock().unwrap();
        execute_query_with_connection(&c, "CREATE TABLE diag_test (id INT PRIMARY KEY)")
            .expect("create");
    }
    {
        let h = handles.lock().unwrap();
        let conn_arc = h.get_connection(conn_id).unwrap();
        let c = conn_arc.lock().unwrap();
        execute_query_with_connection(&c, "INSERT INTO diag_test VALUES (1)")
            .expect("insert first");
    }

    let result = {
        let h = handles.lock().unwrap();
        let conn_arc = h.get_connection(conn_id).unwrap();
        let c = conn_arc.lock().unwrap();
        execute_query_with_connection(&c, "INSERT INTO diag_test VALUES (1)")
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
        let conn_arc = h.get_connection(conn_id).unwrap();
        let c = conn_arc.lock().unwrap();
        execute_query_with_connection(&c, "DROP TABLE diag_test").expect("drop");
    }
    conn.disconnect().expect("disconnect");
}

#[test]
#[ignore]
fn test_structured_error_connection_failure() {
    let invalid_conn_str = "Driver={SQL Server};Server=invalid_host_12345;Database=test;";
    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    
    let result = OdbcConnection::connect(handles, invalid_conn_str);
    assert!(result.is_err(), "connection to invalid host must fail");
    
    if let Err(err) = result {
        let structured = err.to_structured();
        
        assert_ne!(
            structured.sqlstate, [0u8; 5],
            "connection error should have non-zero SQLSTATE"
        );
        assert!(
            !structured.message.is_empty(),
            "connection error message must be non-empty"
        );
        assert!(
            structured.native_code != 0,
            "native error code should be set"
        );
    }
}

#[test]
#[ignore]
fn test_structured_error_syntax_error() {
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

    let result = {
        let h = handles.lock().unwrap();
        let conn_arc = h.get_connection(conn_id).unwrap();
        let c = conn_arc.lock().unwrap();
        execute_query_with_connection(&c, "SELEKT * FROM invalid_syntax")
    };
    assert!(result.is_err(), "syntax error must fail");

    let err = result.unwrap_err();
    let structured = err.to_structured();
    
    assert_ne!(
        structured.sqlstate, [0u8; 5],
        "syntax error should have non-zero SQLSTATE (likely 42000)"
    );
    assert!(
        !structured.message.is_empty(),
        "syntax error message must be non-empty"
    );
    assert!(
        structured.message.to_lowercase().contains("syntax") 
            || structured.message.to_lowercase().contains("incorrect"),
        "error message should mention syntax or incorrect keyword"
    );

    conn.disconnect().expect("disconnect");
}

#[test]
#[ignore]
fn test_structured_error_table_not_found() {
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

    let result = {
        let h = handles.lock().unwrap();
        let conn_arc = h.get_connection(conn_id).unwrap();
        let c = conn_arc.lock().unwrap();
        execute_query_with_connection(&c, "SELECT * FROM nonexistent_table_xyz_12345")
    };
    assert!(result.is_err(), "query on nonexistent table must fail");

    let err = result.unwrap_err();
    let structured = err.to_structured();
    
    assert_ne!(
        structured.sqlstate, [0u8; 5],
        "table not found should have non-zero SQLSTATE"
    );
    assert!(
        !structured.message.is_empty(),
        "table not found error message must be non-empty"
    );

    conn.disconnect().expect("disconnect");
}

#[test]
#[ignore]
fn test_structured_error_column_not_found() {
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
        let conn_arc = h.get_connection(conn_id).unwrap();
        let c = conn_arc.lock().unwrap();
        execute_query_with_connection(&c, "CREATE TABLE col_test (id INT)").expect("create");
    }

    let result = {
        let h = handles.lock().unwrap();
        let conn_arc = h.get_connection(conn_id).unwrap();
        let c = conn_arc.lock().unwrap();
        execute_query_with_connection(&c, "SELECT nonexistent_column FROM col_test")
    };
    assert!(result.is_err(), "query with invalid column must fail");

    let err = result.unwrap_err();
    let structured = err.to_structured();
    
    assert_ne!(
        structured.sqlstate, [0u8; 5],
        "column not found should have non-zero SQLSTATE"
    );
    assert!(
        !structured.message.is_empty(),
        "column not found error message must be non-empty"
    );

    {
        let h = handles.lock().unwrap();
        let conn_arc = h.get_connection(conn_id).unwrap();
        let c = conn_arc.lock().unwrap();
        execute_query_with_connection(&c, "DROP TABLE col_test").expect("drop");
    }
    conn.disconnect().expect("disconnect");
}

#[test]
#[ignore]
fn test_structured_error_type_mismatch() {
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
        let conn_arc = h.get_connection(conn_id).unwrap();
        let c = conn_arc.lock().unwrap();
        execute_query_with_connection(&c, "CREATE TABLE type_test (id INT)").expect("create");
    }

    let result = {
        let h = handles.lock().unwrap();
        let conn_arc = h.get_connection(conn_id).unwrap();
        let c = conn_arc.lock().unwrap();
        execute_query_with_connection(&c, "INSERT INTO type_test VALUES ('not_a_number')")
    };
    assert!(result.is_err(), "type mismatch insert must fail");

    let err = result.unwrap_err();
    let structured = err.to_structured();
    
    assert_ne!(
        structured.sqlstate, [0u8; 5],
        "type mismatch should have non-zero SQLSTATE"
    );
    assert!(
        !structured.message.is_empty(),
        "type mismatch error message must be non-empty"
    );

    {
        let h = handles.lock().unwrap();
        let conn_arc = h.get_connection(conn_id).unwrap();
        let c = conn_arc.lock().unwrap();
        execute_query_with_connection(&c, "DROP TABLE type_test").expect("drop");
    }
    conn.disconnect().expect("disconnect");
}

#[test]
#[ignore]
fn test_structured_error_null_constraint_violation() {
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
        let conn_arc = h.get_connection(conn_id).unwrap();
        let c = conn_arc.lock().unwrap();
        execute_query_with_connection(&c, "CREATE TABLE null_test (id INT NOT NULL)")
            .expect("create");
    }

    let result = {
        let h = handles.lock().unwrap();
        let conn_arc = h.get_connection(conn_id).unwrap();
        let c = conn_arc.lock().unwrap();
        execute_query_with_connection(&c, "INSERT INTO null_test VALUES (NULL)")
    };
    assert!(result.is_err(), "NULL constraint violation must fail");

    let err = result.unwrap_err();
    let structured = err.to_structured();
    
    assert_ne!(
        structured.sqlstate, [0u8; 5],
        "NULL constraint violation should have non-zero SQLSTATE"
    );
    assert!(
        !structured.message.is_empty(),
        "NULL constraint error message must be non-empty"
    );

    {
        let h = handles.lock().unwrap();
        let conn_arc = h.get_connection(conn_id).unwrap();
        let c = conn_arc.lock().unwrap();
        execute_query_with_connection(&c, "DROP TABLE null_test").expect("drop");
    }
    conn.disconnect().expect("disconnect");
}
