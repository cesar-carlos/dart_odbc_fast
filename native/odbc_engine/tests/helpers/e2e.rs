/// Helper functions for E2E tests
/// Provides utilities to check if E2E tests can run (connection available)
use super::env::get_sqlserver_test_dsn;
use odbc_engine::engine::{OdbcConnection, OdbcEnvironment};
use odbc_engine::test_helpers::load_dotenv;

/// Tipo de banco de dados detectado
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DatabaseType {
    SqlServer,
    Sybase,
    PostgreSQL,
    MySQL,
    Oracle,
    MongoDB,
    SQLite,
    Unknown,
}

/// Detecta o tipo de banco de dados pela string de conexão
pub fn detect_database_type(conn_str: &str) -> DatabaseType {
    let conn_lower = conn_str.to_lowercase();

    // SQL Server - vários drivers possíveis
    if conn_lower.contains("sql server")
        || conn_lower.contains("driver={odbc driver")
        || (conn_lower.contains("server=")
            && conn_lower.contains("database=")
            && !conn_lower.contains("sql anywhere"))
    {
        return DatabaseType::SqlServer;
    }

    // Sybase Anywhere
    if conn_lower.contains("sql anywhere")
        || conn_lower.contains("sybase")
        || conn_lower.contains("servername=")
    {
        return DatabaseType::Sybase;
    }

    // PostgreSQL
    if conn_lower.contains("postgresql") {
        return DatabaseType::PostgreSQL;
    }

    // MySQL
    if conn_lower.contains("mysql") {
        return DatabaseType::MySQL;
    }

    // Oracle
    if conn_lower.contains("oracle") {
        return DatabaseType::Oracle;
    }

    // MongoDB (ODBC connector)
    if conn_lower.contains("mongodb") {
        return DatabaseType::MongoDB;
    }

    // SQLite
    if conn_lower.contains("sqlite") {
        return DatabaseType::SQLite;
    }

    DatabaseType::Unknown
}

/// Obtém a string de conexão e detecta o tipo de banco
#[allow(dead_code)]
pub fn get_connection_and_db_type() -> Option<(String, DatabaseType)> {
    load_dotenv();

    let conn_str = get_sqlserver_test_dsn()?;
    let db_type = detect_database_type(&conn_str);

    Some((conn_str, db_type))
}

/// Verifica se é possível conectar ao banco de dados para testes E2E
/// Retorna `true` se a conexão está disponível e funcional
#[allow(dead_code)] // Test helper API; used by e2e tests when ODBC is configured
pub fn can_connect_to_sqlserver() -> bool {
    // Carregar variáveis do .env
    load_dotenv();

    // Verificar se connection string está disponível
    let conn_str = match get_sqlserver_test_dsn() {
        Some(s) => s,
        None => {
            return false;
        }
    };

    // Tentar inicializar ambiente ODBC
    let env = OdbcEnvironment::new();
    if env.init().is_err() {
        return false;
    }

    // Tentar conectar ao banco de dados
    let handles = env.get_handles();
    match OdbcConnection::connect(handles, &conn_str) {
        Ok(conn) => {
            // Se conectou com sucesso, desconectar e retornar true
            let _ = conn.disconnect();
            let db_type = detect_database_type(&conn_str);
            eprintln!(
                "✓ Connection successful with: {} (detected as {:?})",
                conn_str, db_type
            );
            true
        }
        Err(e) => {
            eprintln!("✗ Connection failed: {:?}", e);
            eprintln!("  Connection string: {}", conn_str);
            false
        }
    }
}

/// Verifica se o teste deve rodar para um banco de dados específico
/// Retorna true se o banco conectado é o esperado
#[allow(dead_code)]
pub fn is_database_type(expected: DatabaseType) -> bool {
    load_dotenv();

    if let Some((_conn_str, db_type)) = get_connection_and_db_type() {
        if db_type == expected {
            return true;
        } else {
            eprintln!(
                "⚠️  Skipping test: requires {:?}, but connected to {:?}",
                expected, db_type
            );
            return false;
        }
    }

    false
}

/// Verifica se testes E2E devem ser executados
/// Só executa quando ENABLE_E2E_TESTS estiver explicitamente habilitado
#[allow(dead_code)] // Test helper API; used by e2e tests when ENABLE_E2E_TESTS is set
pub fn should_run_e2e_tests() -> bool {
    // Carregar variáveis do .env
    load_dotenv();

    fn parse_env_bool(raw: &str) -> Option<bool> {
        let normalized = raw.trim().to_lowercase();
        if normalized.is_empty() {
            return None;
        }

        match normalized.as_str() {
            "1" | "true" | "yes" | "y" => Some(true),
            "0" | "false" | "no" | "n" => Some(false),
            _ => None,
        }
    }

    let enabled = std::env::var("ENABLE_E2E_TESTS")
        .ok()
        .as_deref()
        .and_then(parse_env_bool)
        == Some(true);

    if !enabled {
        return false;
    }

    can_connect_to_sqlserver()
}
