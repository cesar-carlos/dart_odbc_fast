//! Comparative benchmarks against SQL Server (ODBC_TEST_DSN or SQLSERVER_TEST_*).
//!
//! Run: `cargo bench --bench comparative_bench`
//!
//! Requires ODBC_TEST_DSN or SQLSERVER_TEST_* env vars. Skips DB benchmarks when unset.
//! Needs `test-helpers` feature (default) for load_dotenv.

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use odbc_engine::engine::core::{ArrayBinding, ParallelBulkInsert};
use odbc_engine::engine::StreamingExecutor;
use odbc_engine::pool::ConnectionPool;
use odbc_engine::{
    execute_query_with_connection, BinaryProtocolDecoder, OdbcConnection, OdbcEnvironment,
};
use std::cell::RefCell;
use std::sync::Arc;
use std::time::Duration;

fn get_bench_dsn() -> Option<String> {
    odbc_engine::test_helpers::load_dotenv();

    if let Ok(dsn) = std::env::var("ODBC_TEST_DSN") {
        if !dsn.is_empty() {
            return Some(dsn);
        }
    }

    let server = std::env::var("SQLSERVER_TEST_SERVER").unwrap_or_else(|_| "LOCALHOST".to_string());
    let database =
        std::env::var("SQLSERVER_TEST_DATABASE").unwrap_or_else(|_| "Estacao".to_string());
    let username = std::env::var("SQLSERVER_TEST_USER").unwrap_or_else(|_| "sa".to_string());
    let password =
        std::env::var("SQLSERVER_TEST_PASSWORD").unwrap_or_else(|_| "123abc.".to_string());
    let port = std::env::var("SQLSERVER_TEST_PORT")
        .ok()
        .and_then(|p| p.parse::<u16>().ok());

    let server_str = port.map(|p| format!("{},{}", server, p)).unwrap_or(server);
    Some(format!(
        "Driver={{SQL Server Native Client 11.0}};Server={};Database={};UID={};PWD={};",
        server_str, database, username, password
    ))
}

fn execute_command(
    conn: &odbc_api::Connection<'static>,
    sql: &str,
) -> Result<(), odbc_engine::OdbcError> {
    let mut stmt = conn.prepare(sql).map_err(odbc_engine::OdbcError::from)?;
    stmt.execute(()).map_err(odbc_engine::OdbcError::from)?;
    Ok(())
}

fn decode_count(data: &[u8]) -> i32 {
    if data.len() >= 4 {
        i32::from_le_bytes([data[0], data[1], data[2], data[3]])
    } else {
        String::from_utf8_lossy(data)
            .trim()
            .parse::<i32>()
            .unwrap_or(0)
    }
}

fn get_row_count(conn: &odbc_api::Connection<'static>, table: &str) -> usize {
    let sql = format!("SELECT COUNT(*) AS c FROM {}", table);
    let buf = execute_query_with_connection(conn, &sql).expect("SELECT COUNT failed");
    let dec = BinaryProtocolDecoder::parse(&buf).expect("Decode count failed");
    decode_count(dec.rows[0][0].as_ref().expect("count cell null")) as usize
}

fn bench_single_row_insert(c: &mut Criterion) {
    let conn_str = match get_bench_dsn() {
        Some(s) => s,
        None => {
            eprintln!("Skipping single_row_insert: ODBC_TEST_DSN not set");
            return;
        }
    };

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("connect");

    let conn_handles = conn.get_handles();
    let guard = conn_handles.lock().unwrap();
    let conn_arc = guard.get_connection(conn.get_connection_id()).unwrap();

    let table = "bench_single_insert";
    execute_command(
        conn_arc.lock().unwrap().connection(),
        &format!("DROP TABLE IF EXISTS {}", table),
    )
    .ok();
    execute_command(
        conn_arc.lock().unwrap().connection(),
        &format!("CREATE TABLE {} (id INT)", table),
    )
    .expect("create table");

    let counter = RefCell::new(0i32);
    let mut group = c.benchmark_group("insert");
    group.sample_size(20);
    group.measurement_time(Duration::from_secs(5));
    group.bench_function("single_row_insert", |b| {
        let odbc_guard = conn_arc.lock().unwrap();
        let conn_ref = odbc_guard.connection();
        b.iter(|| {
            let mut n = counter.borrow_mut();
            *n += 1;
            let sql = format!("INSERT INTO {} (id) VALUES ({})", table, *n);
            execute_command(conn_ref, &sql).unwrap();
            black_box(())
        });
    });
    group.finish();

    drop(guard);
    let _ = conn.disconnect();
}

