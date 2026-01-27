use odbc_api::Connection;
/// E2E tests for bulk operations with massive data
/// Tests CREATE TABLE, INSERT (50k rows), SELECT, UPDATE, DELETE, and DROP operations
/// with performance metrics collection
use odbc_engine::{
    engine::core::{ArrayBinding, ParallelBulkInsert},
    execute_query_with_connection,
    pool::ConnectionPool,
    protocol::{BulkColumnData, BulkColumnSpec, BulkColumnType, BulkInsertPayload},
    BinaryProtocolDecoder, OdbcConnection, OdbcEnvironment,
};
use std::sync::Arc;
use std::time::{Duration, Instant};

mod helpers;
use helpers::e2e::{get_connection_and_db_type, should_run_e2e_tests, DatabaseType};
use serial_test::serial;

/// Metrics structure for bulk operations
struct BulkOperationMetrics {
    operation: String,
    rows_affected: usize,
    duration: Duration,
    rows_per_second: f64,
}

impl BulkOperationMetrics {
    fn new(operation: &str, rows: usize, duration: Duration) -> Self {
        let rows_per_second = if duration.as_secs_f64() > 0.0 {
            rows as f64 / duration.as_secs_f64()
        } else {
            0.0
        };

        Self {
            operation: operation.to_string(),
            rows_affected: rows,
            duration,
            rows_per_second,
        }
    }

    fn print_summary(&self) {
        println!("┌─────────────────────────────────────────────┐");
        println!("│ Operation: {:<32} │", self.operation);
        println!("├─────────────────────────────────────────────┤");
        println!("│ Rows affected: {:<27} │", self.rows_affected);
        println!("│ Duration: {:<31} │", format!("{:.2?}", self.duration));
        println!(
            "│ Throughput: {:<27} rows/s │",
            format!("{:.2}", self.rows_per_second)
        );
        println!("└─────────────────────────────────────────────┘");
    }
}

/// Helper to decode integer values from binary data
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

/// Helper to decode string values from binary data
fn decode_string(data: &[u8]) -> String {
    String::from_utf8_lossy(data).trim().to_string()
}

/// Execute SQL command that doesn't return results (DDL/DML)
fn execute_command(conn: &Connection<'static>, sql: &str) -> Result<(), odbc_engine::OdbcError> {
    let mut stmt = conn.prepare(sql).map_err(odbc_engine::OdbcError::from)?;
    stmt.execute(()).map_err(odbc_engine::OdbcError::from)?;
    Ok(())
}

/// Ensure table is dropped, ignoring errors if table doesn't exist.
/// Retries and waits so parallel runs or previous failed tests don't leave the table.
fn ensure_table_dropped(conn: &Connection<'static>) {
    for _ in 0..3 {
        let _ = execute_command(conn, "DROP TABLE IF EXISTS odbc_bulk_test");
        let _ = execute_command(conn, "DROP TABLE odbc_bulk_test");
        std::thread::sleep(std::time::Duration::from_millis(150));
    }
}

/// Execute SQL command and return execution time
/// For UPDATE/DELETE, rows_affected should be provided separately
fn execute_command_with_metrics(
    conn: &Connection<'static>,
    sql: &str,
) -> Result<Duration, odbc_engine::OdbcError> {
    let start = Instant::now();
    let mut stmt = conn.prepare(sql).map_err(odbc_engine::OdbcError::from)?;
    let _cursor = stmt.execute(()).map_err(odbc_engine::OdbcError::from)?;
    let duration = start.elapsed();

    Ok(duration)
}

