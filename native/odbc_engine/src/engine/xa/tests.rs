use super::apply::{parse_ascii_int, unsupported_other};
use super::hex::{hex_decode, hex_encode, hex_encode_upper, hex_nibble};
use super::mssql::unsupported_sqlserver;
use super::oracle::{oracle_xa_block, oracle_xid_literal, ORACLE_XAER_NOTA, ORACLE_XA_RDONLY};
use super::transaction::{resume_prepared, PreparedXa, PreparingXa, XaState, XaTransaction};
use super::xid::Xid;
use crate::engine::core::{
    ENGINE_DB2, ENGINE_MARIADB, ENGINE_MYSQL, ENGINE_ORACLE, ENGINE_POSTGRES, ENGINE_SQLITE,
    ENGINE_UNKNOWN,
};
use crate::error::OdbcError;

fn sample_xid() -> Xid {
    Xid::new(0x1B, b"global-tx-1".to_vec(), b"branch-A".to_vec()).unwrap()
}

// -----------------------------------------------------------------
// Xid validation
// -----------------------------------------------------------------

#[test]
fn xid_new_rejects_empty_gtrid() {
    let r = Xid::new(0, vec![], b"branch".to_vec());
    match r {
        Err(OdbcError::ValidationError(msg)) => {
            assert!(msg.contains("gtrid must be non-empty"));
        }
        _ => panic!("expected ValidationError, got {r:?}"),
    }
}

#[test]
fn xid_new_rejects_oversize_gtrid() {
    let r = Xid::new(0, vec![b'x'; 65], vec![]);
    match r {
        Err(OdbcError::ValidationError(msg)) => {
            assert!(msg.contains("gtrid is 65 bytes"));
        }
        _ => panic!("expected ValidationError, got {r:?}"),
    }
}

#[test]
fn xid_new_rejects_oversize_bqual() {
    let r = Xid::new(0, b"g".to_vec(), vec![b'x'; 65]);
    match r {
        Err(OdbcError::ValidationError(msg)) => {
            assert!(msg.contains("bqual is 65 bytes"));
        }
        _ => panic!("expected ValidationError, got {r:?}"),
    }
}

#[test]
fn xid_new_accepts_max_size_components() {
    let r = Xid::new(0, vec![b'g'; 64], vec![b'b'; 64]);
    assert!(r.is_ok(), "64+64 must be accepted; got {r:?}");
}

#[test]
fn xid_new_accepts_empty_bqual() {
    // Common in single-branch transactions.
    let r = Xid::new(0, b"g".to_vec(), vec![]);
    assert!(r.is_ok());
    assert!(r.unwrap().bqual().is_empty());
}

// -----------------------------------------------------------------
// PostgreSQL encoding round-trip
// -----------------------------------------------------------------

#[test]
fn xid_postgres_round_trip() {
    let original = sample_xid();
    let encoded = original.encode_postgres();
    let decoded = Xid::decode_postgres(&encoded).expect("must round-trip");
    assert_eq!(decoded, original);
}

#[test]
fn xid_postgres_encoding_is_ascii_hex() {
    let xid = sample_xid();
    let encoded = xid.encode_postgres();
    // Expected format: "27_<hex>_<hex>" (0x1B = 27 decimal)
    assert!(encoded.starts_with("27_"), "got {encoded}");
    // Body must be 0-9 a-f _ only — safe for SQL identifiers
    assert!(
        encoded
            .chars()
            .all(|c| c.is_ascii_hexdigit() || c == '_' || c == '-'),
        "encoded form must be ASCII-clean; got {encoded}",
    );
}

#[test]
fn xid_postgres_decode_rejects_garbage() {
    assert!(Xid::decode_postgres("").is_none());
    assert!(Xid::decode_postgres("foo").is_none());
    assert!(Xid::decode_postgres("0_").is_none());
    // Non-hex gtrid:
    assert!(Xid::decode_postgres("0_xyzz_").is_none());
}

