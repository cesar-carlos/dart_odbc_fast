//! M8 (v3.3.0) — streaming multi-result must surface every item
//! incrementally, regardless of the batch shape, instead of materialising
//! the whole batch in memory.
//!
//! Wire format of each chunk emitted by `odbc_stream_multi_start_batched`:
//!
//! ```text
//! [tag: u8] [len: u32 LE] [payload: len bytes]
//! ```
//!
//! Live ODBC tests are gated by `ENABLE_E2E_TESTS=1` + `ODBC_TEST_DSN`.

use odbc_engine::engine::{
    execute_multi_result, start_multi_batched_stream, OdbcConnection, OdbcEnvironment,
    MULTI_STREAM_ITEM_TAG_RESULT_SET, MULTI_STREAM_ITEM_TAG_ROW_COUNT,
};

fn dsn() -> Option<String> {
    let _ = dotenvy::dotenv();
    if std::env::var("ENABLE_E2E_TESTS").as_deref() != Ok("1") {
        return None;
    }
    std::env::var("ODBC_TEST_DSN")
        .ok()
        .filter(|s| !s.is_empty())
}

/// Read all chunks from a `BatchedStreamingState` and split them back into
/// `(tag, payload)` items using the documented framing.
fn drain_items(mut stream: odbc_engine::engine::BatchedStreamingState) -> Vec<(u8, Vec<u8>)> {
    let mut buffer: Vec<u8> = Vec::new();
    while stream.has_more() {
        if let Some(chunk) = stream.fetch_next_chunk().expect("fetch chunk") {
            buffer.extend(chunk);
        }
    }
    parse_frames(&buffer)
}

fn parse_frames(buf: &[u8]) -> Vec<(u8, Vec<u8>)> {
    let mut out = Vec::new();
    let mut i = 0;
    while i + 5 <= buf.len() {
        let tag = buf[i];
        let len = u32::from_le_bytes([buf[i + 1], buf[i + 2], buf[i + 3], buf[i + 4]]) as usize;
        i += 5;
        assert!(
            i + len <= buf.len(),
            "frame at offset {i} declares len {len} but buffer is only {}",
            buf.len()
        );
        out.push((tag, buf[i..i + len].to_vec()));
        i += len;
    }
    assert_eq!(i, buf.len(), "trailing bytes left in stream buffer");
    out
}

#[test]
#[ignore]
fn streaming_shape_1_three_cursors() {
    let Some(dsn_str) = dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set / ENABLE_E2E_TESTS != 1");
        return;
    };
    let env = OdbcEnvironment::new();
    env.init().expect("init env");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &dsn_str).expect("connect");
    let conn_id = conn.get_connection_id();

    let stream = start_multi_batched_stream(
        handles,
        conn_id,
        "SELECT 1 AS a; SELECT 2 AS b; SELECT 3 AS c".to_string(),
        4096,
    )
    .expect("start stream");
    let items = drain_items(stream);
    assert_eq!(items.len(), 3, "expected 3 items, got {items:?}");
    for (tag, _) in &items {
        assert_eq!(*tag, MULTI_STREAM_ITEM_TAG_RESULT_SET);
    }
    conn.disconnect().expect("disconnect");
}

#[test]
#[ignore]
fn streaming_shape_3_rowcount_then_cursor() {
    let Some(dsn_str) = dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set / ENABLE_E2E_TESTS != 1");
        return;
    };
    let env = OdbcEnvironment::new();
    env.init().expect("init env");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &dsn_str).expect("connect");
    let conn_id = conn.get_connection_id();
    let table = format!("m8_dmldql_{}", std::process::id());
    let make_conn_call = |sql: String| -> () {
        let h = handles.lock().unwrap();
        let arc = h.get_connection(conn_id).unwrap();
        let cached = arc.lock().unwrap();
        let _ = execute_multi_result(cached.connection(), &sql);
    };
    make_conn_call(format!(
        "IF OBJECT_ID('{table}', 'U') IS NOT NULL DROP TABLE {table}"
    ));
    make_conn_call(format!(
        "CREATE TABLE {table} (id INT PRIMARY KEY, val NVARCHAR(20))"
    ));

    let sql = format!(
        "INSERT INTO {table} (id, val) VALUES (1, 'a'), (2, 'b'); \
         SELECT id, val FROM {table} ORDER BY id"
    );
    let stream =
        start_multi_batched_stream(handles.clone(), conn_id, sql, 4096).expect("start stream");
    let items = drain_items(stream);

    assert_eq!(items.len(), 2, "expected 2 items, got {items:?}");
    assert_eq!(items[0].0, MULTI_STREAM_ITEM_TAG_ROW_COUNT);
    let rc = i64::from_le_bytes([
        items[0].1[0],
        items[0].1[1],
        items[0].1[2],
        items[0].1[3],
        items[0].1[4],
        items[0].1[5],
        items[0].1[6],
        items[0].1[7],
    ]);
    assert_eq!(rc, 2);
    assert_eq!(items[1].0, MULTI_STREAM_ITEM_TAG_RESULT_SET);

    make_conn_call(format!("DROP TABLE {table}"));
    conn.disconnect().expect("disconnect");
}

#[test]
#[ignore]
fn streaming_shape_4_cursor_then_rowcount() {
    let Some(dsn_str) = dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set / ENABLE_E2E_TESTS != 1");
        return;
    };
    let env = OdbcEnvironment::new();
    env.init().expect("init env");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &dsn_str).expect("connect");
    let conn_id = conn.get_connection_id();
    let table = format!("m8_dqldml_{}", std::process::id());
    let setup = |sql: String| {
        let h = handles.lock().unwrap();
        let arc = h.get_connection(conn_id).unwrap();
        let cached = arc.lock().unwrap();
        let _ = execute_multi_result(cached.connection(), &sql);
    };
    setup(format!(
        "IF OBJECT_ID('{table}', 'U') IS NOT NULL DROP TABLE {table}"
    ));
    setup(format!("CREATE TABLE {table} (id INT PRIMARY KEY, n INT)"));
    setup(format!(
        "INSERT INTO {table} (id, n) VALUES (1, 10), (2, 20)"
    ));

    let sql = format!("SELECT id, n FROM {table} ORDER BY id; UPDATE {table} SET n = n + 1");
    let stream =
        start_multi_batched_stream(handles.clone(), conn_id, sql, 4096).expect("start stream");
    let items = drain_items(stream);

    assert_eq!(items.len(), 2, "expected 2 items, got {items:?}");
    assert_eq!(items[0].0, MULTI_STREAM_ITEM_TAG_RESULT_SET);
    assert_eq!(items[1].0, MULTI_STREAM_ITEM_TAG_ROW_COUNT);
    let rc = i64::from_le_bytes([
        items[1].1[0],
        items[1].1[1],
        items[1].1[2],
        items[1].1[3],
        items[1].1[4],
        items[1].1[5],
        items[1].1[6],
        items[1].1[7],
    ]);
    assert_eq!(rc, 2);

    setup(format!("DROP TABLE {table}"));
    conn.disconnect().expect("disconnect");
}
