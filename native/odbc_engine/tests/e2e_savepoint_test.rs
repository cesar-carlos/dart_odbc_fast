/// E2E tests for savepoint FFI and engine behavior.
///
/// Savepoints use standard SQL: SAVEPOINT, ROLLBACK TO SAVEPOINT, RELEASE SAVEPOINT.
/// SQL Server uses different syntax (SAVE TRANSACTION / ROLLBACK TRANSACTION),
/// so these tests are skipped when the detected database is SQL Server.
use odbc_engine::engine::{
    execute_query_with_connection, IsolationLevel, OdbcConnection, OdbcEnvironment, Savepoint,
};
use odbc_engine::protocol::BinaryProtocolDecoder;

mod helpers;
use helpers::e2e::{is_database_type, should_run_e2e_tests, DatabaseType};
use helpers::env::get_sqlserver_test_dsn;

fn decode_int(buf: &[u8]) -> i32 {
    if buf.len() < 4 {
        return 0;
    }
    i32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]])
}

#[test]
fn test_savepoint_create_and_rollback() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: no DSN available");
        return;
    }
    if is_database_type(DatabaseType::SqlServer) {
        eprintln!("⚠️  Skipping: SQL Server uses SAVE TRANSACTION, not SAVEPOINT");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("ODBC_TEST_DSN or SQLSERVER_TEST_* not set");

    let env = OdbcEnvironment::new();
    env.init().expect("Init failed");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("Connect failed");
    let conn_id = conn.get_connection_id();

    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, "CREATE TABLE sp_test (id INT)").unwrap();
    }

    conn.with_transaction(IsolationLevel::ReadCommitted, |txn| {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        let _ = execute_query_with_connection(c, "INSERT INTO sp_test VALUES (1)")?;
        drop(h);

        let sp = Savepoint::create(txn, "sp1")?;
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        let _ = execute_query_with_connection(c, "INSERT INTO sp_test VALUES (2)")?;
        drop(h);

        sp.rollback_to()?;
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        let _ = execute_query_with_connection(c, "INSERT INTO sp_test VALUES (3)")?;
        Ok::<(), odbc_engine::OdbcError>(())
    })
    .expect("with_transaction failed");

    let buf = {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, "SELECT id FROM sp_test ORDER BY id").unwrap()
    };
    let decoded = BinaryProtocolDecoder::parse(&buf).unwrap();
    assert_eq!(
        decoded.row_count, 2,
        "expected rows 1 and 3 after rollback to savepoint"
    );
    assert_eq!(decode_int(decoded.rows[0][0].as_ref().unwrap()), 1);
    assert_eq!(decode_int(decoded.rows[1][0].as_ref().unwrap()), 3);

    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        let _ = execute_query_with_connection(c, "DROP TABLE sp_test");
    }
    conn.disconnect().expect("Disconnect failed");
}

#[test]
fn test_savepoint_release() {
    if !should_run_e2e_tests() {
        return;
    }
    if is_database_type(DatabaseType::SqlServer) {
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("DSN not set");

    let env = OdbcEnvironment::new();
    env.init().expect("Init failed");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("Connect failed");
    let conn_id = conn.get_connection_id();

    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, "CREATE TABLE sp_rel_test (id INT)").unwrap();
    }

    conn.with_transaction(IsolationLevel::ReadCommitted, |txn| {
        let sp = Savepoint::create(txn, "sp_rel")?;
        sp.release()?;
        Ok::<(), odbc_engine::OdbcError>(())
    })
    .expect("with_transaction failed");

    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        let _ = execute_query_with_connection(c, "DROP TABLE sp_rel_test");
    }
    conn.disconnect().expect("Disconnect failed");
}

#[test]
#[cfg(feature = "ffi-tests")]
fn test_ffi_savepoint_invalid_txn_id() {
    let _ = odbc_engine::odbc_init();
    const TEST_INVALID_ID: u32 = 0xDEAD_BEEF;
    let name = CString::new("sp1").unwrap();

    let r = odbc_engine::odbc_savepoint_create(TEST_INVALID_ID, name.as_ptr());
    assert!(r != 0, "savepoint_create on invalid txn_id should fail");

    let r = odbc_engine::odbc_savepoint_rollback(TEST_INVALID_ID, name.as_ptr());
    assert!(r != 0, "savepoint_rollback on invalid txn_id should fail");

    let r = odbc_engine::odbc_savepoint_release(TEST_INVALID_ID, name.as_ptr());
    assert!(r != 0, "savepoint_release on invalid txn_id should fail");
}
