/// E2E test for native SQL Server BCP numeric path (no fallback).
///
/// Requires:
/// - `sqlserver-bcp` feature
/// - Windows
/// - ENABLE_E2E_TESTS=1
/// - SQL Server DSN in env
use odbc_api::Connection;
use odbc_engine::{
    engine::core::sqlserver_bcp,
    execute_query_with_connection,
    protocol::{BulkColumnData, BulkColumnSpec, BulkColumnType, BulkInsertPayload},
    BinaryProtocolDecoder, OdbcConnection, OdbcEnvironment,
};
use serial_test::serial;

mod helpers;
use helpers::e2e::{get_connection_and_db_type, should_run_e2e_tests, DatabaseType};

fn decode_integer(data: &[u8]) -> i64 {
    if data.len() >= 8 {
        i64::from_le_bytes([
            data[0], data[1], data[2], data[3], data[4], data[5], data[6], data[7],
        ])
    } else if data.len() >= 4 {
        i32::from_le_bytes([data[0], data[1], data[2], data[3]]) as i64
    } else {
        String::from_utf8_lossy(data)
            .trim()
            .parse::<i64>()
            .unwrap_or(0)
    }
}

fn execute_command(conn: &Connection<'static>, sql: &str) -> Result<(), odbc_engine::OdbcError> {
    let mut stmt = conn.prepare(sql).map_err(odbc_engine::OdbcError::from)?;
    stmt.execute(()).map_err(odbc_engine::OdbcError::from)?;
    Ok(())
}

fn query_single_i64(conn: &Connection<'static>, sql: &str) -> i64 {
    let buf = execute_query_with_connection(conn, sql).expect("query failed");
    let decoded = BinaryProtocolDecoder::parse(&buf).expect("decode failed");
    decode_integer(decoded.rows[0][0].as_ref().expect("null scalar result"))
}

#[cfg(all(feature = "sqlserver-bcp", windows))]
#[test]
#[serial]
fn test_e2e_native_bcp_numeric_nullable() {
    if !should_run_e2e_tests() {
        eprintln!("Skipping native numeric BCP E2E: database not available");
        return;
    }

    let (conn_str, db_type) = get_connection_and_db_type().expect("connection string");
    if db_type != DatabaseType::SqlServer {
        eprintln!("Skipping native numeric BCP E2E: requires SQL Server");
        return;
    }

    let env = OdbcEnvironment::new();
    env.init().expect("init environment");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("connect");
    let conn_id = conn.get_connection_id();
    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().expect("lock handles");
    let conn_arc = handles_guard
        .get_connection(conn_id)
        .expect("get connection");
    let odbc_conn = conn_arc.lock().expect("lock odbc connection");

    let table = "odbc_bcp_native_numeric_test";
    let _ = execute_command(
        &odbc_conn,
        &format!(
            "IF OBJECT_ID(N'{}', N'U') IS NOT NULL DROP TABLE {}",
            table, table
        ),
    );
    execute_command(
        &odbc_conn,
        &format!(
            "CREATE TABLE {} (id INT NOT NULL PRIMARY KEY, score BIGINT NULL)",
            table
        ),
    )
    .expect("create table");

    let n: usize = 5000;
    let ids: Vec<i32> = (1..=n as i32).collect();
    let mut scores: Vec<i64> = Vec::with_capacity(n);
    let mut null_bitmap: Vec<u8> = vec![0_u8; n.div_ceil(8)];
    let mut expected_nulls: i64 = 0;
    for row in 0..n {
        if row % 7 == 0 {
            null_bitmap[row / 8] |= 1_u8 << (row % 8);
            scores.push(0);
            expected_nulls += 1;
        } else {
            scores.push((row as i64) * 10);
        }
    }

    let payload = BulkInsertPayload {
        table: table.to_string(),
        columns: vec![
            BulkColumnSpec {
                name: "id".to_string(),
                col_type: BulkColumnType::I32,
                nullable: false,
                max_len: 0,
            },
            BulkColumnSpec {
                name: "score".to_string(),
                col_type: BulkColumnType::I64,
                nullable: true,
                max_len: 0,
            },
        ],
        row_count: n as u32,
        column_data: vec![
            BulkColumnData::I32 {
                values: ids,
                null_bitmap: None,
            },
            BulkColumnData::I64 {
                values: scores,
                null_bitmap: Some(null_bitmap),
            },
        ],
    };

    let inserted = sqlserver_bcp::execute_native_bcp(conn_str.as_str(), &payload, 1000)
        .expect("native BCP insert should succeed");
    assert_eq!(inserted, n);

    let count = query_single_i64(&odbc_conn, &format!("SELECT COUNT(*) FROM {}", table));
    assert_eq!(count, n as i64);

    let nulls = query_single_i64(
        &odbc_conn,
        &format!("SELECT COUNT(*) FROM {} WHERE score IS NULL", table),
    );
    assert_eq!(nulls, expected_nulls);

    execute_command(&odbc_conn, &format!("DROP TABLE {}", table)).expect("drop table");
    drop(handles_guard);
    conn.disconnect().expect("disconnect");
}

