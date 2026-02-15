//! E2E stress tests: massive insert/update/delete under explicit transaction control
//! (commit and rollback). Uses a dedicated table to avoid clashes with other bulk tests.

mod helpers;
use helpers::e2e::{get_connection_and_db_type, should_run_e2e_tests, DatabaseType};
use odbc_api::Connection;
use odbc_engine::{
    engine::{IsolationLevel, OdbcConnection, OdbcEnvironment},
    execute_query_with_connection, BinaryProtocolDecoder,
};
use serial_test::serial;

const TABLE_NAME: &str = "odbc_bulk_txn_stress";
const STRESS_COMMIT_INSERT_ROWS: usize = 10_000;
const STRESS_ROLLBACK_INSERT_ROWS: usize = 5_000;
const STRESS_BATCH_SIZE: usize = 500;
const STRESS_UPDATE_LIMIT: i32 = 2_000;
const STRESS_DELETE_AFTER_ID: i32 = 8_000;

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

fn generate_create_table_sql(table_name: &str, db_type: DatabaseType) -> String {
    match db_type {
        DatabaseType::SqlServer => format!(
            r#"CREATE TABLE {} (
                id INTEGER PRIMARY KEY,
                name VARCHAR(100),
                age INTEGER,
                salary DECIMAL(10,2),
                is_active BIT,
                birth_date DATE,
                created_at DATETIME2,
                description VARCHAR(500)
            )"#,
            table_name
        ),
        DatabaseType::Sybase => format!(
            r#"CREATE TABLE {} (
                id INTEGER PRIMARY KEY,
                name VARCHAR(100),
                age INTEGER,
                salary DECIMAL(10,2),
                is_active INTEGER,
                birth_date DATE,
                created_at TIMESTAMP,
                description VARCHAR(500)
            )"#,
            table_name
        ),
        _ => format!(
            r#"CREATE TABLE {} (
                id INTEGER PRIMARY KEY,
                name VARCHAR(100),
                age INTEGER,
                salary DECIMAL(10,2),
                is_active INTEGER,
                birth_date DATE,
                created_at TIMESTAMP,
                description VARCHAR(500)
            )"#,
            table_name
        ),
    }
}

fn generate_insert_batch(
    table_name: &str,
    start_id: i32,
    count: usize,
    _db_type: DatabaseType,
) -> String {
    let mut sql = format!(
        "INSERT INTO {} (id, name, age, salary, is_active, birth_date, created_at, description) VALUES ",
        table_name
    );
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

fn drop_table_sql_idempotent(table_name: &str, db_type: DatabaseType) -> String {
    match db_type {
        DatabaseType::SqlServer => {
            format!(
                "IF OBJECT_ID(N'{}', N'U') IS NOT NULL DROP TABLE {}",
                table_name, table_name
            )
        }
        _ => format!("DROP TABLE IF EXISTS {}", table_name),
    }
}

fn get_row_count_from_conn(
    conn: &Connection<'static>,
    table_name: &str,
) -> Result<usize, odbc_engine::OdbcError> {
    let buffer = execute_query_with_connection(
        conn,
        &format!("SELECT COUNT(*) AS cnt FROM {}", table_name),
    )?;
    let decoded = BinaryProtocolDecoder::parse(&buffer)
        .map_err(|e| odbc_engine::OdbcError::InternalError(format!("Failed to decode: {}", e)))?;
    if decoded.row_count > 0 && decoded.rows[0][0].is_some() {
        let count_data = decoded.rows[0][0].as_ref().unwrap();
        Ok(decode_integer(count_data) as usize)
    } else {
        Ok(0)
    }
}

fn execute_sql_on_conn(
    conn: &Connection<'static>,
    sql: &str,
) -> Result<(), odbc_engine::OdbcError> {
    execute_query_with_connection(conn, sql).map(|_| ())
}

#[test]
#[ignore]
#[serial]
fn test_e2e_bulk_stress_transaction_commit() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: database not available");
        return;
    }

    let (conn_str, db_type) =
        get_connection_and_db_type().expect("Failed to get connection string and database type");

    let env = OdbcEnvironment::new();
    env.init().expect("Init failed");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("Connect failed");
    let conn_id = conn.get_connection_id();

    let drop_sql = drop_table_sql_idempotent(TABLE_NAME, db_type);
    {
        let h = handles.lock().expect("lock");
        let c = h.get_connection(conn_id).expect("get_connection");
        execute_sql_on_conn(c, &drop_sql).ok();
    }
    {
        let h = handles.lock().expect("lock");
        let c = h.get_connection(conn_id).expect("get_connection");
        let create_sql = generate_create_table_sql(TABLE_NAME, db_type);
        execute_sql_on_conn(c, &create_sql).expect("CREATE TABLE failed");
    }

    let txn = conn
        .begin_transaction(IsolationLevel::ReadCommitted)
        .expect("begin_transaction failed");

    for batch_start in (1..=STRESS_COMMIT_INSERT_ROWS).step_by(STRESS_BATCH_SIZE) {
        let batch_end = (batch_start + STRESS_BATCH_SIZE - 1).min(STRESS_COMMIT_INSERT_ROWS);
        let batch_count = batch_end - batch_start + 1;
        let insert_sql =
            generate_insert_batch(TABLE_NAME, batch_start as i32, batch_count, db_type);
        let h = handles.lock().expect("lock");
        let c = h.get_connection(conn_id).expect("get_connection");
        execute_sql_on_conn(c, &insert_sql)
            .unwrap_or_else(|_| panic!("INSERT batch {}-{} failed", batch_start, batch_end));
    }

    let update_sql = format!(
        "UPDATE {} SET salary = salary * 1.1 WHERE id <= {}",
        TABLE_NAME, STRESS_UPDATE_LIMIT
    );
    {
        let h = handles.lock().expect("lock");
        let c = h.get_connection(conn_id).expect("get_connection");
        execute_sql_on_conn(c, &update_sql).expect("UPDATE failed");
    }

    let delete_sql = format!(
        "DELETE FROM {} WHERE id > {}",
        TABLE_NAME, STRESS_DELETE_AFTER_ID
    );
    {
        let h = handles.lock().expect("lock");
        let c = h.get_connection(conn_id).expect("get_connection");
        execute_sql_on_conn(c, &delete_sql).expect("DELETE failed");
    }

    txn.commit().expect("commit failed");

    let expected_rows = STRESS_DELETE_AFTER_ID as usize;
    let count = {
        let h = handles.lock().expect("lock");
        let c = h.get_connection(conn_id).expect("get_connection");
        get_row_count_from_conn(c, TABLE_NAME).expect("SELECT COUNT failed")
    };
    assert_eq!(
        count, expected_rows,
        "Expected {} rows after commit, got {}",
        expected_rows, count
    );

    {
        let h = handles.lock().expect("lock");
        let c = h.get_connection(conn_id).expect("get_connection");
        let drop_sql = drop_table_sql_idempotent(TABLE_NAME, db_type);
        execute_sql_on_conn(c, &drop_sql).ok();
    }
    conn.disconnect().expect("disconnect failed");
}