/// Generate CREATE TABLE SQL adapted to database type
fn generate_create_table_sql(db_type: DatabaseType) -> String {
    match db_type {
        DatabaseType::SqlServer => r#"
            CREATE TABLE odbc_bulk_test (
                id INTEGER PRIMARY KEY,
                name VARCHAR(100),
                age INTEGER,
                salary DECIMAL(10,2),
                is_active BIT,
                birth_date DATE,
                created_at DATETIME2,
                description VARCHAR(500)
            )
            "#
        .trim()
        .to_string(),
        DatabaseType::Sybase => r#"
            CREATE TABLE odbc_bulk_test (
                id INTEGER PRIMARY KEY,
                name VARCHAR(100),
                age INTEGER,
                salary DECIMAL(10,2),
                is_active INTEGER,
                birth_date DATE,
                created_at TIMESTAMP,
                description VARCHAR(500)
            )
            "#
        .trim()
        .to_string(),
        _ => {
            // Generic SQL for other databases
            r#"
            CREATE TABLE odbc_bulk_test (
                id INTEGER PRIMARY KEY,
                name VARCHAR(100),
                age INTEGER,
                salary DECIMAL(10,2),
                is_active INTEGER,
                birth_date DATE,
                created_at TIMESTAMP,
                description VARCHAR(500)
            )
            "#
            .trim()
            .to_string()
        }
    }
}

/// Generate INSERT SQL for a batch of rows
fn generate_insert_batch(start_id: i32, count: usize, _db_type: DatabaseType) -> String {
    let mut sql = String::from("INSERT INTO odbc_bulk_test (id, name, age, salary, is_active, birth_date, created_at, description) VALUES ");

    for i in 0..count {
        let id = start_id + i as i32;
        let age = 20 + (id % 50);
        let salary = 1000.0 + (id as f64 * 10.5);
        let is_active = if id % 2 == 0 { 1 } else { 0 };
        let year = 1980 + (id % 40);
        let month = 1 + (id % 12);
        let day = 1 + (id % 28);

        if i > 0 {
            sql.push_str(", ");
        }

        sql.push_str(&format!(
            "({}, 'User_{}', {}, {:.2}, {}, '{}-{:02}-{:02}', CURRENT_TIMESTAMP, 'Description for user {} with age {} and salary {:.2}')",
            id, id, age, salary, is_active, year, month, day, id, age, salary
        ));
    }

    sql
}

/// Get row count from table
fn get_row_count(conn: &Connection<'static>) -> Result<usize, odbc_engine::OdbcError> {
    use odbc_engine::execute_query_with_connection;

    let buffer = execute_query_with_connection(conn, "SELECT COUNT(*) AS cnt FROM odbc_bulk_test")?;
    let decoded = BinaryProtocolDecoder::parse(&buffer)
        .map_err(|e| odbc_engine::OdbcError::InternalError(format!("Failed to decode: {}", e)))?;

    if decoded.row_count > 0 && decoded.rows[0][0].is_some() {
        let count_data = decoded.rows[0][0].as_ref().unwrap();
        let count = decode_integer(count_data) as usize;
        Ok(count)
    } else {
        Ok(0)
    }
}

#[test]
#[serial]
fn test_e2e_bulk_create_table() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: database not available");
        return;
    }

    let (conn_str, db_type) =
        get_connection_and_db_type().expect("Failed to get connection string and database type");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to database");

    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Drop table if exists (cleanup from previous test run)
    ensure_table_dropped(odbc_conn);

    // Create table with SQL adapted to database type
    let create_sql = generate_create_table_sql(db_type);
    println!("Creating table with SQL: {}", create_sql);

    let start = Instant::now();
    execute_command(odbc_conn, &create_sql).expect("Failed to create table");
    let duration = start.elapsed();

    println!("✓ Table created successfully in {:.2?}", duration);

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");
}