#[cfg(all(feature = "sqlserver-bcp", windows))]
#[test]
#[serial]
fn test_e2e_native_bcp_i32_only_non_null() {
    if !should_run_e2e_tests() {
        eprintln!("Skipping native numeric BCP E2E: database not available");
        return;
    }

    let (conn_str, db_type) = get_connection_and_db_type().expect("connection string");
    if db_type != DatabaseType::SqlServer {
        eprintln!("Skipping native numeric BCP E2E: requires SQL Server");
        return;
    }

    let env = OdbcEnvironment::new();
    env.init().expect("init environment");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("connect");
    let conn_id = conn.get_connection_id();
    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().expect("lock handles");
    let conn_arc = handles_guard
        .get_connection(conn_id)
        .expect("get connection");
    let odbc_conn = conn_arc.lock().expect("lock odbc connection");

    let table = "odbc_bcp_native_i32_only_test";
    let _ = execute_command(
        &odbc_conn,
        &format!(
            "IF OBJECT_ID(N'{}', N'U') IS NOT NULL DROP TABLE {}",
            table, table
        ),
    );
    execute_command(
        &odbc_conn,
        &format!("CREATE TABLE {} (id INT NOT NULL PRIMARY KEY)", table),
    )
    .expect("create table");

    let n: usize = 3000;
    let ids: Vec<i32> = (1..=n as i32).collect();
    let payload = BulkInsertPayload {
        table: table.to_string(),
        columns: vec![BulkColumnSpec {
            name: "id".to_string(),
            col_type: BulkColumnType::I32,
            nullable: false,
            max_len: 0,
        }],
        row_count: n as u32,
        column_data: vec![BulkColumnData::I32 {
            values: ids,
            null_bitmap: None,
        }],
    };

    let inserted = sqlserver_bcp::execute_native_bcp(conn_str.as_str(), &payload, 1000)
        .expect("native BCP i32 insert should succeed");
    assert_eq!(inserted, n);

    let count = query_single_i64(&odbc_conn, &format!("SELECT COUNT(*) FROM {}", table));
    assert_eq!(count, n as i64);

    execute_command(&odbc_conn, &format!("DROP TABLE {}", table)).expect("drop table");
    drop(handles_guard);
    conn.disconnect().expect("disconnect");
}

#[cfg(all(feature = "sqlserver-bcp", windows))]
#[test]
#[serial]
fn test_e2e_native_bcp_i32_zero_rows() {
    if !should_run_e2e_tests() {
        eprintln!("Skipping native numeric BCP E2E: database not available");
        return;
    }

    let (conn_str, db_type) = get_connection_and_db_type().expect("connection string");
    if db_type != DatabaseType::SqlServer {
        eprintln!("Skipping native numeric BCP E2E: requires SQL Server");
        return;
    }

    let env = OdbcEnvironment::new();
    env.init().expect("init environment");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("connect");
    let conn_id = conn.get_connection_id();
    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().expect("lock handles");
    let conn_arc = handles_guard
        .get_connection(conn_id)
        .expect("get connection");
    let odbc_conn = conn_arc.lock().expect("lock odbc connection");

    let table = "odbc_bcp_native_i32_zero_rows_test";
    let _ = execute_command(
        &odbc_conn,
        &format!(
            "IF OBJECT_ID(N'{}', N'U') IS NOT NULL DROP TABLE {}",
            table, table
        ),
    );
    execute_command(
        &odbc_conn,
        &format!("CREATE TABLE {} (id INT NOT NULL PRIMARY KEY)", table),
    )
    .expect("create table");

    let payload = BulkInsertPayload {
        table: table.to_string(),
        columns: vec![BulkColumnSpec {
            name: "id".to_string(),
            col_type: BulkColumnType::I32,
            nullable: false,
            max_len: 0,
        }],
        row_count: 0,
        column_data: vec![BulkColumnData::I32 {
            values: Vec::new(),
            null_bitmap: None,
        }],
    };

    let inserted =
        sqlserver_bcp::execute_native_bcp(conn_str.as_str(), &payload, 1000).expect("native BCP");
    assert_eq!(inserted, 0);

    execute_command(&odbc_conn, &format!("DROP TABLE {}", table)).expect("drop table");
    drop(handles_guard);
    conn.disconnect().expect("disconnect");
}