#[test]
#[ignore]
#[serial]
fn test_e2e_bulk_stress_transaction_rollback() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: database not available");
        return;
    }

    let (conn_str, db_type) =
        get_connection_and_db_type().expect("Failed to get connection string and database type");

    let env = OdbcEnvironment::new();
    env.init().expect("Init failed");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("Connect failed");
    let conn_id = conn.get_connection_id();

    let drop_sql = drop_table_sql_idempotent(TABLE_NAME, db_type);
    {
        let h = handles.lock().expect("lock");
        let c = h.get_connection(conn_id).expect("get_connection");
        execute_sql_on_conn(c, &drop_sql).ok();
    }
    {
        let h = handles.lock().expect("lock");
        let c = h.get_connection(conn_id).expect("get_connection");
        let create_sql = generate_create_table_sql(TABLE_NAME, db_type);
        execute_sql_on_conn(c, &create_sql).expect("CREATE TABLE failed");
    }

    {
        let txn = conn
            .begin_transaction(IsolationLevel::ReadCommitted)
            .expect("begin_transaction failed");

        for batch_start in (1..=STRESS_ROLLBACK_INSERT_ROWS).step_by(STRESS_BATCH_SIZE) {
            let batch_end = (batch_start + STRESS_BATCH_SIZE - 1).min(STRESS_ROLLBACK_INSERT_ROWS);
            let batch_count = batch_end - batch_start + 1;
            let insert_sql =
                generate_insert_batch(TABLE_NAME, batch_start as i32, batch_count, db_type);
            let h = handles.lock().expect("lock");
            let c = h.get_connection(conn_id).expect("get_connection");
            execute_sql_on_conn(c, &insert_sql)
                .unwrap_or_else(|_| panic!("INSERT batch {}-{} failed", batch_start, batch_end));
        }

        let update_sql = format!("UPDATE {} SET age = age + 1 WHERE id <= 1000", TABLE_NAME);
        let h = handles.lock().expect("lock");
        let c = h.get_connection(conn_id).expect("get_connection");
        execute_sql_on_conn(c, &update_sql).expect("UPDATE failed");

        txn.rollback().expect("rollback failed");
    }

    let count = {
        let h = handles.lock().expect("lock");
        let c = h.get_connection(conn_id).expect("get_connection");
        get_row_count_from_conn(c, TABLE_NAME).expect("SELECT COUNT failed")
    };
    assert_eq!(
        count, 0,
        "Expected 0 rows after rollback (table should be empty), got {}",
        count
    );

    {
        let h = handles.lock().expect("lock");
        let c = h.get_connection(conn_id).expect("get_connection");
        let drop_sql = drop_table_sql_idempotent(TABLE_NAME, db_type);
        execute_sql_on_conn(c, &drop_sql).ok();
    }
    conn.disconnect().expect("disconnect failed");
}
