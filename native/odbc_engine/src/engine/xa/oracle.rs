use super::xid::Xid;

/// Build a `SYS.DBMS_XA_XID(formatid, HEXTORAW('gtrid'), HEXTORAW('bqual'))`
/// constructor literal. The hex form is uppercase to round-trip with
/// Oracle's `RAWTOHEX` output in `DBA_PENDING_TRANSACTIONS`.
pub(crate) fn oracle_xid_literal(xid: &Xid) -> String {
    let (fmt, g, b) = xid.encode_oracle_components();
    format!(
        "SYS.DBMS_XA_XID({fmt}, HEXTORAW('{g}'), HEXTORAW('{b}'))",
        fmt = fmt,
        g = g,
        b = b,
    )
}

/// Wrap a single `DBMS_XA.*` call in a PL/SQL block that converts a
/// non-zero return code into an `ORA-20100`. Optionally tolerates
/// specific extra return codes (the typical case is `XA_RDONLY=3` on
/// `XA_PREPARE`, where the branch did no DML and is auto-completed).
///
/// The block prefixes the surfaced rc with a sentinel marker the
/// caller can grep for; the engine_id is included so the error path
/// makes the source obvious in a multi-RM transaction.
pub(crate) fn oracle_xa_block(call: &str, allow_rcs: &[i32]) -> String {
    // Build an `IF rc <> 0 AND rc <> R1 AND rc <> R2 ... THEN raise`
    // guard. Empty allow_rcs collapses to `IF rc <> 0 THEN raise` so
    // any non-zero return is fatal. The PL/SQL block converts the
    // surfaced rc into ORA-20100 so the ODBC error path is uniform.
    let mut allow_clause = String::new();
    for rc in allow_rcs {
        allow_clause.push_str(&format!(" AND rc <> {}", rc));
    }
    format!(
        "BEGIN DECLARE rc PLS_INTEGER; BEGIN rc := {call}; \
         IF rc <> 0{allow_clause} THEN \
           RAISE_APPLICATION_ERROR(-20100, 'DBMS_XA rc=' || rc); \
         END IF; END; END;",
        call = call,
        allow_clause = allow_clause,
    )
}

/// `XA_RDONLY = 3` — the branch did no DML and is auto-completed.
pub(crate) const ORACLE_XA_RDONLY: i32 = 3;

/// `XAER_NOTA = -4` (the xid is not in the engine's known set).
/// Surfaces after a read-only `XA_PREPARE` (rc=3) auto-completes the
/// branch — Oracle silently drops it so the subsequent `XA_COMMIT`
/// can't find it. We treat both paths as success at the
/// [`super::transaction::XaTransaction`] layer; see `apply_xa_prepare` for context.
#[allow(
    dead_code,
    reason = "Reserved for Oracle XA read-only prepare path; ODBC-ENG-423; remove by 2026-09-30."
)]
pub(crate) const ORACLE_XAER_NOTA: i32 = -4;