#[cfg(all(feature = "sqlserver-bcp", windows))]
#[test]
#[serial]
#[ignore = "Isolation test: connect-only path to isolate crash stage"]
fn test_e2e_native_bcp_connect_only() {
    if !should_run_e2e_tests() {
        eprintln!("Skipping native BCP isolation test: database not available");
        return;
    }

    let (conn_str, db_type) = get_connection_and_db_type().expect("connection string");
    if db_type != DatabaseType::SqlServer {
        eprintln!("Skipping native BCP isolation test: requires SQL Server");
        return;
    }

    use odbc_api::sys::{
        ConnectionAttribute, DriverConnectOption, Handle, HandleType, SQLAllocHandle,
        SQLDisconnect, SQLDriverConnectW, SQLFreeHandle, SQLSetConnectAttr, SQLSetEnvAttr,
        SmallInt, WChar, IS_INTEGER, NTSL,
    };
    use std::ffi::c_void;

    const SQL_COPT_SS_BCP: i32 = 1219;
    const SQL_BCP_ON: i32 = 1;

    fn to_wide_nul(input: &str) -> Vec<WChar> {
        input.encode_utf16().chain(std::iter::once(0)).collect()
    }

    let mut env: Handle = Handle::null();
    let mut dbc: Handle = Handle::null();

    let env_alloc = unsafe { SQLAllocHandle(HandleType::Env, Handle::null(), &mut env) };
    assert!(
        env_alloc == odbc_api::sys::SqlReturn::SUCCESS
            || env_alloc == odbc_api::sys::SqlReturn::SUCCESS_WITH_INFO
    );
    let env_handle = env.as_henv();

    let version_set = unsafe {
        SQLSetEnvAttr(
            env_handle,
            odbc_api::sys::EnvironmentAttribute::OdbcVersion,
            odbc_api::sys::AttrOdbcVersion::Odbc3.into(),
            0,
        )
    };
    assert!(
        version_set == odbc_api::sys::SqlReturn::SUCCESS
            || version_set == odbc_api::sys::SqlReturn::SUCCESS_WITH_INFO
    );

    let dbc_alloc = unsafe { SQLAllocHandle(HandleType::Dbc, env, &mut dbc) };
    assert!(
        dbc_alloc == odbc_api::sys::SqlReturn::SUCCESS
            || dbc_alloc == odbc_api::sys::SqlReturn::SUCCESS_WITH_INFO
    );
    let dbc_handle = dbc.as_hdbc();

    let bcp_attr_set = unsafe {
        SQLSetConnectAttr(
            dbc_handle,
            ConnectionAttribute(SQL_COPT_SS_BCP),
            SQL_BCP_ON as usize as *mut c_void,
            IS_INTEGER,
        )
    };
    assert!(
        bcp_attr_set == odbc_api::sys::SqlReturn::SUCCESS
            || bcp_attr_set == odbc_api::sys::SqlReturn::SUCCESS_WITH_INFO
    );

    let conn_wide = to_wide_nul(conn_str.as_str());
    let connected = unsafe {
        SQLDriverConnectW(
            dbc_handle,
            std::ptr::null_mut(),
            conn_wide.as_ptr(),
            NTSL as SmallInt,
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
            DriverConnectOption::NoPrompt,
        )
    };
    assert!(
        connected == odbc_api::sys::SqlReturn::SUCCESS
            || connected == odbc_api::sys::SqlReturn::SUCCESS_WITH_INFO
    );

    eprintln!("[OK] BCP-enabled connection established successfully");

    unsafe {
        let _ = SQLDisconnect(dbc_handle);
        let _ = SQLFreeHandle(HandleType::Dbc, dbc);
        let _ = SQLFreeHandle(HandleType::Env, env);
    }

    eprintln!("[OK] Cleanup completed without crash");
}

