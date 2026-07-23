use crate::engine::core::{
    ENGINE_DB2, ENGINE_MARIADB, ENGINE_MYSQL, ENGINE_ORACLE, ENGINE_POSTGRES, ENGINE_SQLSERVER,
    ENGINE_UNKNOWN,
};
use crate::error::{OdbcError, Result};
use crate::handles::CachedConnection;

use super::mssql::unsupported_sqlserver;
use super::oracle::{oracle_xa_block, oracle_xid_literal, ORACLE_XAER_NOTA, ORACLE_XA_RDONLY};
use super::xid::Xid;

/// Best-effort engine detection from a locked [`CachedConnection`].
///
/// Uses the per-connection `engine_id` cache (single `SQL_DBMS_NAME` on
/// first call). Falls back to [`ENGINE_UNKNOWN`] on any `SQLGetInfo`
/// failure so the SQL emitter returns a clean `UnsupportedFeature`.
pub(crate) fn detect_engine_id_cached(cached: &CachedConnection) -> &'static str {
    match cached.engine_id() {
        Ok(id) => id,
        Err(e) => {
            log::warn!(
                "XA detect_engine_id: SQLGetInfo failed ({e}); falling back to {ENGINE_UNKNOWN}"
            );
            ENGINE_UNKNOWN
        }
    }
}

