//! Session-scoped attribute defaults restored after local transactions
//! and pool checkin (lock-timeout overrides, etc.).

use crate::engine::core::{
    ENGINE_DB2, ENGINE_MARIADB, ENGINE_MYSQL, ENGINE_SQLITE, ENGINE_SQLSERVER,
};

/// Returns `true` when lock-timeout overrides are session-scoped and must be
/// reset after the transaction (or on pool checkin). PostgreSQL uses
/// `SET LOCAL` and auto-resets with the txn — not session-scoped.
pub(crate) fn lock_timeout_is_session_scoped(engine_id: &str) -> bool {
    matches!(
        engine_id,
        ENGINE_SQLSERVER | ENGINE_MYSQL | ENGINE_MARIADB | ENGINE_DB2 | ENGINE_SQLITE
    )
}

/// SQL that restores the documented engine default after a session-scoped
/// lock-timeout override. `None` for engines that do not need a reset
/// (PostgreSQL `SET LOCAL`, Oracle/Snowflake no-op).
pub(crate) fn session_lock_timeout_reset_sql(engine_id: &str) -> Option<&'static str> {
    match engine_id {
        ENGINE_SQLSERVER => Some("SET LOCK_TIMEOUT -1"),
        ENGINE_MYSQL | ENGINE_MARIADB => Some("SET SESSION innodb_lock_wait_timeout = 50"),
        ENGINE_SQLITE => Some("PRAGMA busy_timeout = 0"),
        ENGINE_DB2 => Some("SET CURRENT LOCK TIMEOUT NULL"),
        _ => None,
    }
}

/// SQL Server, SQLite and DB2 apply these isolation settings to the session,
/// so a pooled connection must restore the documented engine default.
pub(crate) fn session_isolation_reset_sql(engine_id: &str) -> Option<&'static str> {
    match engine_id {
        ENGINE_SQLSERVER => Some("SET TRANSACTION ISOLATION LEVEL READ COMMITTED"),
        ENGINE_SQLITE => Some("PRAGMA read_uncommitted = 0"),
        ENGINE_DB2 => Some("SET CURRENT ISOLATION = CS"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::core::{ENGINE_MYSQL, ENGINE_POSTGRES};

    #[test]
    fn only_session_scoped_isolation_has_reset_sql() {
        assert_eq!(
            session_isolation_reset_sql(ENGINE_SQLSERVER),
            Some("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
        );
        assert_eq!(
            session_isolation_reset_sql(ENGINE_SQLITE),
            Some("PRAGMA read_uncommitted = 0")
        );
        assert_eq!(
            session_isolation_reset_sql(ENGINE_DB2),
            Some("SET CURRENT ISOLATION = CS")
        );
        assert_eq!(session_isolation_reset_sql(ENGINE_POSTGRES), None);
        assert_eq!(session_isolation_reset_sql(ENGINE_MYSQL), None);
    }
}
