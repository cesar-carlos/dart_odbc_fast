//! M1 (v3.2.0) — `execute_multi_result` must collect every result set the
//! batch produces, regardless of whether the **first** statement was a
//! cursor or a row-count.
//!
//! Pre-v3.2 the engine took an `if had_cursor { … } else { row_count }`
//! shape that silently dropped everything past the first item in two of the
//! four batch shapes:
//!
//! 1. cursor → cursor → cursor                  (already worked)
//! 2. row-count → row-count → row-count         (returned only the first)
//! 3. row-count → cursor                        (cursor was lost)
//! 4. cursor → row-count                        (row-count was lost)
//!
//! Live ODBC tests are gated behind `#[ignore]` and only run when
//! `ODBC_TEST_DSN` is set + `ENABLE_E2E_TESTS=1`.

use odbc_engine::engine::{execute_multi_result, OdbcConnection, OdbcEnvironment};
use odbc_engine::protocol::{decode_multi, MultiResultItem};

fn dsn() -> Option<String> {
    let _ = dotenvy::dotenv();
    if std::env::var("ENABLE_E2E_TESTS").as_deref() != Ok("1") {
        return None;
    }
    std::env::var("ODBC_TEST_DSN")
        .ok()
        .filter(|s| !s.is_empty())
}

/// Run a closure with a single SQL Server connection. The closure receives
/// the live `&Connection<'static>`; nothing leaks across tests.
fn with_conn<F>(f: F)
where
    F: FnOnce(&odbc_api::Connection<'static>),
{
    let Some(dsn_str) = dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set / ENABLE_E2E_TESTS != 1");
        return;
    };
    let env = OdbcEnvironment::new();
    env.init().expect("init env");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &dsn_str).expect("connect");
    let conn_id = conn.get_connection_id();
    {
        let h = handles.lock().expect("lock handles");
        let conn_arc = h.get_connection(conn_id).expect("get conn arc");
        let cached = conn_arc.lock().expect("lock conn");
        f(cached.connection());
    }
    conn.disconnect().expect("disconnect");
}

#[test]
#[ignore]
fn batch_shape_2_rowcount_then_rowcount_collects_all_items() {
    with_conn(|conn| {
        // Setup ephemeral table per-process so multiple test runs don't collide.
        let table = format!("m1_dml_{}", std::process::id());
        let _ = execute_multi_result(
            conn,
            &format!("IF OBJECT_ID('{table}', 'U') IS NOT NULL DROP TABLE {table}"),
        );
        execute_multi_result(conn, &format!("CREATE TABLE {table} (id INT PRIMARY KEY)"))
            .expect("create");

        let sql = format!(
            "INSERT INTO {table} (id) VALUES (1); \
             INSERT INTO {table} (id) VALUES (2); \
             INSERT INTO {table} (id) VALUES (3)"
        );
        let buf = execute_multi_result(conn, &sql).expect("multi exec");
        let items = decode_multi(&buf).expect("decode");

        // Should yield three RowCount items (one per INSERT). Pre-v3.2 only
        // returned the first.
        assert_eq!(items.len(), 3, "expected 3 row-counts, got {items:?}");
        for it in &items {
            assert!(
                matches!(it, MultiResultItem::RowCount(n) if *n == 1),
                "expected RowCount(1), got {it:?}"
            );
        }

        let _ = execute_multi_result(conn, &format!("DROP TABLE {table}"));
    });
}

#[test]
#[ignore]
fn batch_shape_3_rowcount_then_cursor_collects_all_items() {
    with_conn(|conn| {
        let table = format!("m1_dmldql_{}", std::process::id());
        let _ = execute_multi_result(
            conn,
            &format!("IF OBJECT_ID('{table}', 'U') IS NOT NULL DROP TABLE {table}"),
        );
        execute_multi_result(
            conn,
            &format!("CREATE TABLE {table} (id INT PRIMARY KEY, val NVARCHAR(20))"),
        )
        .expect("create");

        let sql = format!(
            "INSERT INTO {table} (id, val) VALUES (1, 'a'), (2, 'b'); \
             SELECT id, val FROM {table} ORDER BY id"
        );
        let buf = execute_multi_result(conn, &sql).expect("multi exec");
        let items = decode_multi(&buf).expect("decode");

        assert_eq!(items.len(), 2, "expected 2 items, got {items:?}");
        // Pre-v3.2 returned only the row-count; the cursor was lost.
        assert!(
            matches!(items[0], MultiResultItem::RowCount(2)),
            "first item must be RowCount(2), got {:?}",
            items[0]
        );
        assert!(
            matches!(items[1], MultiResultItem::ResultSet(_)),
            "second item must be ResultSet, got {:?}",
            items[1]
        );

        let _ = execute_multi_result(conn, &format!("DROP TABLE {table}"));
    });
}

#[test]
#[ignore]
fn batch_shape_4_cursor_then_rowcount_collects_all_items() {
    with_conn(|conn| {
        let table = format!("m1_dqldml_{}", std::process::id());
        let _ = execute_multi_result(
            conn,
            &format!("IF OBJECT_ID('{table}', 'U') IS NOT NULL DROP TABLE {table}"),
        );
        execute_multi_result(
            conn,
            &format!("CREATE TABLE {table} (id INT PRIMARY KEY, n INT)"),
        )
        .expect("create");
        execute_multi_result(
            conn,
            &format!("INSERT INTO {table} (id, n) VALUES (1, 10), (2, 20)"),
        )
        .expect("seed");

        let sql = format!(
            "SELECT id, n FROM {table} ORDER BY id; \
             UPDATE {table} SET n = n + 1"
        );
        let buf = execute_multi_result(conn, &sql).expect("multi exec");
        let items = decode_multi(&buf).expect("decode");

        assert_eq!(items.len(), 2, "expected 2 items, got {items:?}");
        // Pre-v3.2 returned only the cursor; the trailing UPDATE row-count
        // was lost.
        assert!(
            matches!(items[0], MultiResultItem::ResultSet(_)),
            "first item must be ResultSet, got {:?}",
            items[0]
        );
        assert!(
            matches!(items[1], MultiResultItem::RowCount(2)),
            "second item must be RowCount(2), got {:?}",
            items[1]
        );

        let _ = execute_multi_result(conn, &format!("DROP TABLE {table}"));
    });
}

#[test]
#[ignore]
fn batch_shape_1_three_cursors_still_works() {
    with_conn(|conn| {
        // Already-supported shape; included as smoke test to make sure the
        // refactor in M1 did not regress it.
        let sql = "SELECT 1 AS a; SELECT 2 AS b; SELECT 3 AS c";
        let buf = execute_multi_result(conn, sql).expect("multi exec");
        let items = decode_multi(&buf).expect("decode");
        assert_eq!(items.len(), 3, "expected 3 cursors, got {items:?}");
        for it in &items {
            assert!(
                matches!(it, MultiResultItem::ResultSet(_)),
                "expected ResultSet, got {it:?}"
            );
        }
    });
}