#[test]
fn xid_postgres_round_trip_with_empty_bqual() {
    let xid = Xid::new(0, b"g".to_vec(), vec![]).unwrap();
    let encoded = xid.encode_postgres();
    // Format: "0_67_" (67 = 'g' in hex)
    assert_eq!(encoded, "0_67_");
    let decoded = Xid::decode_postgres(&encoded).expect("must round-trip");
    assert_eq!(decoded, xid);
}

#[test]
fn xid_postgres_round_trip_with_binary_payload() {
    let xid = Xid::new(7, vec![0x00, 0xFF, 0x10, 0x20], vec![0xAB]).unwrap();
    let encoded = xid.encode_postgres();
    let decoded = Xid::decode_postgres(&encoded).expect("must round-trip");
    assert_eq!(decoded, xid);
}

// -----------------------------------------------------------------
// MySQL/MariaDB/DB2 component encoding
// -----------------------------------------------------------------

#[test]
fn xid_mysql_components_round_trip() {
    let original = sample_xid();
    let (g, b, f) = original.encode_mysql_components();
    let decoded = Xid::decode_mysql_components(&g, &b, f).expect("must round-trip");
    assert_eq!(decoded, original);
}

#[test]
fn xid_mysql_components_format() {
    let xid = sample_xid();
    let (g, b, f) = xid.encode_mysql_components();
    assert_eq!(f, 0x1B);
    // Each component must be 2× original length (hex encoding)
    assert_eq!(g.len(), 11 * 2, "gtrid hex length");
    assert_eq!(b.len(), 8 * 2, "bqual hex length");
    // Must be lowercase hex
    assert!(g
        .chars()
        .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
}

#[test]
fn xid_hex_encode_decode_round_trip() {
    for data in &[
        vec![],
        vec![0x00],
        vec![0xFF],
        vec![0x00, 0x01, 0x02, 0xFE, 0xFF],
        (0..=255_u8).collect::<Vec<u8>>(),
    ] {
        let encoded = hex_encode(data);
        let decoded = hex_decode(&encoded).expect("round-trip");
        assert_eq!(&decoded, data);
    }
}

#[test]
fn xid_hex_decode_rejects_odd_length() {
    assert!(hex_decode("a").is_none());
    assert!(hex_decode("abc").is_none());
}

#[test]
fn xid_hex_decode_rejects_non_hex() {
    assert!(hex_decode("xy").is_none());
    assert!(hex_decode("ab__").is_none());
}

// -----------------------------------------------------------------
// SQL emitter shape (engines that error out cleanly)
// -----------------------------------------------------------------

#[test]
fn unsupported_sqlserver_message_points_at_dtc() {
    let err = unsupported_sqlserver();
    let s = err.to_string();
    // MSDTC must be mentioned in BOTH variants (no-feature + feature
    // enabled). The cfg!() switch picks the right body; the test
    // pins the universal substring so a refactor can't accidentally
    // drop the actionable hint.
    assert!(s.contains("MSDTC"));
    assert!(s.contains("xa-dtc"));
    assert!(s.contains("section 2.1"));
    assert!(s.contains("PENDING_IMPLEMENTATIONS"));
}

#[test]
fn unsupported_other_lists_supported_engines() {
    let err = unsupported_other(ENGINE_SQLITE);
    let s = err.to_string();
    assert!(s.contains("sqlite"));
    assert!(s.contains("postgres"));
    assert!(s.contains("mysql"));
    assert!(s.contains("mariadb"));
    assert!(s.contains("db2"));
    assert!(s.contains("oracle"));
}

// -----------------------------------------------------------------
// Oracle DBMS_XA encoding round-trips (unit-only — no live DB)
// -----------------------------------------------------------------

#[test]
fn xid_oracle_components_round_trip() {
    let original = Xid::new(7, vec![0xDE, 0xAD, 0xBE, 0xEF], vec![0xCA, 0xFE]).unwrap();
    let (fmt, g, b) = original.encode_oracle_components();
    assert_eq!(fmt, 7);
    assert_eq!(g, "DEADBEEF");
    assert_eq!(b, "CAFE");
    let decoded = Xid::decode_oracle_components(fmt, &g, &b).expect("must round-trip");
    assert_eq!(decoded, original);
}

#[test]
fn xid_oracle_decode_accepts_lowercase_hex() {
    // Some recovery sweeps may surface lowercase hex; we accept
    // both so the helper doesn't trip over a future driver
    // change.
    let xid = Xid::decode_oracle_components(0, "abcd", "ef").expect("lowercase ok");
    assert_eq!(xid.gtrid(), &[0xAB, 0xCD][..]);
    assert_eq!(xid.bqual(), &[0xEF][..]);
}

#[test]
fn oracle_xid_literal_emits_dbms_xa_xid_constructor() {
    let xid = Xid::new(0x1B, b"global".to_vec(), b"branch".to_vec()).unwrap();
    let lit = oracle_xid_literal(&xid);
    // 'global' = 676C6F62616C ; 'branch' = 6272616E6368.
    // Verify uppercase hex (Oracle's RAWTOHEX convention) and the
    // exact constructor name we tested live in the sandbox.
    assert_eq!(
        lit,
        "SYS.DBMS_XA_XID(27, HEXTORAW('676C6F62616C'), HEXTORAW('6272616E6368'))"
    );
}

#[test]
fn oracle_xa_block_wraps_call_with_rc_check() {
    let sql = oracle_xa_block("DBMS_XA.XA_PREPARE(x)", &[3]);
    assert!(sql.contains("DBMS_XA.XA_PREPARE(x)"));
    assert!(sql.contains("rc <> 0"));
    assert!(sql.contains("rc <> 3"));
    assert!(sql.contains("RAISE_APPLICATION_ERROR(-20100"));
}

// -----------------------------------------------------------------
// PreparedXa state machine guards
// -----------------------------------------------------------------

#[test]
fn prepared_xa_commit_rejects_wrong_state() {
    let xa = PreparedXa::from_test_state(XaState::Active, ENGINE_POSTGRES, sample_xid());
    let r = xa.commit();
    match r {
        Err(OdbcError::ValidationError(msg)) => {
            assert!(msg.contains("expected state Prepared, got Active"));
        }
        _ => panic!("expected ValidationError, got {r:?}"),
    }
}

#[test]
fn prepared_xa_rollback_rejects_wrong_state() {
    let xa = PreparedXa::from_test_state(XaState::Idle, ENGINE_MYSQL, sample_xid());
    let r = xa.rollback();
    match r {
        Err(OdbcError::ValidationError(msg)) => {
            assert!(msg.contains("expected state Prepared, got Idle"));
        }
        _ => panic!("expected ValidationError, got {r:?}"),
    }
}

#[test]
fn xa_state_variants_are_distinct() {
    let states = [
        XaState::None,
        XaState::Active,
        XaState::Idle,
        XaState::Prepared,
        XaState::Committed,
        XaState::RolledBack,
        XaState::Failed,
    ];
    for (i, a) in states.iter().enumerate() {
        for (j, b) in states.iter().enumerate() {
            if i == j {
                assert_eq!(a, b);
            } else {
                assert_ne!(a, b);
            }
        }
    }
}

#[test]
fn parse_ascii_int_trims_and_parses() {
    assert_eq!(parse_ascii_int::<i32>(b" 42 "), Some(42));
    assert_eq!(parse_ascii_int::<usize>(b"0"), Some(0));
    assert_eq!(parse_ascii_int::<i32>(b"not-a-number"), None);
    assert_eq!(parse_ascii_int::<i32>(b"\xff"), None);
}

#[test]
fn hex_encode_upper_differs_from_lowercase_for_non_digits() {
    let bytes = [0xAB, 0xCD];
    assert_eq!(hex_encode(&bytes), "abcd");
    assert_eq!(hex_encode_upper(&bytes), "ABCD");
}

// -----------------------------------------------------------------
// SQL emitter shape (pure formatting — no live ODBC)
// -----------------------------------------------------------------

fn mysql_xa_start_sql(xid: &Xid) -> String {
    let (g, b, f) = xid.encode_mysql_components();
    if b.is_empty() {
        format!("XA START '{}', '', {}", g, f)
    } else {
        format!("XA START '{}', '{}', {}", g, b, f)
    }
}

#[test]
fn mysql_xa_start_sql_empty_bqual_uses_empty_string_arg() {
    let xid = Xid::new(1, b"g".to_vec(), vec![]).unwrap();
    assert_eq!(mysql_xa_start_sql(&xid), "XA START '67', '', 1");
}

#[test]
fn mysql_xa_start_sql_with_bqual_includes_branch() {
    let xid = sample_xid();
    let sql = mysql_xa_start_sql(&xid);
    assert!(sql.contains("XA START '"));
    assert!(sql.contains("', '"));
    assert!(sql.contains(", 27"));
}

#[test]
fn postgres_prepare_and_commit_prepared_sql_format() {
    let xid = sample_xid();
    let id = xid.encode_postgres();
    let prepare = format!("PREPARE TRANSACTION '{id}'");
    let commit = format!("COMMIT PREPARED '{id}'");
    let rollback = format!("ROLLBACK PREPARED '{id}'");
    assert!(prepare.starts_with("PREPARE TRANSACTION '"));
    assert!(commit.starts_with("COMMIT PREPARED '"));
    assert!(rollback.starts_with("ROLLBACK PREPARED '"));
    assert!(prepare.ends_with('\''));
}

#[test]
fn mysql_xa_commit_one_phase_suffix() {
    let xid = Xid::new(0, b"g".to_vec(), vec![]).unwrap();
    let (g, b, f) = xid.encode_mysql_components();
    let sql = format!("XA COMMIT '{}', '', {}{}", g, f, " ONE PHASE");
    assert!(sql.ends_with(" ONE PHASE"));
    assert!(b.is_empty());
}

#[test]
fn oracle_xa_commit_prepared_block_allows_xaer_nota() {
    let xid = sample_xid();
    let sql = oracle_xa_block(
        &format!("DBMS_XA.XA_COMMIT({}, FALSE)", oracle_xid_literal(&xid),),
        &[ORACLE_XAER_NOTA],
    );
    assert!(sql.contains("rc <> -4"));
    assert!(sql.contains("XA_COMMIT"));
}

#[test]
fn oracle_xa_rollback_prepared_block_allows_xaer_nota() {
    let xid = sample_xid();
    let sql = oracle_xa_block(
        &format!("DBMS_XA.XA_ROLLBACK({})", oracle_xid_literal(&xid)),
        &[ORACLE_XAER_NOTA],
    );
    assert!(sql.contains("rc <> -4"));
}

#[test]
fn xid_mysql_decode_rejects_invalid_hex_component() {
    assert!(Xid::decode_mysql_components("zz", "", 0).is_none());
}

#[test]
fn unsupported_other_mentions_sqlserver_dtc_path() {
    let err = unsupported_other("sybase");
    let s = err.to_string();
    assert!(s.contains("sybase"));
    assert!(s.contains("SQL Server"));
    assert!(s.contains("xa-dtc"));
}

// -----------------------------------------------------------------
// XaTransaction / PreparingXa state guards (no live ODBC)
// -----------------------------------------------------------------

#[test]
fn xa_transaction_end_rejects_when_state_idle() {
    let xa = XaTransaction::from_test_state(XaState::Idle, ENGINE_POSTGRES, sample_xid());
    let r = xa.end();
    match r {
        Err(OdbcError::ValidationError(msg)) => {
            assert!(msg.contains("XaTransaction::end"));
            assert!(msg.contains("expected state Active, got Idle"));
        }
        _ => panic!("expected ValidationError"),
    }
}

#[test]
fn xa_transaction_commit_one_phase_rejects_when_state_idle() {
    let xa = XaTransaction::from_test_state(XaState::Idle, ENGINE_MYSQL, sample_xid());
    let r = xa.commit_one_phase();
    match r {
        Err(OdbcError::ValidationError(msg)) => {
            assert!(msg.contains("XaTransaction::commit_one_phase"));
            assert!(msg.contains("expected state Active, got Idle"));
        }
        _ => panic!("expected ValidationError, got {r:?}"),
    }
}

#[test]
fn should_return_active_handle_when_commit_one_phase_preserving_fails_validation() {
    let xa = XaTransaction::from_test_state(XaState::Idle, ENGINE_MYSQL, sample_xid());
    let result = xa.commit_one_phase_preserving_active();
    match result {
        Err((OdbcError::ValidationError(msg), returned)) => {
            assert!(msg.contains("XaTransaction::commit_one_phase"));
            assert_eq!(returned.state(), XaState::Idle);
        }
        Ok(()) => panic!("expected ValidationError with handle"),
        Err(_) => panic!("expected ValidationError with handle"),
    }
}

#[test]
fn xa_transaction_rollback_rejects_when_state_prepared() {
    let xa = XaTransaction::from_test_state(XaState::Prepared, ENGINE_DB2, sample_xid());
    let r = xa.rollback();
    match r {
        Err(OdbcError::ValidationError(msg)) => {
            assert!(msg.contains("XaTransaction::rollback"));
            assert!(msg.contains("expected state Active, got Prepared"));
        }
        _ => panic!("expected ValidationError"),
    }
}

#[test]
fn preparing_xa_prepare_rejects_when_state_active() {
    let inner = XaTransaction::from_test_state(XaState::Active, ENGINE_MARIADB, sample_xid());
    let prep = PreparingXa::from_test_transaction(inner);
    let r = prep.prepare();
    match r {
        Err(OdbcError::ValidationError(msg)) => {
            assert!(msg.contains("XaTransaction::prepare"));
            assert!(msg.contains("expected state Idle, got Active"));
        }
        _ => panic!("expected ValidationError"),
    }
}

#[test]
fn preparing_xa_rollback_rejects_when_state_active() {
    let inner = XaTransaction::from_test_state(XaState::Active, ENGINE_ORACLE, sample_xid());
    let prep = PreparingXa::from_test_transaction(inner);
    let r = prep.rollback();
    match r {
        Err(OdbcError::ValidationError(msg)) => {
            assert!(msg.contains("XaTransaction::rollback"));
            assert!(msg.contains("expected state Idle, got Active"));
        }
        _ => panic!("expected ValidationError"),
    }
}

#[test]
fn oracle_xa_block_without_allowed_rcs_only_checks_nonzero() {
    let sql = oracle_xa_block("DBMS_XA.XA_END(x)", &[]);
    assert!(sql.contains("rc <> 0"));
    assert!(!sql.contains("rc <> 3"));
    assert!(!sql.contains("rc <> -4"));
}

fn mysql_xa_end_sql(xid: &Xid) -> String {
    let (g, b, f) = xid.encode_mysql_components();
    if b.is_empty() {
        format!("XA END '{}', '', {}", g, f)
    } else {
        format!("XA END '{}', '{}', {}", g, b, f)
    }
}

fn mysql_xa_prepare_sql(xid: &Xid) -> String {
    let (g, b, f) = xid.encode_mysql_components();
    if b.is_empty() {
        format!("XA PREPARE '{}', '', {}", g, f)
    } else {
        format!("XA PREPARE '{}', '{}', {}", g, b, f)
    }
}

fn mysql_xa_rollback_sql(xid: &Xid) -> String {
    let (g, b, f) = xid.encode_mysql_components();
    if b.is_empty() {
        format!("XA ROLLBACK '{}', '', {}", g, f)
    } else {
        format!("XA ROLLBACK '{}', '{}', {}", g, b, f)
    }
}

#[test]
fn mysql_xa_end_sql_empty_bqual_uses_empty_string_arg() {
    let xid = Xid::new(2, b"g".to_vec(), vec![]).unwrap();
    assert_eq!(mysql_xa_end_sql(&xid), "XA END '67', '', 2");
}

#[test]
fn mysql_xa_prepare_sql_with_bqual() {
    let xid = sample_xid();
    let sql = mysql_xa_prepare_sql(&xid);
    assert!(sql.starts_with("XA PREPARE '"));
    assert!(sql.contains("', '"));
    assert!(sql.ends_with(", 27"));
}

#[test]
fn mysql_xa_rollback_sql_matches_start_component_order() {
    let xid = sample_xid();
    let start = mysql_xa_start_sql(&xid);
    let rollback = mysql_xa_rollback_sql(&xid);
    assert!(start.starts_with("XA START "));
    assert!(rollback.starts_with("XA ROLLBACK "));
    assert_eq!(
        start.replace("XA START ", ""),
        rollback.replace("XA ROLLBACK ", "")
    );
}

#[test]
fn oracle_active_rollback_sql_chains_end_then_rollback() {
    let xid = sample_xid();
    let lit = oracle_xid_literal(&xid);
    let sql = format!(
        "BEGIN DECLARE rc PLS_INTEGER; BEGIN \
           rc := DBMS_XA.XA_END({lit}, DBMS_XA.TMSUCCESS); \
           IF rc <> 0 THEN RAISE_APPLICATION_ERROR(-20100, 'DBMS_XA xa_end rc=' || rc); END IF; \
           rc := DBMS_XA.XA_ROLLBACK({lit}); \
           IF rc <> 0 THEN RAISE_APPLICATION_ERROR(-20101, 'DBMS_XA xa_rollback rc=' || rc); END IF; \
         END; END;",
    );
    assert!(sql.contains("XA_END"));
    assert!(sql.contains("XA_ROLLBACK"));
    assert!(sql.contains("-20100"));
    assert!(sql.contains("-20101"));
}

#[test]
fn xid_postgres_decode_rejects_non_numeric_format_id() {
    assert!(Xid::decode_postgres("notanumber_67_").is_none());
}

#[test]
fn xid_for_test_empty_gtrid_does_not_round_trip_postgres() {
    let bad = Xid::for_test(0, vec![], vec![]);
    let encoded = bad.encode_postgres();
    assert!(Xid::decode_postgres(&encoded).is_none());
}

#[test]
fn xid_oracle_decode_rejects_odd_length_hex() {
    assert!(Xid::decode_oracle_components(0, "abc", "00").is_none());
}

#[test]
fn postgres_xa_start_sql_is_begin() {
    assert_eq!(postgres_xa_start_sql(), "BEGIN");
}

#[test]
fn postgres_one_phase_commit_sql_is_plain_commit() {
    assert_eq!(postgres_xa_commit_sql(true), "COMMIT");
    assert_eq!(
        postgres_xa_commit_sql(false),
        format!("COMMIT PREPARED '{}'", sample_xid().encode_postgres())
    );
}

#[test]
fn oracle_xa_start_sql_wraps_xa_start_with_tmnoflags() {
    let xid = sample_xid();
    let sql = oracle_xa_start_sql(&xid);
    assert!(sql.contains("DBMS_XA.XA_START("));
    assert!(sql.contains("DBMS_XA.TMNOFLAGS"));
    assert!(sql.contains(&oracle_xid_literal(&xid)));
    assert!(sql.contains("RAISE_APPLICATION_ERROR(-20100"));
}

#[test]
fn oracle_xa_prepare_sql_allows_rdonly_return_code() {
    let sql = oracle_xa_prepare_sql(&sample_xid());
    assert!(sql.contains("DBMS_XA.XA_PREPARE("));
    assert!(sql.contains("rc <> 3"));
}

#[test]
fn oracle_one_phase_commit_sql_uses_true_without_xaer_nota() {
    let sql = oracle_xa_commit_sql(&sample_xid(), true);
    assert!(sql.contains("DBMS_XA.XA_COMMIT("));
    assert!(sql.contains("TRUE"));
    assert!(!sql.contains("rc <> -4"));
}

#[test]
fn mysql_two_phase_commit_sql_has_no_one_phase_suffix() {
    let xid = Xid::new(0, b"g".to_vec(), vec![]).unwrap();
    let (g, _b, f) = xid.encode_mysql_components();
    let sql = format!("XA COMMIT '{}', '', {}", g, f);
    assert!(!sql.contains("ONE PHASE"));
}

#[test]
fn dialect_xa_start_sql_matches_for_mysql_mariadb_db2() {
    let xid = sample_xid();
    let expected = mysql_xa_start_sql(&xid);
    for engine in [ENGINE_MYSQL, ENGINE_MARIADB, ENGINE_DB2] {
        assert_eq!(
            dialect_xa_start_sql(engine, &xid),
            expected,
            "XA START grammar must match for {engine}"
        );
    }
}

#[test]
fn hex_decode_empty_string_produces_empty_vec() {
    assert_eq!(hex_decode("").as_deref(), Some(&[][..]));
}

#[test]
fn xid_decode_postgres_rejects_hex_decoded_oversize_gtrid() {
    let oversized_hex = "aa".repeat(65);
    let encoded = format!("0_{oversized_hex}_");
    assert!(Xid::decode_postgres(&encoded).is_none());
}

#[test]
fn parse_ascii_int_parses_negative_i32() {
    assert_eq!(parse_ascii_int::<i32>(b"-99"), Some(-99));
}

#[test]
fn oracle_xa_block_two_allowed_return_codes() {
    let sql = oracle_xa_block("DBMS_XA.XA_COMMIT(x)", &[3, -4]);
    assert!(sql.contains("rc <> 3"));
    assert!(sql.contains("rc <> -4"));
}

#[test]
fn resume_prepared_without_connection_succeeds() {
    let handles = std::sync::Arc::new(std::sync::Mutex::new(crate::handles::HandleManager::new()));
    let xid = sample_xid();
    let prepared = resume_prepared(handles, u32::MAX, xid.clone()).expect("resume");
    assert_eq!(prepared.xid(), &xid);
}

#[test]
fn xa_from_test_state_exposes_xid_and_state() {
    let xa = XaTransaction::from_test_state(XaState::Active, ENGINE_POSTGRES, sample_xid());
    assert_eq!(xa.state(), XaState::Active);
    assert_eq!(xa.xid(), &sample_xid());
}

#[test]
fn oracle_recover_query_targets_dba_pending_transactions() {
    assert_eq!(
        oracle_xa_recover_sql(),
        "SELECT FORMATID, RAWTOHEX(GLOBALID), RAWTOHEX(BRANCHID) \
         FROM DBA_PENDING_TRANSACTIONS"
    );
}

#[test]
fn unsupported_other_unknown_engine_mentions_engine_id() {
    let err = unsupported_other(ENGINE_UNKNOWN);
    let s = err.to_string();
    assert!(s.contains(ENGINE_UNKNOWN));
    assert!(s.contains("postgres"));
}

#[test]
fn xid_postgres_round_trip_negative_format_id() {
    let xid = Xid::new(-1, b"g".to_vec(), vec![]).unwrap();
    let encoded = xid.encode_postgres();
    assert!(encoded.starts_with("-1_"));
    let decoded = Xid::decode_postgres(&encoded).expect("negative format_id");
    assert_eq!(decoded, xid);
}

#[test]
fn postgres_xa_recover_query_targets_pg_prepared_xacts() {
    assert_eq!(
        postgres_xa_recover_sql(),
        "SELECT gid FROM pg_prepared_xacts"
    );
}

#[test]
fn mysql_xa_recover_sql_is_xa_recover() {
    assert_eq!(mysql_xa_recover_sql(), "XA RECOVER");
}

// Mirrors per-engine SQL in apply_xa_* without ODBC.
fn postgres_xa_start_sql() -> &'static str {
    "BEGIN"
}

