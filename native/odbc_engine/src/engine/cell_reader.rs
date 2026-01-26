use crate::error::{OdbcError, Result};
use crate::protocol::OdbcType;
use odbc_api::CursorRow;

pub fn read_cell_bytes(
    row: &mut CursorRow<'_>,
    column_number: u16,
    odbc_type: OdbcType,
) -> Result<Option<Vec<u8>>> {
    match odbc_type {
        OdbcType::Binary => read_binary(row, column_number),
        OdbcType::Integer => read_i32_as_le_bytes(row, column_number),
        OdbcType::BigInt => read_i64_as_le_bytes(row, column_number),
        _ => read_text(row, column_number),
    }
}

fn read_text(row: &mut CursorRow<'_>, column_number: u16) -> Result<Option<Vec<u8>>> {
    let mut buf: Vec<u8> = Vec::new();
    let has_value = row
        .get_text(column_number, &mut buf)
        .map_err(OdbcError::from)?;

    if has_value {
        Ok(Some(buf))
    } else {
        Ok(None)
    }
}

fn read_binary(row: &mut CursorRow<'_>, column_number: u16) -> Result<Option<Vec<u8>>> {
    let mut buf: Vec<u8> = Vec::new();
    let has_value = row
        .get_binary(column_number, &mut buf)
        .map_err(OdbcError::from)?;

    if has_value {
        Ok(Some(buf))
    } else {
        Ok(None)
    }
}

fn read_i32_as_le_bytes(row: &mut CursorRow<'_>, column_number: u16) -> Result<Option<Vec<u8>>> {
    let text_bytes = read_text(row, column_number)?;
    let Some(text_bytes) = text_bytes else {
        return Ok(None);
    };

    let s = std::str::from_utf8(&text_bytes).unwrap_or("").trim();
    if let Ok(value) = s.parse::<i32>() {
        return Ok(Some(value.to_le_bytes().to_vec()));
    }

    Ok(Some(text_bytes))
}

fn read_i64_as_le_bytes(row: &mut CursorRow<'_>, column_number: u16) -> Result<Option<Vec<u8>>> {
    let text_bytes = read_text(row, column_number)?;
    let Some(text_bytes) = text_bytes else {
        return Ok(None);
    };

    let s = std::str::from_utf8(&text_bytes).unwrap_or("").trim();
    if let Ok(value) = s.parse::<i64>() {
        return Ok(Some(value.to_le_bytes().to_vec()));
    }

    Ok(Some(text_bytes))
}

#[cfg(test)]
mod tests {
    use crate::engine::{execute_query_with_connection, OdbcConnection, OdbcEnvironment};

    fn get_test_dsn() -> Option<String> {
        std::env::var("ODBC_TEST_DSN")
            .ok()
            .filter(|s| !s.is_empty())
    }

    #[test]
    #[ignore]
    fn test_read_cell_bytes_integer() {
        let conn_str = get_test_dsn().expect("ODBC_TEST_DSN not set");

        let env = OdbcEnvironment::new();
        env.init().expect("Failed to initialize environment");

        let handles = env.get_handles();
        let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect");

        let handles = conn.get_handles();
        let handles_guard = handles.lock().unwrap();
        let odbc_conn = handles_guard
            .get_connection(conn.get_connection_id())
            .expect("Failed to get ODBC connection");

        let sql = "SELECT 42 AS value";
        let buffer =
            execute_query_with_connection(odbc_conn, sql).expect("Failed to execute query");

        drop(handles_guard);
        conn.disconnect().expect("Failed to disconnect");

        let decoded =
            crate::protocol::BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode");

        assert_eq!(decoded.column_count, 1);
        assert_eq!(decoded.row_count, 1);
    }

    #[test]
    #[ignore]
    fn test_read_cell_bytes_text() {
        let conn_str = get_test_dsn().expect("ODBC_TEST_DSN not set");

        let env = OdbcEnvironment::new();
        env.init().expect("Failed to initialize environment");

        let handles = env.get_handles();
        let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect");

        let handles = conn.get_handles();
        let handles_guard = handles.lock().unwrap();
        let odbc_conn = handles_guard
            .get_connection(conn.get_connection_id())
            .expect("Failed to get ODBC connection");

        let sql = "SELECT 'test' AS value";
        let buffer =
            execute_query_with_connection(odbc_conn, sql).expect("Failed to execute query");

        drop(handles_guard);
        conn.disconnect().expect("Failed to disconnect");

        let decoded =
            crate::protocol::BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode");

        assert_eq!(decoded.column_count, 1);
        assert_eq!(decoded.row_count, 1);
    }

    #[test]
    #[ignore]
    fn test_read_cell_bytes_null() {
        let conn_str = get_test_dsn().expect("ODBC_TEST_DSN not set");

        let env = OdbcEnvironment::new();
        env.init().expect("Failed to initialize environment");

        let handles = env.get_handles();
        let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect");

        let handles = conn.get_handles();
        let handles_guard = handles.lock().unwrap();
        let odbc_conn = handles_guard
            .get_connection(conn.get_connection_id())
            .expect("Failed to get ODBC connection");

        let sql = "SELECT NULL AS value";
        let buffer =
            execute_query_with_connection(odbc_conn, sql).expect("Failed to execute query");

        drop(handles_guard);
        conn.disconnect().expect("Failed to disconnect");

        let decoded =
            crate::protocol::BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode");

        assert_eq!(decoded.column_count, 1);
        assert_eq!(decoded.row_count, 1);
        assert_eq!(decoded.rows[0][0], None);
    }

    #[test]
    #[ignore]
    fn test_read_cell_bytes_bigint() {
        let conn_str = get_test_dsn().expect("ODBC_TEST_DSN not set");

        let env = OdbcEnvironment::new();
        env.init().expect("Failed to initialize environment");

        let handles = env.get_handles();
        let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect");

        let handles = conn.get_handles();
        let handles_guard = handles.lock().unwrap();
        let odbc_conn = handles_guard
            .get_connection(conn.get_connection_id())
            .expect("Failed to get ODBC connection");

        let sql = "SELECT 9223372036854775807 AS value";
        let buffer =
            execute_query_with_connection(odbc_conn, sql).expect("Failed to execute query");

        drop(handles_guard);
        conn.disconnect().expect("Failed to disconnect");

        let decoded =
            crate::protocol::BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode");

        assert_eq!(decoded.column_count, 1);
        assert_eq!(decoded.row_count, 1);
    }
}