#[cfg(all(feature = "sqlserver-bcp", windows))]
#[test]
#[serial]
#[ignore = "Isolation test: connect + bcp_init (no bind) to isolate crash stage"]
fn test_e2e_native_bcp_init_only() {
    if !should_run_e2e_tests() {
        eprintln!("Skipping native BCP isolation test: database not available");
        return;
    }

    let (conn_str, db_type) = get_connection_and_db_type().expect("connection string");
    if db_type != DatabaseType::SqlServer {
        eprintln!("Skipping native BCP isolation test: requires SQL Server");
        return;
    }

    let env = OdbcEnvironment::new();
    env.init().expect("init environment");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("connect");
    let conn_id = conn.get_connection_id();
    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().expect("lock handles");
    let conn_arc = handles_guard
        .get_connection(conn_id)
        .expect("get connection");
    let odbc_conn = conn_arc.lock().expect("lock odbc connection");

    let table = "odbc_bcp_init_only_test";
    let _ = execute_command(
        &odbc_conn,
        &format!(
            "IF OBJECT_ID(N'{}', N'U') IS NOT NULL DROP TABLE {}",
            table, table
        ),
    );
    execute_command(
        &odbc_conn,
        &format!("CREATE TABLE {} (id INT NOT NULL PRIMARY KEY)", table),
    )
    .expect("create table");

    eprintln!("[INFO] Table created, keeping odbc-api connection open");

    use libloading::Library;
    use odbc_api::sys::{
        ConnectionAttribute, DriverConnectOption, HDbc, Handle, HandleType, SQLAllocHandle,
        SQLDisconnect, SQLDriverConnectW, SQLFreeHandle, SQLSetConnectAttr, SQLSetEnvAttr,
        SmallInt, WChar, IS_INTEGER, NTSL,
    };
    use std::ffi::c_void;

    const SQL_COPT_SS_BCP: i32 = 1219;
    const SQL_BCP_ON: i32 = 1;
    const DB_IN: i32 = 1;

    type BcpInitWFn = unsafe extern "system" fn(
        hdbc: HDbc,
        sz_table: *const WChar,
        sz_data_file: *const WChar,
        sz_error_file: *const WChar,
        e_direction: i32,
    ) -> i32;

    fn to_wide_nul(input: &str) -> Vec<WChar> {
        input.encode_utf16().chain(std::iter::once(0)).collect()
    }

    let (lib, lib_name) = unsafe { Library::new("sqlncli11.dll") }
        .map(|l| (l, "sqlncli11.dll"))
        .or_else(|_| unsafe { Library::new("msodbcsql17.dll") }.map(|l| (l, "msodbcsql17.dll")))
        .or_else(|_| unsafe { Library::new("msodbcsql18.dll") }.map(|l| (l, "msodbcsql18.dll")))
        .expect("load BCP library");

    eprintln!("[INFO] Loaded BCP library: {}", lib_name);

    let bcp_init_w: BcpInitWFn = unsafe { *lib.get(b"bcp_initW\0").expect("bcp_initW symbol") };

    let mut env_bcp: Handle = Handle::null();
    let mut dbc_bcp: Handle = Handle::null();

    let env_alloc = unsafe { SQLAllocHandle(HandleType::Env, Handle::null(), &mut env_bcp) };
    assert!(
        env_alloc == odbc_api::sys::SqlReturn::SUCCESS
            || env_alloc == odbc_api::sys::SqlReturn::SUCCESS_WITH_INFO
    );

    let version_set = unsafe {
        SQLSetEnvAttr(
            env_bcp.as_henv(),
            odbc_api::sys::EnvironmentAttribute::OdbcVersion,
            odbc_api::sys::AttrOdbcVersion::Odbc3.into(),
            0,
        )
    };
    assert!(
        version_set == odbc_api::sys::SqlReturn::SUCCESS
            || version_set == odbc_api::sys::SqlReturn::SUCCESS_WITH_INFO
    );

    let dbc_alloc = unsafe { SQLAllocHandle(HandleType::Dbc, env_bcp, &mut dbc_bcp) };
    assert!(
        dbc_alloc == odbc_api::sys::SqlReturn::SUCCESS
            || dbc_alloc == odbc_api::sys::SqlReturn::SUCCESS_WITH_INFO
    );
    let dbc_handle = dbc_bcp.as_hdbc();

    let bcp_attr_set = unsafe {
        SQLSetConnectAttr(
            dbc_handle,
            ConnectionAttribute(SQL_COPT_SS_BCP),
            SQL_BCP_ON as usize as *mut c_void,
            IS_INTEGER,
        )
    };
    assert!(
        bcp_attr_set == odbc_api::sys::SqlReturn::SUCCESS
            || bcp_attr_set == odbc_api::sys::SqlReturn::SUCCESS_WITH_INFO
    );

    let conn_wide = to_wide_nul(conn_str.as_str());
    let connected = unsafe {
        SQLDriverConnectW(
            dbc_handle,
            std::ptr::null_mut(),
            conn_wide.as_ptr(),
            NTSL as SmallInt,
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
            DriverConnectOption::NoPrompt,
        )
    };
    assert!(
        connected == odbc_api::sys::SqlReturn::SUCCESS
            || connected == odbc_api::sys::SqlReturn::SUCCESS_WITH_INFO
    );

    eprintln!("[OK] BCP-enabled connection established");

    let database = conn_str
        .split(';')
        .find_map(|part| {
            let trimmed = part.trim();
            if trimmed.to_lowercase().starts_with("database=") {
                Some(trimmed[9..].trim().to_string())
            } else {
                None
            }
        })
        .unwrap_or_else(|| "master".to_string());

    eprintln!("[INFO] Database context: {}", database);

    use odbc_api::sys::{
        SQLAllocHandle as SQLAllocHandleStmt, SQLExecDirectW, SQLFreeHandle as SQLFreeHandleStmt,
    };
    let mut stmt: Handle = Handle::null();
    let stmt_alloc = unsafe { SQLAllocHandleStmt(HandleType::Stmt, dbc_bcp, &mut stmt) };
    if stmt_alloc == odbc_api::sys::SqlReturn::SUCCESS
        || stmt_alloc == odbc_api::sys::SqlReturn::SUCCESS_WITH_INFO
    {
        let use_db_query = format!("USE {}", database);
        let use_db_wide = to_wide_nul(&use_db_query);
        let use_db_rc =
            unsafe { SQLExecDirectW(stmt.as_hstmt(), use_db_wide.as_ptr(), NTSL as i32) };
        eprintln!("[INFO] USE {} returned: {:?}", database, use_db_rc);

        let create_in_bcp_conn = format!("CREATE TABLE {} (id INT NOT NULL PRIMARY KEY)", table);
        let create_wide = to_wide_nul(&create_in_bcp_conn);
        let create_rc =
            unsafe { SQLExecDirectW(stmt.as_hstmt(), create_wide.as_ptr(), NTSL as i32) };
        eprintln!(
            "[INFO] CREATE TABLE in BCP connection returned: {:?}",
            create_rc
        );

        unsafe {
            let _ = SQLFreeHandleStmt(HandleType::Stmt, stmt);
        }
    } else {
        eprintln!("[WARN] Could not allocate statement for table verification");
    }

    let table_wide = to_wide_nul(table);
    let init_rc = unsafe {
        bcp_init_w(
            dbc_handle,
            table_wide.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            DB_IN,
        )
    };
    eprintln!("[INFO] bcp_initW returned: {}", init_rc);

    if init_rc == 0 {
        eprintln!("[ERROR] bcp_initW failed (rc=0). Skipping cleanup to avoid heap corruption.");
        panic!("bcp_initW returned 0 (failure)");
    }

    eprintln!("[OK] bcp_initW completed successfully");

    eprintln!("[INFO] Starting cleanup: SQLDisconnect");
    let disconnect_rc = unsafe { SQLDisconnect(dbc_handle) };
    eprintln!("[INFO] SQLDisconnect returned: {:?}", disconnect_rc);

    eprintln!("[INFO] Starting cleanup: SQLFreeHandle(Dbc)");
    let free_dbc_rc = unsafe { SQLFreeHandle(HandleType::Dbc, dbc_bcp) };
    eprintln!("[INFO] SQLFreeHandle(Dbc) returned: {:?}", free_dbc_rc);

    eprintln!("[INFO] Starting cleanup: SQLFreeHandle(Env)");
    let free_env_rc = unsafe { SQLFreeHandle(HandleType::Env, env_bcp) };
    eprintln!("[INFO] SQLFreeHandle(Env) returned: {:?}", free_env_rc);

    eprintln!("[OK] Cleanup completed without crash (connect + init only)");

    execute_command(&odbc_conn, &format!("DROP TABLE {}", table)).expect("drop table");
    drop(odbc_conn);
    drop(handles_guard);
    conn.disconnect().expect("disconnect");
}

