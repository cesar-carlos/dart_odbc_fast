mod helpers;
use helpers::e2e::{detect_database_type, should_run_e2e_tests, DatabaseType};
use helpers::get_sqlserver_test_dsn;
use odbc_engine::{
    engine::{IsolationLevel, Savepoint},
    execute_query_with_connection, BinaryProtocolDecoder, OdbcConnection, OdbcEnvironment,
};

fn decode_integer(data: &[u8]) -> i32 {
    if data.len() >= 4 {
        i32::from_le_bytes([data[0], data[1], data[2], data[3]])
    } else if data.len() >= 8 {
        i64::from_le_bytes([
            data[0], data[1], data[2], data[3], data[4], data[5], data[6], data[7],
        ]) as i32
    } else {
        String::from_utf8_lossy(data)
            .trim()
            .parse::<i32>()
            .unwrap_or_else(|_| panic!("Could not decode integer from: {:?}", data))
    }
}

#[test]
#[ignore]
fn test_transaction_commit() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("Init failed");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("Connect failed");
    let conn_id = conn.get_connection_id();

    const TBL: &str = "txn_test_commit";
    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        let _ = execute_query_with_connection(
            c,
            &format!("IF OBJECT_ID(N'{TBL}', N'U') IS NOT NULL DROP TABLE {TBL}"),
        );
        execute_query_with_connection(
            c,
            &format!("CREATE TABLE {TBL} (id INT, value VARCHAR(50))"),
        )
        .unwrap();
    }

    let txn = conn
        .begin_transaction(IsolationLevel::ReadCommitted)
        .unwrap();
    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, &format!("INSERT INTO {TBL} VALUES (1, 'test')")).unwrap();
    }
    txn.commit().expect("Commit failed");

    let buf = {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, &format!("SELECT COUNT(*) AS cnt FROM {TBL}")).unwrap()
    };
    let decoded = BinaryProtocolDecoder::parse(&buf).unwrap();
    let count = decode_integer(decoded.rows[0][0].as_ref().unwrap());
    assert_eq!(count, 1);

    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, &format!("DROP TABLE {TBL}")).unwrap();
    }
    conn.disconnect().expect("Disconnect failed");
}

#[test]
#[ignore]
fn test_transaction_rollback() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("Init failed");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("Connect failed");
    let conn_id = conn.get_connection_id();

    const TBL: &str = "txn_test_rollback";
    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        let _ = execute_query_with_connection(
            c,
            &format!("IF OBJECT_ID(N'{TBL}', N'U') IS NOT NULL DROP TABLE {TBL}"),
        );
        execute_query_with_connection(c, &format!("CREATE TABLE {TBL} (id INT)")).unwrap();
    }

    {
        let txn = conn
            .begin_transaction(IsolationLevel::ReadCommitted)
            .unwrap();
        {
            let h = handles.lock().unwrap();
            let c = h.get_connection(conn_id).unwrap();
            execute_query_with_connection(c, &format!("INSERT INTO {TBL} VALUES (1)")).unwrap();
        }
        txn.rollback().expect("Rollback failed");
    }

    let buf = {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, &format!("SELECT COUNT(*) AS cnt FROM {TBL}")).unwrap()
    };
    let decoded = BinaryProtocolDecoder::parse(&buf).unwrap();
    let count = decode_integer(decoded.rows[0][0].as_ref().unwrap());
    assert_eq!(count, 0);

    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, &format!("DROP TABLE {TBL}")).unwrap();
    }
    conn.disconnect().expect("Disconnect failed");
}

#[test]
#[ignore]
fn test_transaction_auto_rollback_on_error() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("Init failed");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("Connect failed");
    let conn_id = conn.get_connection_id();

    const TBL: &str = "txn_test_auto_rollback";
    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        let _ = execute_query_with_connection(
            c,
            &format!("IF OBJECT_ID(N'{TBL}', N'U') IS NOT NULL DROP TABLE {TBL}"),
        );
        execute_query_with_connection(c, &format!("CREATE TABLE {TBL} (id INT PRIMARY KEY)"))
            .unwrap();
    }

    let result = conn.with_transaction(IsolationLevel::ReadCommitted, |_txn| {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, &format!("INSERT INTO {TBL} VALUES (1)"))?;
        execute_query_with_connection(c, &format!("INSERT INTO {TBL} VALUES (1)"))?;
        Ok::<(), odbc_engine::OdbcError>(())
    });
    assert!(result.is_err());

    let buf = {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, &format!("SELECT COUNT(*) AS cnt FROM {TBL}")).unwrap()
    };
    let decoded = BinaryProtocolDecoder::parse(&buf).unwrap();
    let count = decode_integer(decoded.rows[0][0].as_ref().unwrap());
    assert_eq!(count, 0);

    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, &format!("DROP TABLE {TBL}")).unwrap();
    }
    conn.disconnect().expect("Disconnect failed");
}