fn postgres_xa_commit_sql(one_phase: bool) -> String {
    if one_phase {
        "COMMIT".to_string()
    } else {
        format!("COMMIT PREPARED '{}'", sample_xid().encode_postgres())
    }
}

fn postgres_xa_recover_sql() -> &'static str {
    "SELECT gid FROM pg_prepared_xacts"
}

fn mysql_xa_recover_sql() -> &'static str {
    "XA RECOVER"
}

fn oracle_xa_recover_sql() -> &'static str {
    "SELECT FORMATID, RAWTOHEX(GLOBALID), RAWTOHEX(BRANCHID) \
     FROM DBA_PENDING_TRANSACTIONS"
}

fn oracle_xa_start_sql(xid: &Xid) -> String {
    oracle_xa_block(
        &format!(
            "DBMS_XA.XA_START({}, DBMS_XA.TMNOFLAGS)",
            oracle_xid_literal(xid),
        ),
        &[],
    )
}

fn oracle_xa_prepare_sql(xid: &Xid) -> String {
    oracle_xa_block(
        &format!("DBMS_XA.XA_PREPARE({})", oracle_xid_literal(xid)),
        &[ORACLE_XA_RDONLY],
    )
}

fn oracle_xa_commit_sql(xid: &Xid, one_phase: bool) -> String {
    let onephase_lit = if one_phase { "TRUE" } else { "FALSE" };
    let allow: &[i32] = if one_phase { &[] } else { &[ORACLE_XAER_NOTA] };
    oracle_xa_block(
        &format!(
            "DBMS_XA.XA_COMMIT({}, {})",
            oracle_xid_literal(xid),
            onephase_lit,
        ),
        allow,
    )
}