#[cfg(all(feature = "sqlserver-bcp", windows))]
#[test]
#[serial]
#[ignore = "Benchmark: compare native BCP vs ArrayBinding; run with --ignored"]
fn test_benchmark_native_vs_fallback() {
    if !should_run_e2e_tests() {
        eprintln!("Skipping benchmark: database not available");
        return;
    }

    let (conn_str, db_type) = get_connection_and_db_type().expect("connection string");
    if db_type != DatabaseType::SqlServer {
        eprintln!("Skipping benchmark: requires SQL Server");
        return;
    }

    let env = OdbcEnvironment::new();
    env.init().expect("init environment");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("connect");
    let conn_id = conn.get_connection_id();
    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().expect("lock handles");
    let conn_arc = handles_guard
        .get_connection(conn_id)
        .expect("get connection");
    let odbc_conn = conn_arc.lock().expect("lock odbc connection");

    let n: usize = 50_000;
    let table_native = "odbc_bcp_benchmark_native";
    let table_fallback = "odbc_bcp_benchmark_fallback";

    for table in [table_native, table_fallback] {
        let _ = execute_command(
            &odbc_conn,
            &format!(
                "IF OBJECT_ID(N'{}', N'U') IS NOT NULL DROP TABLE {}",
                table, table
            ),
        );
        execute_command(
            &odbc_conn,
            &format!(
                "CREATE TABLE {} (id INT NOT NULL PRIMARY KEY, score BIGINT NOT NULL)",
                table
            ),
        )
        .expect("create table");
    }

    let ids: Vec<i32> = (1..=n as i32).collect();
    let scores: Vec<i64> = (1..=n).map(|i| (i as i64) * 10).collect();

    let payload_native = BulkInsertPayload {
        table: table_native.to_string(),
        columns: vec![
            BulkColumnSpec {
                name: "id".to_string(),
                col_type: BulkColumnType::I32,
                nullable: false,
                max_len: 0,
            },
            BulkColumnSpec {
                name: "score".to_string(),
                col_type: BulkColumnType::I64,
                nullable: false,
                max_len: 0,
            },
        ],
        row_count: n as u32,
        column_data: vec![
            BulkColumnData::I32 {
                values: ids.clone(),
                null_bitmap: None,
            },
            BulkColumnData::I64 {
                values: scores.clone(),
                null_bitmap: None,
            },
        ],
    };

    let payload_fallback = BulkInsertPayload {
        table: table_fallback.to_string(),
        columns: payload_native.columns.clone(),
        row_count: n as u32,
        column_data: vec![
            BulkColumnData::I32 {
                values: ids,
                null_bitmap: None,
            },
            BulkColumnData::I64 {
                values: scores,
                null_bitmap: None,
            },
        ],
    };

    use std::time::Instant;

    std::env::set_var("ODBC_ENABLE_UNSTABLE_NATIVE_BCP", "1");
    let start_native = Instant::now();
    let inserted_native =
        sqlserver_bcp::execute_native_bcp(conn_str.as_str(), &payload_native, 1000)
            .expect("native BCP should succeed");
    let elapsed_native = start_native.elapsed();
    std::env::remove_var("ODBC_ENABLE_UNSTABLE_NATIVE_BCP");

    assert_eq!(inserted_native, n);

    use odbc_engine::engine::core::bulk_copy::BulkCopyExecutor;
    let executor = BulkCopyExecutor::new(1000);
    let start_fallback = Instant::now();
    let inserted_fallback = executor
        .bulk_copy_from_payload(&odbc_conn, &payload_fallback, None)
        .expect("fallback should succeed");
    let elapsed_fallback = start_fallback.elapsed();

    assert_eq!(inserted_fallback, n);

    let speedup = elapsed_fallback.as_secs_f64() / elapsed_native.as_secs_f64();
    let native_rps = n as f64 / elapsed_native.as_secs_f64();
    let fallback_rps = n as f64 / elapsed_fallback.as_secs_f64();

    eprintln!("\n=== Benchmark Results ({} rows) ===", n);
    eprintln!(
        "Native BCP:   {:.2?} ({:.0} rows/s)",
        elapsed_native, native_rps
    );
    eprintln!(
        "ArrayBinding: {:.2?} ({:.0} rows/s)",
        elapsed_fallback, fallback_rps
    );
    eprintln!("Speedup:      {:.2}x", speedup);

    for table in [table_native, table_fallback] {
        execute_command(&odbc_conn, &format!("DROP TABLE {}", table)).expect("drop table");
    }

    drop(handles_guard);
    conn.disconnect().expect("disconnect");
}

#[cfg(not(all(feature = "sqlserver-bcp", windows)))]
#[test]
fn test_e2e_native_bcp_numeric_nullable_skipped() {
    eprintln!("Native numeric BCP E2E requires Windows + sqlserver-bcp feature");
}
