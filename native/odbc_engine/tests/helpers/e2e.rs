/// Helper functions for E2E tests
/// Provides utilities to check if E2E tests can run (connection available)
use super::env::get_sqlserver_test_dsn;
use odbc_engine::engine::{OdbcConnection, OdbcEnvironment};
use std::sync::Once;

static INIT: Once = Once::new();

/// Carrega variáveis de ambiente do arquivo .env (apenas uma vez)
/// Prioriza o .env sobre variáveis de ambiente do sistema
fn load_dotenv() {
    INIT.call_once(|| {
        // Procura o .env na raiz do projeto (onde está o .env)
        let mut current = std::env::current_dir().ok();
        let mut found_env = None;

        // Procura subindo os diretórios até encontrar o .env
        while let Some(dir) = current {
            let dotenv_path = dir.join(".env");
            if dotenv_path.exists() {
                found_env = Some(dotenv_path);
                break;
            }

            // Tenta também 2 níveis acima (raiz do projeto)
            if let Some(parent) = dir.parent() {
                let root_dotenv = parent.join(".env");
                if root_dotenv.exists() {
                    found_env = Some(root_dotenv);
                    break;
                }
            }

            current = dir.parent().map(|p| p.to_path_buf());

            // Limite: não subir mais que 5 níveis
            if dir.components().count() < 3 {
                break;
            }
        }

        // Se encontrou o .env, carrega manualmente para garantir que sobrescreva variáveis existentes
        if let Some(env_path) = found_env {
            if let Ok(contents) = std::fs::read_to_string(&env_path) {
                for line in contents.lines() {
                    let line = line.trim();
                    // Ignora comentários e linhas vazias
                    if line.is_empty() || line.starts_with('#') {
                        continue;
                    }
                    // Processa linhas no formato KEY=VALUE
                    if let Some(equal_pos) = line.find('=') {
                        let key = line[..equal_pos].trim();
                        let value = line[equal_pos + 1..].trim();
                        // Remove aspas se houver
                        let value = value.trim_matches('"').trim_matches('\'');
                        // Define a variável, sobrescrevendo qualquer valor existente
                        std::env::set_var(key, value);
                    }
                }
                eprintln!(
                    "📁 Loaded .env from: {} (overriding system env vars)",
                    env_path.display()
                );
            }
        } else {
            // Fallback: tenta carregar .env do diretório atual ou do workspace
            let _ = dotenvy::dotenv();
        }
    });
}

/// Tipo de banco de dados detectado
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DatabaseType {
    SqlServer,
    Sybase,
    PostgreSQL,
    MySQL,
    Oracle,
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