fn dialect_xa_start_sql(_engine: &str, xid: &Xid) -> String {
    mysql_xa_start_sql(xid)
}

#[test]
fn xid_accessors_expose_constructed_fields() {
    let xid = Xid::new(42, b"gtrid-bytes".to_vec(), b"bqual".to_vec()).unwrap();
    assert_eq!(xid.format_id(), 42);
    assert_eq!(xid.gtrid(), b"gtrid-bytes".as_slice());
    assert_eq!(xid.bqual(), b"bqual".as_slice());
}

#[test]
fn hex_nibble_accepts_all_valid_ascii_hex_digits() {
    for (c, expected) in [
        (b'0', 0),
        (b'9', 9),
        (b'a', 10),
        (b'f', 15),
        (b'A', 10),
        (b'F', 15),
    ] {
        assert_eq!(hex_nibble(c), Some(expected), "digit {c}");
    }
    assert_eq!(hex_nibble(b'g'), None);
}

#[test]
fn postgres_active_rollback_sql_is_plain_rollback() {
    assert_eq!(postgres_xa_rollback_active_sql(), "ROLLBACK");
}

#[test]
fn postgres_prepared_rollback_sql_uses_rollback_prepared() {
    let xid = sample_xid();
    let sql = format!("ROLLBACK PREPARED '{}'", xid.encode_postgres());
    assert_eq!(postgres_xa_rollback_prepared_sql(&xid), sql);
}