#[test]
#[serial]
fn test_e2e_bulk_insert_50k_rows() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: database not available");
        return;
    }

    let (conn_str, db_type) =
        get_connection_and_db_type().expect("Failed to get connection string and database type");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to database");

    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Ensure table exists (drop if exists first)
    ensure_table_dropped(odbc_conn);
    let create_sql = generate_create_table_sql(db_type);
    execute_command(odbc_conn, &create_sql).expect("Failed to create table");

    // Insert 50,000 rows in batches of 500
    const TOTAL_ROWS: usize = 50000;
    const BATCH_SIZE: usize = 500;
    let mut total_duration = Duration::ZERO;

    println!(
        "Inserting {} rows in batches of {}...",
        TOTAL_ROWS, BATCH_SIZE
    );

    for batch_start in (1..=TOTAL_ROWS).step_by(BATCH_SIZE) {
        let batch_end = std::cmp::min(batch_start + BATCH_SIZE - 1, TOTAL_ROWS);
        let batch_count = batch_end - batch_start + 1;

        let insert_sql = generate_insert_batch(batch_start as i32, batch_count, db_type);

        let start = Instant::now();
        execute_command(odbc_conn, &insert_sql)
            .unwrap_or_else(|_| panic!("Failed to insert batch starting at {}", batch_start));
        let batch_duration = start.elapsed();
        total_duration += batch_duration;

        println!(
            "  ✓ Inserted batch {}-{} ({} rows) in {:.2?}",
            batch_start, batch_end, batch_count, batch_duration
        );
    }

    // Verify row count
    let row_count = get_row_count(odbc_conn).expect("Failed to get row count");
    assert_eq!(
        row_count, TOTAL_ROWS,
        "Expected {} rows, got {}",
        TOTAL_ROWS, row_count
    );

    // Print metrics
    let metrics = BulkOperationMetrics::new(
        &format!("INSERT {} rows", TOTAL_ROWS),
        TOTAL_ROWS,
        total_duration,
    );
    metrics.print_summary();

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");
}

#[test]
#[serial]
fn test_e2e_bulk_read_all_rows() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: database not available");
        return;
    }

    let (conn_str, db_type) =
        get_connection_and_db_type().expect("Failed to get connection string and database type");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to database");

    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Ensure table exists with data (drop if exists first)
    ensure_table_dropped(odbc_conn);
    let create_sql = generate_create_table_sql(db_type);
    execute_command(odbc_conn, &create_sql).expect("Failed to create table");

    // Insert sample data in batches
    const TOTAL_ROWS: usize = 50000;
    const BATCH_SIZE: usize = 500;

    println!(
        "Inserting {} rows in batches of {} for read test...",
        TOTAL_ROWS, BATCH_SIZE
    );
    for batch_start in (1..=TOTAL_ROWS).step_by(BATCH_SIZE) {
        let batch_end = std::cmp::min(batch_start + BATCH_SIZE - 1, TOTAL_ROWS);
        let batch_count = batch_end - batch_start + 1;
        let insert_sql = generate_insert_batch(batch_start as i32, batch_count, db_type);
        execute_command(odbc_conn, &insert_sql)
            .unwrap_or_else(|_| panic!("Failed to insert batch starting at {}", batch_start));
    }

    // Read all rows
    println!("Reading all {} rows...", TOTAL_ROWS);
    let start = Instant::now();

    use odbc_engine::execute_query_with_connection;
    let buffer =
        execute_query_with_connection(odbc_conn, "SELECT * FROM odbc_bulk_test ORDER BY id")
            .expect("Failed to read rows");

    let read_duration = start.elapsed();

    // Decode and validate
    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(
        decoded.row_count, TOTAL_ROWS,
        "Expected {} rows, got {}",
        TOTAL_ROWS, decoded.row_count
    );
    assert_eq!(
        decoded.column_count, 8,
        "Expected 8 columns, got {}",
        decoded.column_count
    );

    // Validate first row
    if decoded.row_count > 0 {
        let first_row = &decoded.rows[0];
        assert_eq!(first_row.len(), 8, "First row should have 8 columns");

        // Validate ID (first column)
        if let Some(id_data) = &first_row[0] {
            let id = decode_integer(id_data);
            assert_eq!(id, 1, "First row ID should be 1");
        }

        // Validate name (second column)
        if let Some(name_data) = &first_row[1] {
            let name = decode_string(name_data);
            assert!(name.starts_with("User_"), "Name should start with 'User_'");
        }
    }

    // Validate last row
    if decoded.row_count > 0 {
        let last_row = &decoded.rows[decoded.row_count - 1];
        if let Some(id_data) = &last_row[0] {
            let id = decode_integer(id_data);
            assert_eq!(
                id, TOTAL_ROWS as i32,
                "Last row ID should be {}",
                TOTAL_ROWS
            );
        }
    }

    // Print metrics
    let metrics = BulkOperationMetrics::new(
        &format!("SELECT {} rows", TOTAL_ROWS),
        TOTAL_ROWS,
        read_duration,
    );
    metrics.print_summary();

    println!(
        "✓ Successfully read and validated {} rows",
        decoded.row_count
    );

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");
}