pub(crate) fn apply_xa_start(
    conn: &mut odbc_api::Connection<'static>,
    engine_id: &str,
    xid: &Xid,
) -> Result<()> {
    match engine_id {
        ENGINE_POSTGRES => {
            // PostgreSQL has no `XA START` — every transaction is the
            // implicit branch. We still emit `BEGIN` to make the txn
            // boundary explicit (autocommit was turned off above).
            conn.execute("BEGIN", (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        ENGINE_MYSQL | ENGINE_MARIADB | ENGINE_DB2 => {
            let (g, b, f) = xid.encode_mysql_components();
            let sql = if b.is_empty() {
                format!("XA START '{}', '', {}", g, f)
            } else {
                format!("XA START '{}', '{}', {}", g, b, f)
            };
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        ENGINE_SQLSERVER => Err(unsupported_sqlserver()),
        ENGINE_ORACLE => {
            // DBMS_XA.XA_START(xid, TMNOFLAGS) attaches the current
            // session to a new branch. The PL/SQL helper wraps the
            // call in an exception-translating block so a non-zero rc
            // surfaces as an ODBC error instead of silently winning.
            let sql = oracle_xa_block(
                &format!(
                    "DBMS_XA.XA_START({}, DBMS_XA.TMNOFLAGS)",
                    oracle_xid_literal(xid),
                ),
                &[],
            );
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        _ => Err(unsupported_other(engine_id)),
    }
}

pub(crate) fn apply_xa_end(
    conn: &mut odbc_api::Connection<'static>,
    engine_id: &str,
    xid: &Xid,
) -> Result<()> {
    match engine_id {
        ENGINE_POSTGRES => {
            // No-op for PG — `xa_end` semantics are folded into
            // `xa_prepare` (PREPARE TRANSACTION ...).
            Ok(())
        }
        ENGINE_MYSQL | ENGINE_MARIADB | ENGINE_DB2 => {
            let (g, b, f) = xid.encode_mysql_components();
            let sql = if b.is_empty() {
                format!("XA END '{}', '', {}", g, f)
            } else {
                format!("XA END '{}', '{}', {}", g, b, f)
            };
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        ENGINE_SQLSERVER => Err(unsupported_sqlserver()),
        ENGINE_ORACLE => {
            // DBMS_XA.XA_END(xid, TMSUCCESS) detaches the session from
            // the branch. Required before XA_PREPARE per X/Open.
            let sql = oracle_xa_block(
                &format!(
                    "DBMS_XA.XA_END({}, DBMS_XA.TMSUCCESS)",
                    oracle_xid_literal(xid),
                ),
                &[],
            );
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        _ => Err(unsupported_other(engine_id)),
    }
}

pub(crate) fn apply_xa_prepare(
    conn: &mut odbc_api::Connection<'static>,
    engine_id: &str,
    xid: &Xid,
) -> Result<()> {
    match engine_id {
        ENGINE_POSTGRES => {
            let id = xid.encode_postgres();
            // PG identifier limit is much larger than our 1+128+padding
            // hex form so length is safe; the only risk is a single-quote
            // collision, which our hex encoding eliminates.
            let sql = format!("PREPARE TRANSACTION '{id}'");
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        ENGINE_MYSQL | ENGINE_MARIADB | ENGINE_DB2 => {
            let (g, b, f) = xid.encode_mysql_components();
            let sql = if b.is_empty() {
                format!("XA PREPARE '{}', '', {}", g, f)
            } else {
                format!("XA PREPARE '{}', '{}', {}", g, b, f)
            };
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        ENGINE_SQLSERVER => Err(unsupported_sqlserver()),
        ENGINE_ORACLE => {
            // DBMS_XA.XA_PREPARE(xid). Allowed extra rc: XA_RDONLY (3)
            // — Oracle uses it to signal "this branch did no DML, I
            // already auto-completed it; no commit/rollback needed".
            // We treat that as success at this layer; the subsequent
            // commit_prepared call will see XAER_NOTA and similarly
            // accept it. Tracking the read-only branch separately
            // would require a state-machine extension; the silent
            // accept matches X/Open's documented behaviour.
            let sql = oracle_xa_block(
                &format!("DBMS_XA.XA_PREPARE({})", oracle_xid_literal(xid)),
                &[ORACLE_XA_RDONLY],
            );
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        _ => Err(unsupported_other(engine_id)),
    }
}

pub(crate) fn apply_xa_commit(
    conn: &mut odbc_api::Connection<'static>,
    engine_id: &str,
    xid: &Xid,
    one_phase: bool,
) -> Result<()> {
    match engine_id {
        ENGINE_POSTGRES => {
            if one_phase {
                conn.execute("COMMIT", (), None)
                    .map(|_| ())
                    .map_err(OdbcError::from)
            } else {
                let sql = format!("COMMIT PREPARED '{}'", xid.encode_postgres());
                conn.execute(&sql, (), None)
                    .map(|_| ())
                    .map_err(OdbcError::from)
            }
        }
        ENGINE_MYSQL | ENGINE_MARIADB | ENGINE_DB2 => {
            let (g, b, f) = xid.encode_mysql_components();
            let suffix = if one_phase { " ONE PHASE" } else { "" };
            let sql = if b.is_empty() {
                format!("XA COMMIT '{}', '', {}{}", g, f, suffix)
            } else {
                format!("XA COMMIT '{}', '{}', {}{}", g, b, f, suffix)
            };
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        ENGINE_SQLSERVER => Err(unsupported_sqlserver()),
        ENGINE_ORACLE => {
            // DBMS_XA.XA_COMMIT(xid, onephase). For one_phase=true, we
            // also forgive XAER_PROTO (-6) which Oracle returns when
            // the branch was implicitly auto-committed (read-only DML
            // after start without prior end). Otherwise allow
            // XAER_NOTA (-4) so commit_prepared after a read-only
            // prepare is a no-op.
            let onephase_lit = if one_phase { "TRUE" } else { "FALSE" };
            let allow: &[i32] = if one_phase { &[] } else { &[ORACLE_XAER_NOTA] };
            let sql = oracle_xa_block(
                &format!(
                    "DBMS_XA.XA_COMMIT({}, {})",
                    oracle_xid_literal(xid),
                    onephase_lit,
                ),
                allow,
            );
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        _ => Err(unsupported_other(engine_id)),
    }
}

/// Roll back an **Active or Idle** branch (no PREPARE issued).
/// PG and the SQL-XA family handle these identically — there is no
/// prepare-log entry to clean up.
pub(crate) fn apply_xa_rollback(
    conn: &mut odbc_api::Connection<'static>,
    engine_id: &str,
    xid: &Xid,
) -> Result<()> {
    match engine_id {
        ENGINE_POSTGRES => conn
            .execute("ROLLBACK", (), None)
            .map(|_| ())
            .map_err(OdbcError::from),
        ENGINE_MYSQL | ENGINE_MARIADB | ENGINE_DB2 => {
            let (g, b, f) = xid.encode_mysql_components();
            let sql = if b.is_empty() {
                format!("XA ROLLBACK '{}', '', {}", g, f)
            } else {
                format!("XA ROLLBACK '{}', '{}', {}", g, b, f)
            };
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        ENGINE_SQLSERVER => Err(unsupported_sqlserver()),
        ENGINE_ORACLE => {
            // Active/Idle rollback: XA_END(TMSUCCESS) then XA_ROLLBACK.
            // We chain both in a single PL/SQL block so a network blip
            // can't strand the branch in the Idle state.
            let xid_lit = oracle_xid_literal(xid);
            let sql = format!(
                "BEGIN DECLARE rc PLS_INTEGER; BEGIN \
                   rc := DBMS_XA.XA_END({xid}, DBMS_XA.TMSUCCESS); \
                   IF rc <> 0 THEN RAISE_APPLICATION_ERROR(-20100, 'DBMS_XA xa_end rc=' || rc); END IF; \
                   rc := DBMS_XA.XA_ROLLBACK({xid}); \
                   IF rc <> 0 THEN RAISE_APPLICATION_ERROR(-20101, 'DBMS_XA xa_rollback rc=' || rc); END IF; \
                 END; END;",
                xid = xid_lit,
            );
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        _ => Err(unsupported_other(engine_id)),
    }
}

/// Roll back a **Prepared** branch (Phase 2 rollback). PostgreSQL
/// requires `ROLLBACK PREPARED '<xid>'` because the prepare log entry
/// outlives the connection. MySQL/MariaDB/DB2 use the same `XA
/// ROLLBACK` grammar regardless of state — the engine recognises the
/// xid is already prepared and does the right thing.
pub(crate) fn apply_xa_rollback_prepared(
    conn: &mut odbc_api::Connection<'static>,
    engine_id: &str,
    xid: &Xid,
) -> Result<()> {
    match engine_id {
        ENGINE_POSTGRES => {
            let sql = format!("ROLLBACK PREPARED '{}'", xid.encode_postgres());
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        ENGINE_MYSQL | ENGINE_MARIADB | ENGINE_DB2 => {
            // Same as plain xa_rollback for these engines.
            apply_xa_rollback(conn, engine_id, xid)
        }
        ENGINE_SQLSERVER => Err(unsupported_sqlserver()),
        ENGINE_ORACLE => {
            // Prepared rollback: only XA_ROLLBACK; XA_END was already
            // emitted by `xa_prepare`. Allow XAER_NOTA so a follow-up
            // recovery sweep on a branch that read-only-prepared
            // (Oracle auto-completed it) is a no-op.
            let sql = oracle_xa_block(
                &format!("DBMS_XA.XA_ROLLBACK({})", oracle_xid_literal(xid)),
                &[ORACLE_XAER_NOTA],
            );
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        _ => Err(unsupported_other(engine_id)),
    }
}

pub(crate) fn apply_xa_recover(
    conn: &mut odbc_api::Connection<'static>,
    engine_id: &str,
) -> Result<Vec<Xid>> {
    match engine_id {
        ENGINE_POSTGRES => {
            // Read the gid column from pg_prepared_xacts. Only XIDs
            // produced by `Xid::encode_postgres` round-trip; others
            // are skipped silently (they belong to a different
            // client).
            let mut out = Vec::new();
            let cursor = conn
                .execute("SELECT gid FROM pg_prepared_xacts", (), None)
                .map_err(OdbcError::from)?;
            if let Some(mut cursor) = cursor {
                use odbc_api::Cursor;
                while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
                    let mut buf: Vec<u8> = Vec::new();
                    if row.get_text(1, &mut buf).map_err(OdbcError::from)? {
                        if let Ok(s) = std::str::from_utf8(&buf) {
                            if let Some(xid) = Xid::decode_postgres(s) {
                                out.push(xid);
                            }
                        }
                    }
                }
            }
            Ok(out)
        }
        ENGINE_MYSQL | ENGINE_MARIADB | ENGINE_DB2 => {
            // XA RECOVER returns: formatID, gtrid_length, bqual_length, data.
            // The `data` column carries gtrid concatenated with bqual,
            // both raw bytes. Our `apply_xa_start` always hex-encoded
            // them, so the bytes coming back here are ASCII hex.
            let mut out = Vec::new();
            let cursor = conn
                .execute("XA RECOVER", (), None)
                .map_err(OdbcError::from)?;
            if let Some(mut cursor) = cursor {
                use odbc_api::Cursor;
                while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
                    let mut format_id_buf: Vec<u8> = Vec::new();
                    let mut gtrid_len_buf: Vec<u8> = Vec::new();
                    let mut bqual_len_buf: Vec<u8> = Vec::new();
                    let mut data_buf: Vec<u8> = Vec::new();
                    let _ = row
                        .get_text(1, &mut format_id_buf)
                        .map_err(OdbcError::from)?;
                    let _ = row
                        .get_text(2, &mut gtrid_len_buf)
                        .map_err(OdbcError::from)?;
                    let _ = row
                        .get_text(3, &mut bqual_len_buf)
                        .map_err(OdbcError::from)?;
                    let _ = row.get_text(4, &mut data_buf).map_err(OdbcError::from)?;
                    let format_id: i32 = parse_ascii_int(&format_id_buf).unwrap_or(0);
                    let gtrid_len: usize = parse_ascii_int::<usize>(&gtrid_len_buf).unwrap_or(0);
                    let bqual_len: usize = parse_ascii_int::<usize>(&bqual_len_buf).unwrap_or(0);
                    if data_buf.len() < gtrid_len + bqual_len {
                        continue;
                    }
                    // Our encoding was hex strings; the engine returns
                    // them as ASCII data. Each component arrives at
                    // 2× original length because we hex-encoded.
                    let g_hex = std::str::from_utf8(&data_buf[..gtrid_len]).ok();
                    let b_hex =
                        std::str::from_utf8(&data_buf[gtrid_len..gtrid_len + bqual_len]).ok();
                    if let (Some(g), Some(b)) = (g_hex, b_hex) {
                        if let Some(xid) = Xid::decode_mysql_components(g, b, format_id) {
                            out.push(xid);
                        }
                    }
                }
            }
            Ok(out)
        }
        ENGINE_SQLSERVER => Err(unsupported_sqlserver()),
        ENGINE_ORACLE => {
            // Oracle exposes prepared XIDs via DBA_PENDING_TRANSACTIONS
            // (FORMATID NUMBER, GLOBALID RAW(64), BRANCHID RAW(64)).
            // We RAWTOHEX both binary columns so the ODBC driver
            // returns ASCII (round-trips with our HEXTORAW literals on
            // start). XIDs we can't decode (different application's
            // format) are skipped silently.
            let mut out = Vec::new();
            let cursor = conn
                .execute(
                    "SELECT FORMATID, RAWTOHEX(GLOBALID), RAWTOHEX(BRANCHID) \
                     FROM DBA_PENDING_TRANSACTIONS",
                    (),
                    None,
                )
                .map_err(OdbcError::from)?;
            if let Some(mut cursor) = cursor {
                use odbc_api::Cursor;
                while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
                    let mut format_id_buf: Vec<u8> = Vec::new();
                    let mut globalid_buf: Vec<u8> = Vec::new();
                    let mut branchid_buf: Vec<u8> = Vec::new();
                    let _ = row
                        .get_text(1, &mut format_id_buf)
                        .map_err(OdbcError::from)?;
                    let _ = row
                        .get_text(2, &mut globalid_buf)
                        .map_err(OdbcError::from)?;
                    let _ = row
                        .get_text(3, &mut branchid_buf)
                        .map_err(OdbcError::from)?;
                    let format_id: i32 = parse_ascii_int(&format_id_buf).unwrap_or(0);
                    let globalid_hex = std::str::from_utf8(&globalid_buf).unwrap_or("");
                    let branchid_hex = std::str::from_utf8(&branchid_buf).unwrap_or("");
                    if let Some(xid) =
                        Xid::decode_oracle_components(format_id, globalid_hex, branchid_hex)
                    {
                        out.push(xid);
                    }
                }
            }
            Ok(out)
        }
        _ => Err(unsupported_other(engine_id)),
    }
}

pub(crate) fn parse_ascii_int<T: std::str::FromStr>(bytes: &[u8]) -> Option<T> {
    std::str::from_utf8(bytes).ok()?.trim().parse::<T>().ok()
}

pub(crate) fn unsupported_other(engine_id: &str) -> OdbcError {
    OdbcError::UnsupportedFeature(format!(
        "XA / 2PC is not supported on engine {:?}. Supported engines: \
         postgres, mysql, mariadb, db2, oracle (via DBMS_XA). SQL Server \
         requires MSDTC enlistment (Windows + xa-dtc feature; advanced \
         recovery is operational scope).",
        engine_id,
    ))
}