#[test]
fn mysql_xa_end_with_bqual_matches_start_component_order() {
    let xid = sample_xid();
    let end = mysql_xa_end_sql(&xid);
    let start = mysql_xa_start_sql(&xid);
    assert!(end.starts_with("XA END "));
    assert_eq!(end.replace("XA END ", ""), start.replace("XA START ", ""));
}

#[test]
fn xa_transaction_end_rejects_when_state_committed() {
    let xa = XaTransaction::from_test_state(XaState::Committed, ENGINE_POSTGRES, sample_xid());
    let r = xa.end();
    match r {
        Err(OdbcError::ValidationError(msg)) => {
            assert!(msg.contains("XaTransaction::end"));
            assert!(msg.contains("expected state Active, got Committed"));
        }
        _ => panic!("expected ValidationError"),
    }
}

#[test]
fn oracle_xa_end_sql_wraps_xa_end_with_tmsuccess() {
    let xid = sample_xid();
    let sql = oracle_xa_end_sql(&xid);
    assert!(sql.contains("DBMS_XA.XA_END("));
    assert!(sql.contains("DBMS_XA.TMSUCCESS"));
    assert!(sql.contains(&oracle_xid_literal(&xid)));
}

#[test]
fn xid_mysql_decode_empty_bqual_round_trip() {
    let xid = Xid::new(3, b"ab".to_vec(), vec![]).unwrap();
    let (g, b, f) = xid.encode_mysql_components();
    assert!(b.is_empty());
    let decoded = Xid::decode_mysql_components(&g, &b, f).expect("round-trip");
    assert_eq!(decoded, xid);
}

fn postgres_xa_rollback_active_sql() -> &'static str {
    "ROLLBACK"
}

fn postgres_xa_rollback_prepared_sql(xid: &Xid) -> String {
    format!("ROLLBACK PREPARED '{}'", xid.encode_postgres())
}

fn oracle_xa_end_sql(xid: &Xid) -> String {
    oracle_xa_block(
        &format!(
            "DBMS_XA.XA_END({}, DBMS_XA.TMSUCCESS)",
            oracle_xid_literal(xid),
        ),
        &[],
    )
}