#[test]
#[serial]
fn test_e2e_bulk_update_operations() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: database not available");
        return;
    }

    let (conn_str, db_type) =
        get_connection_and_db_type().expect("Failed to get connection string and database type");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to database");

    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Setup: Create table and insert data
    ensure_table_dropped(odbc_conn);
    let create_sql = generate_create_table_sql(db_type);
    execute_command(odbc_conn, &create_sql).expect("Failed to create table");

    const TOTAL_ROWS: usize = 50000;
    const BATCH_SIZE: usize = 500;

    println!(
        "Inserting {} rows in batches of {} for update test...",
        TOTAL_ROWS, BATCH_SIZE
    );
    for batch_start in (1..=TOTAL_ROWS).step_by(BATCH_SIZE) {
        let batch_end = std::cmp::min(batch_start + BATCH_SIZE - 1, TOTAL_ROWS);
        let batch_count = batch_end - batch_start + 1;
        let insert_sql = generate_insert_batch(batch_start as i32, batch_count, db_type);
        execute_command(odbc_conn, &insert_sql)
            .unwrap_or_else(|_| panic!("Failed to insert batch starting at {}", batch_start));
    }

    // Determine concatenation operator based on database type
    let concat_op = match db_type {
        DatabaseType::SqlServer => "+",
        _ => "||",
    };

    // UPDATE 1: Small update (500 rows - 1%)
    println!("\n--- UPDATE 1: Small update (500 rows - 1%) ---");
    let update_sql_1 =
        "UPDATE odbc_bulk_test SET salary = salary * 1.1 WHERE id <= 500".to_string();
    let duration_1 =
        execute_command_with_metrics(odbc_conn, &update_sql_1).expect("Failed to execute UPDATE 1");

    let metrics_1 = BulkOperationMetrics::new("UPDATE 500 rows (1%)", 500, duration_1);
    metrics_1.print_summary();

    // UPDATE 2: Medium update (5,000 rows - 10%)
    println!("\n--- UPDATE 2: Medium update (5,000 rows - 10%) ---");
    let update_sql_2 = format!(
        "UPDATE odbc_bulk_test SET name = 'Updated_' {} name WHERE id <= 5000",
        concat_op
    );
    let duration_2 =
        execute_command_with_metrics(odbc_conn, &update_sql_2).expect("Failed to execute UPDATE 2");

    let metrics_2 = BulkOperationMetrics::new("UPDATE 5,000 rows (10%)", 5000, duration_2);
    metrics_2.print_summary();

    // UPDATE 3: Large update (25,000 rows - 50%)
    println!("\n--- UPDATE 3: Large update (25,000 rows - 50%) ---");
    let update_sql_3 = "UPDATE odbc_bulk_test SET age = age + 1 WHERE id <= 25000".to_string();
    let duration_3 =
        execute_command_with_metrics(odbc_conn, &update_sql_3).expect("Failed to execute UPDATE 3");

    let metrics_3 = BulkOperationMetrics::new("UPDATE 25,000 rows (50%)", 25000, duration_3);
    metrics_3.print_summary();

    // Verify final row count
    let final_count = get_row_count(odbc_conn).expect("Failed to get final row count");
    assert_eq!(
        final_count, TOTAL_ROWS,
        "Row count should remain {}",
        TOTAL_ROWS
    );

    println!("\n✓ All UPDATE operations completed successfully");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");
}