/// Savepoints for nested transactions. Uses SAVE TRANSACTION / ROLLBACK TRANSACTION
/// on SQL Server and SAVEPOINT / ROLLBACK TO SAVEPOINT on PostgreSQL-style DBs.
#[test]
#[ignore]
fn test_savepoint() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build connection string");
    let db_type = detect_database_type(&conn_str);
    let use_save_transaction_syntax = db_type == DatabaseType::SqlServer;

    let env = OdbcEnvironment::new();
    env.init().expect("Init failed");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("Connect failed");
    let conn_id = conn.get_connection_id();

    const TBL: &str = "txn_test_savepoint";
    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        let _ = execute_query_with_connection(
            c,
            &format!("IF OBJECT_ID(N'{TBL}', N'U') IS NOT NULL DROP TABLE {TBL}"),
        );
        execute_query_with_connection(c, &format!("CREATE TABLE {TBL} (id INT)")).unwrap();
    }

    conn.with_transaction(IsolationLevel::ReadCommitted, |txn| {
        {
            let h = handles.lock().unwrap();
            let c = h.get_connection(conn_id).unwrap();
            execute_query_with_connection(c, &format!("INSERT INTO {TBL} VALUES (1)"))?;
        }

        if use_save_transaction_syntax {
            txn.execute_sql("SAVE TRANSACTION sp1")?;
            {
                let h = handles.lock().unwrap();
                let c = h.get_connection(conn_id).unwrap();
                execute_query_with_connection(c, &format!("INSERT INTO {TBL} VALUES (2)"))?;
            }
            txn.execute_sql("ROLLBACK TRANSACTION sp1")?;
        } else {
            let sp = Savepoint::create(txn, "sp1")?;
            {
                let h = handles.lock().unwrap();
                let c = h.get_connection(conn_id).unwrap();
                execute_query_with_connection(c, &format!("INSERT INTO {TBL} VALUES (2)"))?;
            }
            sp.rollback_to()?;
        }

        {
            let h = handles.lock().unwrap();
            let c = h.get_connection(conn_id).unwrap();
            execute_query_with_connection(c, &format!("INSERT INTO {TBL} VALUES (3)"))?;
        }
        Ok::<(), odbc_engine::OdbcError>(())
    })
    .expect("with_transaction failed");

    let buf = {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, &format!("SELECT id FROM {TBL} ORDER BY id")).unwrap()
    };
    let decoded = BinaryProtocolDecoder::parse(&buf).unwrap();
    assert_eq!(decoded.row_count, 2, "expected rows 1 and 3, not 2");
    assert_eq!(decode_integer(decoded.rows[0][0].as_ref().unwrap()), 1);
    assert_eq!(decode_integer(decoded.rows[1][0].as_ref().unwrap()), 3);

    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, &format!("DROP TABLE {TBL}")).unwrap();
    }
    conn.disconnect().expect("Disconnect failed");
}

#[test]
fn test_with_transaction_commit_on_success() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("Init failed");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("Connect failed");
    let conn_id = conn.get_connection_id();

    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        let _ = execute_query_with_connection(c, "DROP TABLE IF EXISTS txn_cov_commit_test");
        execute_query_with_connection(c, "CREATE TABLE txn_cov_commit_test (id INT)").unwrap();
    }

    let result = conn.with_transaction(IsolationLevel::ReadCommitted, |_| {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, "INSERT INTO txn_cov_commit_test VALUES (1)")?;
        Ok(())
    });
    assert!(result.is_ok());

    let buf = {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, "SELECT COUNT(*) AS cnt FROM txn_cov_commit_test").unwrap()
    };
    let decoded = BinaryProtocolDecoder::parse(&buf).unwrap();
    let count = decode_integer(decoded.rows[0][0].as_ref().unwrap());
    assert_eq!(count, 1);

    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, "DROP TABLE txn_cov_commit_test").unwrap();
    }
    conn.disconnect().expect("Disconnect failed");
}

#[test]
fn test_with_transaction_rollback_on_error() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("Init failed");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("Connect failed");
    let conn_id = conn.get_connection_id();

    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        let _ = execute_query_with_connection(c, "DROP TABLE IF EXISTS txn_cov_rollback_test");
        execute_query_with_connection(c, "CREATE TABLE txn_cov_rollback_test (id INT PRIMARY KEY)")
            .unwrap();
    }

    let result = conn.with_transaction(IsolationLevel::ReadCommitted, |_| {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, "INSERT INTO txn_cov_rollback_test VALUES (1)")?;
        execute_query_with_connection(c, "INSERT INTO txn_cov_rollback_test VALUES (1)")?;
        Ok::<(), odbc_engine::OdbcError>(())
    });
    assert!(result.is_err());

    let buf = {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, "SELECT COUNT(*) AS cnt FROM txn_cov_rollback_test")
            .unwrap()
    };
    let decoded = BinaryProtocolDecoder::parse(&buf).unwrap();
    let count = decode_integer(decoded.rows[0][0].as_ref().unwrap());
    assert_eq!(count, 0);

    {
        let h = handles.lock().unwrap();
        let c = h.get_connection(conn_id).unwrap();
        execute_query_with_connection(c, "DROP TABLE txn_cov_rollback_test").unwrap();
    }
    conn.disconnect().expect("Disconnect failed");
}

#[test]
fn test_begin_transaction_all_isolation_levels() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build connection string");
    let levels = [
        IsolationLevel::ReadUncommitted,
        IsolationLevel::ReadCommitted,
        IsolationLevel::RepeatableRead,
        IsolationLevel::Serializable,
    ];

    for level in levels {
        let env = OdbcEnvironment::new();
        env.init().expect("Init failed");
        let handles = env.get_handles();
        let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("Connect failed");

        let txn = conn
            .begin_transaction(level)
            .expect("begin_transaction failed");
        txn.commit().expect("commit failed");
        conn.disconnect().expect("Disconnect failed");
    }
}
