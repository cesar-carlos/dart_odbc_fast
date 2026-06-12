//! E2E coverage for FFI paths changed by the Rust/FFI refactor.
//!
//! These tests are opt-in through the normal E2E gate. They focus on behavior
//! that unit tests cannot prove against a live driver: long calls must not hold
//! `GLOBAL_STATE`, pool close/resize must respect in-flight pooled calls, bulk
//! v2 binary cells must survive an actual insert/readback, and spill-backed
//! streaming must fetch a real large result.

use odbc_engine::ffi::{
    odbc_bulk_insert_array, odbc_connect, odbc_disconnect, odbc_exec_query, odbc_get_error,
    odbc_get_metrics, odbc_init, odbc_pool_close, odbc_pool_create, odbc_pool_get_connection,
    odbc_pool_release_connection, odbc_pool_set_size, odbc_stream_close, odbc_stream_fetch,
    odbc_stream_start,
};
use odbc_engine::protocol::{
    serialize_bulk_insert_payload_v2, BulkColumnData, BulkColumnSpec, BulkColumnType,
    BulkInsertPayload,
};
use odbc_engine::BinaryProtocolDecoder;
use serial_test::serial;
use std::ffi::CString;
use std::os::raw::{c_char, c_uint};
use std::time::{Duration, Instant};

mod helpers;
use helpers::e2e::{
    get_connection_and_db_type, should_run_e2e_tests, sql_drop_table_if_exists, unique_e2e_table,
    DatabaseType,
};

fn sql_server_dsn() -> Option<String> {
    if !should_run_e2e_tests() {
        eprintln!("Skipping FFI refactor E2E: ENABLE_E2E_TESTS + DSN not configured");
        return None;
    }

    let (dsn, db_type) = get_connection_and_db_type()?;
    if db_type != DatabaseType::SqlServer {
        eprintln!("Skipping FFI refactor E2E: requires SQL Server, got {db_type:?}");
        return None;
    }

    Some(dsn)
}

fn connect(dsn: &str) -> u32 {
    odbc_init();
    let conn = CString::new(dsn).expect("dsn must not contain NUL");
    let conn_id = odbc_connect(conn.as_ptr());
    assert!(conn_id > 0, "connect failed: {}", last_error());
    conn_id
}

fn disconnect(conn_id: u32) {
    assert_eq!(odbc_disconnect(conn_id), 0, "disconnect failed");
}

fn exec(conn_id: u32, sql: &str) -> Vec<u8> {
    let sql = CString::new(sql).expect("sql must not contain NUL");
    let mut buffer = vec![0u8; 4 * 1024 * 1024];
    let mut written: c_uint = 0;
    let code = odbc_exec_query(
        conn_id,
        sql.as_ptr(),
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(code, 0, "exec failed: {}", last_error());
    buffer.truncate(written as usize);
    buffer
}

fn last_error() -> String {
    let mut buffer = vec![0u8; 4096];
    let len = odbc_get_error(buffer.as_mut_ptr() as *mut c_char, buffer.len() as c_uint);
    if len <= 0 {
        return String::new();
    }
    String::from_utf8_lossy(&buffer[..len as usize]).to_string()
}

fn decode_i64_cell(bytes: &[u8]) -> i64 {
    match bytes.len() {
        0..=3 => String::from_utf8_lossy(bytes).trim().parse().unwrap(),
        4..=7 => i32::from_le_bytes(bytes[..4].try_into().unwrap()) as i64,
        _ => i64::from_le_bytes(bytes[..8].try_into().unwrap()),
    }
}

struct EnvGuard {
    key: &'static str,
    previous: Option<std::ffi::OsString>,
}

impl EnvGuard {
    fn set(key: &'static str, value: &str) -> Self {
        let previous = std::env::var_os(key);
        std::env::set_var(key, value);
        Self { key, previous }
    }
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        match &self.previous {
            Some(value) => std::env::set_var(self.key, value),
            None => std::env::remove_var(self.key),
        }
    }
}

#[test]
#[serial]
fn bulk_v2_binary_nul_round_trips_through_ffi() {
    let Some(dsn) = sql_server_dsn() else {
        return;
    };

    let table = unique_e2e_table("odbc_bulk_v2_e2e");
    let conn_id = connect(&dsn);
    let drop_sql = sql_drop_table_if_exists(&table, DatabaseType::SqlServer);

    exec(conn_id, &drop_sql);
    exec(
        conn_id,
        &format!(
            "CREATE TABLE {table} (id INT NOT NULL PRIMARY KEY, payload VARBINARY(8) NOT NULL)"
        ),
    );

    let payload = BulkInsertPayload {
        table: table.clone(),
        columns: vec![
            BulkColumnSpec {
                name: "id".to_string(),
                col_type: BulkColumnType::I32,
                nullable: false,
                max_len: 0,
            },
            BulkColumnSpec {
                name: "payload".to_string(),
                col_type: BulkColumnType::Binary,
                nullable: false,
                max_len: 8,
            },
        ],
        row_count: 2,
        column_data: vec![
            BulkColumnData::I32 {
                values: vec![1, 2],
                null_bitmap: None,
            },
            BulkColumnData::Binary {
                rows: odbc_engine::protocol::bulk_rows_from_vecs(vec![vec![1, 0, 2], vec![3, 4]]),
                null_bitmap: None,
                max_len: 8,
            },
        ],
    };
    let encoded = serialize_bulk_insert_payload_v2(&payload).expect("encode bulk v2");
    let table_c = CString::new(table.as_str()).unwrap();
    let column_names = [
        CString::new("id").unwrap(),
        CString::new("payload").unwrap(),
    ];
    let column_ptrs = column_names.iter().map(|c| c.as_ptr()).collect::<Vec<_>>();
    let mut rows_inserted: c_uint = 0;
    let code = odbc_bulk_insert_array(
        conn_id,
        table_c.as_ptr(),
        column_ptrs.as_ptr(),
        column_ptrs.len() as c_uint,
        encoded.as_ptr(),
        encoded.len() as c_uint,
        payload.row_count,
        &mut rows_inserted,
    );
    assert_eq!(code, 0, "bulk insert failed: {}", last_error());
    assert_eq!(rows_inserted, 2);

    let result = exec(
        conn_id,
        &format!("SELECT id, payload, DATALENGTH(payload) AS payload_len FROM {table} ORDER BY id"),
    );
    let decoded = BinaryProtocolDecoder::parse(&result).expect("decode select");
    assert_eq!(decoded.row_count, 2);
    assert_eq!(decoded.rows[0][1].as_deref(), Some(&[1, 0, 2][..]));
    assert_eq!(decode_i64_cell(decoded.rows[0][2].as_ref().unwrap()), 3);
    assert_eq!(decoded.rows[1][1].as_deref(), Some(&[3, 4][..]));
    assert_eq!(decode_i64_cell(decoded.rows[1][2].as_ref().unwrap()), 2);

    exec(conn_id, &drop_sql);
    disconnect(conn_id);
}