fn bench_bulk_insert_array(c: &mut Criterion) {
    let conn_str = match get_bench_dsn() {
        Some(s) => s,
        None => {
            eprintln!("Skipping bulk_insert_array: ODBC_TEST_DSN not set");
            return;
        }
    };

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("connect");

    let conn_handles = conn.get_handles();
    let guard = conn_handles.lock().unwrap();
    let conn_arc = guard.get_connection(conn.get_connection_id()).unwrap();

    let mut group = c.benchmark_group("bulk_insert");
    group.sample_size(10);
    group.measurement_time(Duration::from_secs(8));

    for rows in [1_000, 5_000, 10_000] {
        let table = format!("bench_array_{}", rows);
        group.bench_with_input(
            BenchmarkId::new("array_binding", rows),
            &(conn_arc.clone(), table.clone(), rows),
            |b, (arc, tbl, n)| {
                b.iter(|| {
                    let odbc_guard = arc.lock().unwrap();
                    let conn_ref = odbc_guard.connection();
                    execute_command(conn_ref, &format!("DROP TABLE IF EXISTS {}", tbl)).ok();
                    execute_command(conn_ref, &format!("CREATE TABLE {} (id INT)", tbl)).unwrap();
                    let ids: Vec<i32> = (1..=*n as i32).collect();
                    let data = vec![ids];
                    let ab = ArrayBinding::new(1000);
                    let inserted = ab
                        .bulk_insert_i32(conn_ref, tbl, &["id"], &data)
                        .expect("insert");
                    assert_eq!(inserted, *n);
                    black_box(inserted)
                });
            },
        );
    }
    group.finish();

    drop(guard);
    let _ = conn.disconnect();
}

fn bench_bulk_insert_parallel(c: &mut Criterion) {
    let conn_str = match get_bench_dsn() {
        Some(s) => s,
        None => {
            eprintln!("Skipping bulk_insert_parallel: ODBC_TEST_DSN not set");
            return;
        }
    };

    let pool = Arc::new(ConnectionPool::new(&conn_str, 4).expect("pool"));

    let mut group = c.benchmark_group("bulk_insert");
    group.sample_size(10);
    group.measurement_time(Duration::from_secs(8));

    for rows in [1_000, 5_000, 10_000] {
        let table = format!("bench_parallel_{}", rows);
        group.bench_with_input(
            BenchmarkId::new("parallel", rows),
            &(Arc::clone(&pool), table, rows),
            |b, (p, tbl, n)| {
                b.iter(|| {
                    {
                        let mut setup = p.get().expect("get");
                        let conn = setup.get_connection_mut();
                        execute_command(conn, &format!("DROP TABLE IF EXISTS {}", tbl)).ok();
                        execute_command(conn, &format!("CREATE TABLE {} (id INT)", tbl)).unwrap();
                    }
                    let ids: Vec<i32> = (1..=*n as i32).collect();
                    let data = vec![ids];
                    let pbi = ParallelBulkInsert::new(Arc::clone(p), 4).with_batch_size(500);
                    let inserted = pbi.insert_i32_parallel(tbl, &["id"], data).expect("insert");
                    assert_eq!(inserted, *n);
                    black_box(inserted)
                });
            },
        );
    }
    group.finish();
}

fn bench_select_cold_warm_streaming(c: &mut Criterion) {
    let conn_str = match get_bench_dsn() {
        Some(s) => s,
        None => {
            eprintln!("Skipping select benchmarks: ODBC_TEST_DSN not set");
            return;
        }
    };

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("connect");

    let conn_handles = conn.get_handles();
    let guard = conn_handles.lock().unwrap();
    let conn_arc = guard.get_connection(conn.get_connection_id()).unwrap();

    let table = "bench_select_src";
    let odbc_guard = conn_arc.lock().unwrap();
    let conn_ref = odbc_guard.connection();

    execute_command(conn_ref, &format!("DROP TABLE IF EXISTS {}", table)).ok();
    execute_command(conn_ref, &format!("CREATE TABLE {} (id INT)", table)).unwrap();
    let ids: Vec<i32> = (1..=5000).collect();
    let data = vec![ids];
    let ab = ArrayBinding::new(1000);
    ab.bulk_insert_i32(conn_ref, table, &["id"], &data)
        .expect("insert");
    let count = get_row_count(conn_ref, table);
    assert_eq!(count, 5000);

    let sql = format!("SELECT id FROM {} ORDER BY id", table);

    let mut group = c.benchmark_group("select");
    group.sample_size(15);
    group.measurement_time(Duration::from_secs(5));

    group.bench_function("cold_single", |b| {
        b.iter(|| {
            let buf = execute_query_with_connection(conn_ref, &sql).unwrap();
            black_box(BinaryProtocolDecoder::parse(&buf).unwrap())
        });
    });

    group.bench_function("warm_repeated", |b| {
        let _ = execute_query_with_connection(conn_ref, &sql).unwrap();
        b.iter(|| {
            let buf = execute_query_with_connection(conn_ref, &sql).unwrap();
            black_box(BinaryProtocolDecoder::parse(&buf).unwrap())
        });
    });

    let executor = StreamingExecutor::new(1024);
    group.bench_function("streaming", |b| {
        b.iter(|| {
            let state = executor.execute_streaming(conn_ref, &sql).unwrap();
            black_box(state)
        });
    });

    group.finish();

    execute_command(conn_ref, &format!("DROP TABLE {}", table)).ok();
    drop(guard);
    let _ = conn.disconnect();
}

criterion_group!(
    benches,
    bench_single_row_insert,
    bench_bulk_insert_array,
    bench_bulk_insert_parallel,
    bench_select_cold_warm_streaming,
);
criterion_main!(benches);
