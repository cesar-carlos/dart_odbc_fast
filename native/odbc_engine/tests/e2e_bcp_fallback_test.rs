/// E2E tests for BCP path with fallback to ArrayBinding.
///
/// When `sqlserver-bcp` feature is enabled, `BulkCopyExecutor::bulk_copy_from_payload`
/// tries native SQL Server BCP first (currently blocked by SQL_COPT_SS_BCP pre-connect
/// requirement), then falls back to ArrayBinding. These tests verify the fallback path.
///
/// Run: `cargo test --features sqlserver-bcp e2e_bcp -- --ignored` (for 100k)
/// Or:  `cargo test --features sqlserver-bcp e2e_bcp` (for default rows)
///
/// Env: ENABLE_E2E_TESTS=1, ODBC_TEST_DSN or ODBC_TEST_DB, BCP_E2E_ROWS (optional)
use odbc_api::Connection;
use odbc_engine::{
    engine::core::BulkCopyExecutor,
    execute_query_with_connection,
    protocol::{BulkColumnData, BulkColumnSpec, BulkColumnType, BulkInsertPayload},
    BinaryProtocolDecoder, OdbcConnection, OdbcEnvironment,
};
use serial_test::serial;
use std::time::Instant;

mod helpers;
use helpers::e2e::{get_connection_and_db_type, should_run_e2e_tests};

fn decode_integer(data: &[u8]) -> i32 {
    if data.len() >= 4 {
        i32::from_le_bytes([data[0], data[1], data[2], data[3]])
    } else {
        String::from_utf8_lossy(data)
            .trim()
            .parse::<i32>()
            .unwrap_or(0)
    }
}

fn execute_command(conn: &Connection<'static>, sql: &str) -> Result<(), odbc_engine::OdbcError> {
    let mut stmt = conn.prepare(sql).map_err(odbc_engine::OdbcError::from)?;
    stmt.execute(()).map_err(odbc_engine::OdbcError::from)?;
    Ok(())
}

fn get_row_count(conn: &Connection<'static>, table: &str) -> usize {
    let sql = format!("SELECT COUNT(*) AS c FROM {}", table);
    let buf = execute_query_with_connection(conn, &sql).expect("SELECT COUNT failed");
    let dec = BinaryProtocolDecoder::parse(&buf).expect("Decode count failed");
    decode_integer(dec.rows[0][0].as_ref().expect("count cell null")) as usize
}

fn env_rows() -> usize {
    std::env::var("BCP_E2E_ROWS")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(10_000)
}

#[cfg(feature = "sqlserver-bcp")]
fn run_bcp_fallback_e2e(n: usize) {
    if !should_run_e2e_tests() {
        eprintln!("Skipping BCP fallback E2E: database not available");
        return;
    }

    let (conn_str, _db_type) =
        get_connection_and_db_type().expect("Failed to get connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect");
    let conn_id = conn.get_connection_id();
    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().expect("Lock handles");
    let conn_arc = handles_guard
        .get_connection(conn_id)
        .expect("Failed to get ODBC connection");
    let odbc_conn = conn_arc.lock().expect("Lock connection");

    let table = "odbc_bcp_fallback_test";
    let _ = execute_command(&odbc_conn, &format!("DROP TABLE IF EXISTS {}", table));
    let _ = execute_command(&odbc_conn, &format!("DROP TABLE {}", table));
    std::thread::sleep(std::time::Duration::from_millis(100));

    execute_command(
        &odbc_conn,
        &format!(
            "CREATE TABLE {} (id INT PRIMARY KEY, name VARCHAR(100))",
            table
        ),
    )
    .expect("Create table");

    let ids: Vec<i32> = (1..=n as i32).collect();
    let names: Vec<Vec<u8>> = (1..=n)
        .map(|i| format!("bcp_user_{}", i).into_bytes())
        .collect();
    let max_len = 100;

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
                name: "name".to_string(),
                col_type: BulkColumnType::Text,
                nullable: false,
                max_len,
            },
        ],
        row_count: n as u32,
        column_data: vec![
            BulkColumnData::I32 {
                values: ids,
                null_bitmap: None,
            },
            BulkColumnData::Text {
                rows: names,
                max_len,
                null_bitmap: None,
            },
        ],
    };

    let bcp = BulkCopyExecutor::new(1_000);
    let start = Instant::now();
    let inserted = bcp
        .bulk_copy_from_payload(&odbc_conn, &payload, Some(conn_str.as_str()))
        .expect("bulk_copy_from_payload (fallback path)");
    let elapsed = start.elapsed();

    assert_eq!(inserted, n, "Expected {} rows inserted", n);

    let count = get_row_count(&odbc_conn, table);
    assert_eq!(count, n, "Row count mismatch after insert");

    let rows_per_sec = if elapsed.as_secs_f64() > 0.0 {
        n as f64 / elapsed.as_secs_f64()
    } else {
        0.0
    };
    eprintln!(
        "BCP fallback: {} rows in {:.2?} ({:.0} rows/s)",
        n, elapsed, rows_per_sec
    );

    execute_command(&odbc_conn, &format!("DROP TABLE {}", table)).expect("Drop table");
    drop(handles_guard);
    conn.disconnect().expect("Disconnect");
}

#[cfg(feature = "sqlserver-bcp")]
#[test]
#[serial]
fn test_e2e_bcp_fallback_inserts_rows() {
    run_bcp_fallback_e2e(env_rows());
}

#[cfg(feature = "sqlserver-bcp")]
#[test]
#[ignore = "Long-running 100k row test; run with --ignored"]
#[serial]
fn test_e2e_bcp_fallback_100k_rows() {
    run_bcp_fallback_e2e(100_000);
}

#[cfg(not(feature = "sqlserver-bcp"))]
#[test]
fn test_e2e_bcp_skipped_without_feature() {
    eprintln!("BCP E2E tests require sqlserver-bcp feature");
}