#[test]
#[serial]
fn test_e2e_bulk_delete_operations() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: database not available");
        return;
    }

    let (conn_str, db_type) =
        get_connection_and_db_type().expect("Failed to get connection string and database type");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to database");

    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Setup: Create table and insert data (drop if exists first)
    ensure_table_dropped(odbc_conn);
    let create_sql = generate_create_table_sql(db_type);
    execute_command(odbc_conn, &create_sql).expect("Failed to create table");

    const TOTAL_ROWS: usize = 50000;
    const BATCH_SIZE: usize = 500;

    println!(
        "Inserting {} rows in batches of {} for delete test...",
        TOTAL_ROWS, BATCH_SIZE
    );
    for batch_start in (1..=TOTAL_ROWS).step_by(BATCH_SIZE) {
        let batch_end = std::cmp::min(batch_start + BATCH_SIZE - 1, TOTAL_ROWS);
        let batch_count = batch_end - batch_start + 1;
        let insert_sql = generate_insert_batch(batch_start as i32, batch_count, db_type);
        execute_command(odbc_conn, &insert_sql)
            .unwrap_or_else(|_| panic!("Failed to insert batch starting at {}", batch_start));
    }

    let mut remaining_rows = TOTAL_ROWS;

    // DELETE 1: Small delete (500 rows - 1%)
    println!("\n--- DELETE 1: Small delete (500 rows - 1%) ---");
    let delete_sql_1 = format!(
        "DELETE FROM odbc_bulk_test WHERE id > {}",
        remaining_rows - 500
    );
    let duration_1 =
        execute_command_with_metrics(odbc_conn, &delete_sql_1).expect("Failed to execute DELETE 1");

    remaining_rows -= 500;
    let metrics_1 = BulkOperationMetrics::new("DELETE 500 rows (1%)", 500, duration_1);
    metrics_1.print_summary();

    // Verify count after DELETE 1
    let count_1 = get_row_count(odbc_conn).expect("Failed to get count after DELETE 1");
    assert_eq!(
        count_1, remaining_rows,
        "Expected {} rows after DELETE 1, got {}",
        remaining_rows, count_1
    );

    // DELETE 2: Medium delete (5,000 rows - 10% of remaining)
    println!("\n--- DELETE 2: Medium delete (5,000 rows - 10% of remaining) ---");
    let delete_sql_2 = format!(
        "DELETE FROM odbc_bulk_test WHERE id > {} AND id <= {}",
        remaining_rows - 5000,
        remaining_rows
    );
    let duration_2 =
        execute_command_with_metrics(odbc_conn, &delete_sql_2).expect("Failed to execute DELETE 2");

    remaining_rows -= 5000;
    let metrics_2 = BulkOperationMetrics::new("DELETE 5,000 rows (10%)", 5000, duration_2);
    metrics_2.print_summary();

    // Verify count after DELETE 2
    let count_2 = get_row_count(odbc_conn).expect("Failed to get count after DELETE 2");
    assert_eq!(
        count_2, remaining_rows,
        "Expected {} rows after DELETE 2, got {}",
        remaining_rows, count_2
    );

    // DELETE 3: Large delete (20,000 rows - 40% of remaining)
    println!("\n--- DELETE 3: Large delete (20,000 rows - 40% of remaining) ---");
    let delete_sql_3 = format!(
        "DELETE FROM odbc_bulk_test WHERE id > {} AND id <= {}",
        remaining_rows - 20000,
        remaining_rows
    );
    let duration_3 =
        execute_command_with_metrics(odbc_conn, &delete_sql_3).expect("Failed to execute DELETE 3");

    remaining_rows -= 20000;
    let metrics_3 = BulkOperationMetrics::new("DELETE 20,000 rows (40%)", 20000, duration_3);
    metrics_3.print_summary();

    // Verify final count
    let final_count = get_row_count(odbc_conn).expect("Failed to get final count");
    assert_eq!(
        final_count, remaining_rows,
        "Expected {} rows after all DELETEs, got {}",
        remaining_rows, final_count
    );

    println!("\n✓ All DELETE operations completed successfully");
    println!(
        "  Final row count: {} (started with {})",
        final_count, TOTAL_ROWS
    );

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");
}

