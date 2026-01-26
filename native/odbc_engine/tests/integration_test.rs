use odbc_engine::*;

#[test]
#[ignore]
fn test_connection_lifecycle() {
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to init");

    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, "DSN=TestDSN;UID=user;PWD=pass;")
        .expect("Failed to connect");

    conn.disconnect().expect("Failed to disconnect");
}
