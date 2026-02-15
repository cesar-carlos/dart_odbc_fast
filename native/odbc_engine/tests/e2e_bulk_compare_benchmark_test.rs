/// Comparative benchmark for bulk insert strategies (array vs parallel).
///
/// Run manually:
/// `cargo test --test e2e_bulk_compare_benchmark_test -- --ignored --nocapture`
///
/// Optional env vars:
/// - `BULK_BENCH_SMALL_ROWS` (default: 5_000)
/// - `BULK_BENCH_MEDIUM_ROWS` (default: 20_000)
use odbc_engine::engine::core::{ArrayBinding, ParallelBulkInsert};
use odbc_engine::pool::ConnectionPool;
use odbc_engine::{
    execute_query_with_connection, BinaryProtocolDecoder, OdbcConnection, OdbcEnvironment,
};
use serial_test::serial;
use std::sync::Arc;
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
            .unwrap_or_else(|_| panic!("Could not decode integer from: {:?}", data))
    }
}

fn execute_command(
    conn: &odbc_api::Connection<'static>,
    sql: &str,
) -> Result<(), odbc_engine::OdbcError> {
    let mut stmt = conn.prepare(sql).map_err(odbc_engine::OdbcError::from)?;
    stmt.execute(()).map_err(odbc_engine::OdbcError::from)?;
    Ok(())
}

fn get_row_count(conn: &odbc_api::Connection<'static>, table: &str) -> usize {
    let sql = format!("SELECT COUNT(*) AS c FROM {}", table);
    let buf = execute_query_with_connection(conn, &sql).expect("SELECT COUNT failed");
    let dec = BinaryProtocolDecoder::parse(&buf).expect("Decode count failed");
    decode_integer(dec.rows[0][0].as_ref().expect("count cell null")) as usize
}

fn benchmark_array_binding(
    conn: &odbc_api::Connection<'static>,
    table: &str,
    rows: usize,
    batch_size: usize,
) -> f64 {
    let ids: Vec<i32> = (1..=rows as i32).collect();
    let data = vec![ids];
    execute_command(conn, &format!("DROP TABLE IF EXISTS {}", table)).ok();
    execute_command(conn, &format!("DROP TABLE {}", table)).ok();
    execute_command(conn, &format!("CREATE TABLE {} (id INT)", table)).expect("Create table");

    let ab = ArrayBinding::new(batch_size);
    let start = Instant::now();
    let inserted = ab
        .bulk_insert_i32(conn, table, &["id"], &data)
        .expect("ArrayBinding insert failed");
    let elapsed = start.elapsed();
    assert_eq!(inserted, rows, "ArrayBinding inserted rows mismatch");

    let count = get_row_count(conn, table);
    assert_eq!(count, rows, "ArrayBinding count mismatch");

    execute_command(conn, &format!("DROP TABLE {}", table)).expect("Drop table");
    rows as f64 / elapsed.as_secs_f64()
}

fn benchmark_parallel_bulk(
    pool: Arc<ConnectionPool>,
    table: &str,
    rows: usize,
    parallelism: usize,
    batch_size: usize,
) -> f64 {
    {
        let mut setup = pool.get().expect("Get setup connection");
        let conn = setup.get_connection_mut();
        execute_command(conn, &format!("DROP TABLE IF EXISTS {}", table)).ok();
        execute_command(conn, &format!("DROP TABLE {}", table)).ok();
        execute_command(conn, &format!("CREATE TABLE {} (id INT)", table)).expect("Create table");
    }

    let ids: Vec<i32> = (1..=rows as i32).collect();
    let data = vec![ids];
    let pbi = ParallelBulkInsert::new(Arc::clone(&pool), parallelism).with_batch_size(batch_size);

    let start = Instant::now();
    let inserted = pbi
        .insert_i32_parallel(table, &["id"], data)
        .expect("Parallel bulk insert failed");
    let elapsed = start.elapsed();
    assert_eq!(inserted, rows, "Parallel inserted rows mismatch");

    {
        let verify = pool.get().expect("Get verify connection");
        let count = get_row_count(verify.get_connection(), table);
        assert_eq!(count, rows, "Parallel count mismatch");
    }

    {
        let mut cleanup = pool.get().expect("Get cleanup connection");
        execute_command(
            cleanup.get_connection_mut(),
            &format!("DROP TABLE {}", table),
        )
        .expect("Drop table");
    }

    rows as f64 / elapsed.as_secs_f64()
}

fn env_rows(key: &str, default_value: usize) -> usize {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(default_value)
}

#[test]
#[ignore]
#[serial]
fn test_e2e_bulk_compare_array_vs_parallel() {
    if !should_run_e2e_tests() {
        eprintln!("Skipping benchmark: E2E database not available");
        return;
    }

    let (conn_str, _db_type) =
        get_connection_and_db_type().expect("Failed to get connection string and database type");

    let small_rows = env_rows("BULK_BENCH_SMALL_ROWS", 5_000);
    let medium_rows = env_rows("BULK_BENCH_MEDIUM_ROWS", 20_000);

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect");

    let conn_handles = conn.get_handles();
    let guard = conn_handles.lock().expect("Lock handles");
    let odbc_conn = guard
        .get_connection(conn.get_connection_id())
        .expect("Get ODBC connection");

    let pool = Arc::new(ConnectionPool::new(&conn_str, 4).expect("Create pool"));

    let scenarios = [("small", small_rows), ("medium", medium_rows)];
    println!("| scenario | rows | array rows/s | parallel rows/s | speedup |");
    println!("| --- | ---: | ---: | ---: | ---: |");

    for (label, rows) in scenarios {
        let array_table = format!("odbc_bench_array_{}", label);
        let parallel_table = format!("odbc_bench_parallel_{}", label);

        let array_rps = benchmark_array_binding(odbc_conn, &array_table, rows, 1_000);
        let parallel_rps =
            benchmark_parallel_bulk(Arc::clone(&pool), &parallel_table, rows, 4, 500);
        let speedup = if array_rps > 0.0 {
            parallel_rps / array_rps
        } else {
            0.0
        };

        println!(
            "| {} | {} | {:.2} | {:.2} | {:.2}x |",
            label, rows, array_rps, parallel_rps, speedup
        );
    }

    drop(guard);
    conn.disconnect().expect("Disconnect");
}