#[test]
#[serial]
fn test_e2e_bulk_drop_table() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: database not available");
        return;
    }

    let (conn_str, _db_type) =
        get_connection_and_db_type().expect("Failed to get connection string and database type");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to database");

    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Ensure table exists (create if needed, drop if exists first)
    ensure_table_dropped(odbc_conn);
    let create_sql = generate_create_table_sql(_db_type);
    execute_command(odbc_conn, &create_sql).expect("Failed to create table");

    // Verify table exists
    let count_before = get_row_count(odbc_conn).ok();
    println!("Table exists (row count: {:?})", count_before);

    // Drop table
    println!("Dropping table odbc_bulk_test...");
    let start = Instant::now();
    execute_command(odbc_conn, "DROP TABLE odbc_bulk_test").expect("Failed to drop table");
    let duration = start.elapsed();

    println!("✓ Table dropped successfully in {:.2?}", duration);

    // Verify table no longer exists (should error or return 0)
    let count_after = get_row_count(odbc_conn);
    assert!(
        count_after.is_err() || count_after.unwrap_or(0) == 0,
        "Table should not exist after DROP"
    );

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");
}

#[test]
fn test_e2e_bulk_array_binding() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: database not available");
        return;
    }

    let (conn_str, _db_type) =
        get_connection_and_db_type().expect("Failed to get connection string and database type");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("Failed to connect");
    let conn_id = conn.get_connection_id();

    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn_id)
        .expect("Failed to get ODBC connection");

    let _ = execute_command(odbc_conn, "DROP TABLE IF EXISTS odbc_ab_test");
    let _ = execute_command(odbc_conn, "DROP TABLE odbc_ab_test");
    std::thread::sleep(Duration::from_millis(100));

    execute_command(odbc_conn, "CREATE TABLE odbc_ab_test (id INT)").expect("Create table");
    const N: usize = 5_000;
    let ids: Vec<i32> = (1..=N as i32).collect();
    let data: Vec<Vec<i32>> = vec![ids];

    let ab = ArrayBinding::new(1_000);
    let start = Instant::now();
    let inserted = ab
        .bulk_insert_i32(odbc_conn, "odbc_ab_test", &["id"], &data)
        .expect("bulk_insert_i32");
    let elapsed = start.elapsed();

    assert_eq!(inserted, N, "Expected {} rows inserted", N);
    let buf = execute_query_with_connection(odbc_conn, "SELECT COUNT(*) AS c FROM odbc_ab_test")
        .expect("SELECT COUNT");
    let dec = BinaryProtocolDecoder::parse(&buf).unwrap();
    let count = decode_integer(dec.rows[0][0].as_ref().unwrap());
    assert_eq!(count as usize, N);

    let m = BulkOperationMetrics::new("ArrayBinding insert", N, elapsed);
    m.print_summary();

    execute_command(odbc_conn, "DROP TABLE odbc_ab_test").expect("Drop table");
    drop(handles_guard);
    conn.disconnect().expect("Disconnect");
}