#[test]
#[serial]
fn long_ffi_query_does_not_block_global_metrics_lookup() {
    let Some(dsn) = sql_server_dsn() else {
        return;
    };

    let conn_id = connect(&dsn);
    let long_query = CString::new("WAITFOR DELAY '00:00:02'; SELECT 1 AS n").unwrap();

    let handle = std::thread::spawn(move || {
        let mut buffer = vec![0u8; 8192];
        let mut written: c_uint = 0;
        odbc_exec_query(
            conn_id,
            long_query.as_ptr(),
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            &mut written,
        )
    });

    std::thread::sleep(Duration::from_millis(250));
    let start = Instant::now();
    let mut metrics = [0u8; 40];
    let mut written: c_uint = 0;
    let metrics_code =
        odbc_get_metrics(metrics.as_mut_ptr(), metrics.len() as c_uint, &mut written);
    let elapsed = start.elapsed();

    assert_eq!(metrics_code, 0, "metrics lookup failed: {}", last_error());
    assert_eq!(written, 40);
    assert!(
        elapsed < Duration::from_millis(750),
        "metrics lookup was blocked by long ODBC call for {elapsed:?}"
    );

    assert_eq!(handle.join().expect("long query thread panicked"), 0);
    disconnect(conn_id);
}

#[test]
#[serial]
fn pool_resize_and_close_fail_while_pooled_query_is_in_flight() {
    let Some(dsn) = sql_server_dsn() else {
        return;
    };

    odbc_init();
    let conn = CString::new(dsn).unwrap();
    let pool_id = odbc_pool_create(conn.as_ptr(), 2);
    assert!(pool_id > 0, "pool create failed: {}", last_error());

    let pooled_id = odbc_pool_get_connection(pool_id);
    assert!(pooled_id > 0, "pool checkout failed: {}", last_error());

    let long_query = CString::new("WAITFOR DELAY '00:00:02'; SELECT 1 AS n").unwrap();
    let handle = std::thread::spawn(move || {
        let mut buffer = vec![0u8; 8192];
        let mut written: c_uint = 0;
        odbc_exec_query(
            pooled_id,
            long_query.as_ptr(),
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            &mut written,
        )
    });

    std::thread::sleep(Duration::from_millis(250));
    assert_eq!(
        odbc_pool_set_size(pool_id, 3),
        -1,
        "resize must fail while a pooled connection is busy"
    );
    assert_ne!(
        odbc_pool_close(pool_id),
        0,
        "close must fail while a pooled connection is busy"
    );

    assert_eq!(handle.join().expect("pooled query thread panicked"), 0);
    assert_eq!(odbc_pool_release_connection(pooled_id), 0);
    assert_eq!(odbc_pool_set_size(pool_id, 3), 0);
    assert_eq!(odbc_pool_close(pool_id), 0);
}

#[test]
#[serial]
fn stream_start_spill_path_fetches_large_result() {
    let Some(dsn) = sql_server_dsn() else {
        return;
    };

    let _guard = EnvGuard::set("ODBC_STREAM_SPILL_THRESHOLD_MB", "1");
    let conn_id = connect(&dsn);
    let sql =
        CString::new("SELECT REPLICATE(CAST('x' AS VARCHAR(MAX)), 1100000) AS large_text").unwrap();
    let stream_id = odbc_stream_start(conn_id, sql.as_ptr(), 64 * 1024);
    assert!(stream_id > 0, "stream start failed: {}", last_error());

    let mut full = Vec::new();
    let mut buffer = vec![0u8; 128 * 1024];
    let mut written: c_uint = 0;
    let mut has_more: u8 = 1;
    while has_more != 0 {
        let code = odbc_stream_fetch(
            stream_id,
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            &mut written,
            &mut has_more,
        );
        assert_eq!(code, 0, "stream fetch failed: {}", last_error());
        full.extend_from_slice(&buffer[..written as usize]);
    }

    assert_eq!(odbc_stream_close(stream_id), 0);
    disconnect(conn_id);

    let decoded = BinaryProtocolDecoder::parse(&full).expect("decode streamed payload");
    assert_eq!(decoded.row_count, 1);
    let cell = decoded.rows[0][0]
        .as_ref()
        .expect("large_text should not be null");
    assert!(
        cell.len() >= 1_100_000,
        "expected large streamed cell, got {} bytes",
        cell.len()
    );
}