#[test]
fn test_e2e_bulk_parallel_insert() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: database not available");
        return;
    }

    let (conn_str, _db_type) =
        get_connection_and_db_type().expect("Failed to get connection string and database type");

    let pool = Arc::new(ConnectionPool::new(&conn_str, 4).expect("Create pool"));
    let mut wrapper = pool.get().expect("Get connection");
    let conn = wrapper.get_connection_mut();

    let _ = execute_command(conn, "DROP TABLE IF EXISTS odbc_pi_test");
    let _ = execute_command(conn, "DROP TABLE odbc_pi_test");
    std::thread::sleep(Duration::from_millis(100));
    execute_command(conn, "CREATE TABLE odbc_pi_test (id INT)").expect("Create table");
    drop(wrapper);

    const N: usize = 2_000;
    let ids: Vec<i32> = (1..=N as i32).collect();
    let data: Vec<Vec<i32>> = vec![ids];

    let pbi = ParallelBulkInsert::new(Arc::clone(&pool), 2).with_batch_size(500);
    let start = Instant::now();
    let inserted = pbi
        .insert_i32_parallel("odbc_pi_test", &["id"], data)
        .expect("insert_i32_parallel");
    let elapsed = start.elapsed();

    assert_eq!(inserted, N, "Expected {} rows inserted", N);

    let wrapper2 = pool.get().expect("Get connection");
    let conn2 = wrapper2.get_connection();
    let buf = execute_query_with_connection(conn2, "SELECT COUNT(*) AS c FROM odbc_pi_test")
        .expect("SELECT COUNT");
    let dec = BinaryProtocolDecoder::parse(&buf).unwrap();
    let count = decode_integer(dec.rows[0][0].as_ref().unwrap());
    assert_eq!(count as usize, N);

    let m = BulkOperationMetrics::new("ParallelBulkInsert", N, elapsed);
    m.print_summary();

    let mut w3 = pool.get().expect("Get connection");
    execute_command(w3.get_connection_mut(), "DROP TABLE odbc_pi_test").expect("Drop table");
}

#[test]
fn test_e2e_bulk_insert_generic() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: database not available");
        return;
    }

    let (conn_str, _db_type) =
        get_connection_and_db_type().expect("Failed to get connection string and database type");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("Failed to connect");
    let conn_id = conn.get_connection_id();

    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn_id)
        .expect("Failed to get ODBC connection");

    let _ = execute_command(odbc_conn, "DROP TABLE IF EXISTS odbc_bi_gen_test");
    let _ = execute_command(odbc_conn, "DROP TABLE odbc_bi_gen_test");
    std::thread::sleep(Duration::from_millis(100));

    execute_command(
        odbc_conn,
        "CREATE TABLE odbc_bi_gen_test (id INT, name VARCHAR(50))",
    )
    .expect("Create table");

    const N: usize = 500;
    let ids: Vec<i32> = (1..=N as i32).collect();
    let names: Vec<Vec<u8>> = (1..=N)
        .map(|i| format!("user_{}", i).into_bytes())
        .collect();
    let max_len = 50;

    let payload = BulkInsertPayload {
        table: "odbc_bi_gen_test".to_string(),
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
        row_count: N as u32,
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

    let ab = ArrayBinding::new(200);
    let start = Instant::now();
    let inserted = ab
        .bulk_insert_generic(odbc_conn, &payload)
        .expect("bulk_insert_generic");
    let elapsed = start.elapsed();

    assert_eq!(inserted, N, "Expected {} rows inserted", N);
    let buf =
        execute_query_with_connection(odbc_conn, "SELECT COUNT(*) AS c FROM odbc_bi_gen_test")
            .expect("SELECT COUNT");
    let dec = BinaryProtocolDecoder::parse(&buf).unwrap();
    let count = decode_integer(dec.rows[0][0].as_ref().unwrap());
    assert_eq!(count as usize, N);

    let m = BulkOperationMetrics::new("bulk_insert_generic I32+Text", N, elapsed);
    m.print_summary();

    execute_command(odbc_conn, "DROP TABLE odbc_bi_gen_test").expect("Drop table");
    drop(handles_guard);
    conn.disconnect().expect("Disconnect");
}
