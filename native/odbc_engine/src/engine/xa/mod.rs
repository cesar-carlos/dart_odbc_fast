//! X/Open XA distributed transaction support — Sprint 4.3.
//!
//! Implements the **Two-Phase Commit (2PC)** lifecycle on top of ODBC
//! using each engine's native SQL-level XA grammar. The cross-vendor
//! abstraction lives here; per-engine SQL emission lives in
//! [`apply_xa_start`], [`apply_xa_end`], [`apply_xa_prepare`],
//! [`apply_xa_commit`], [`apply_xa_rollback`] and [`apply_xa_recover`].
//!
//! ## Engine matrix
//!
//! | Engine                | Mechanism                                  | Status            |
//! | --------------------- | ------------------------------------------ | ----------------- |
//! | PostgreSQL            | SQL: `PREPARE TRANSACTION` + `pg_prepared_xacts` | ✅ implemented |
//! | MySQL / MariaDB       | SQL: `XA START / END / PREPARE / COMMIT / ROLLBACK / RECOVER` | ✅ implemented |
//! | DB2                   | SQL: native `XA*` family                   | ✅ implemented    |
//! | SQL Server            | Requires MSDTC enlistment (Windows COM, `SQL_ATTR_ENLIST_IN_DTC` + `ITransaction*`) | ✅ lifecycle on Windows with `--features xa-dtc`; advanced `Reenlist` / RM recovery remains operational scope |
//! | Oracle                | PL/SQL: `DBMS_XA` package (`SYS.DBMS_XA_XID`, `XA_START / END / PREPARE / COMMIT / ROLLBACK`); recovery via `DBA_PENDING_TRANSACTIONS` | ✅ implemented (10g+) — needs `EXECUTE` on `DBMS_XA` plus `FORCE [ANY] TRANSACTION` |
//! | SQLite / Snowflake / others | No 2PC support                       | ❌ rejected with `UnsupportedFeature` |
//!
//! Note on Oracle: an alternative path through Oracle's OCI XA library
//! (`xaoSvcCtx` / `oraxa.h`) is scaffolded in [`crate::engine::xa_oci`]
//! behind the `xa-oci` Cargo feature. Production deployments use the
//! `DBMS_XA` PL/SQL path because it works through any Oracle ODBC
//! driver without requiring access to the underlying `OCIServer*`
//! handle (which `odbc-api` does not expose). The OCI shim is kept
//! as a future option if the underlying handle ever becomes
//! reachable.
//!
//! ## XID encoding
//!
//! The X/Open XID is a 192-byte structure with three fields: a 32-bit
//! `format_id`, a 1..64-byte global transaction id (`gtrid`) and a
//! 0..64-byte branch qualifier (`bqual`).
//!
//! Each engine demands a different SQL-level spelling:
//!
//! - **PostgreSQL** accepts a single arbitrary string identifier.
//!   We canonicalise as `"<format_id>_<gtrid_hex>_<bqual_hex>"` so
//!   the original components round-trip through `pg_prepared_xacts`.
//! - **MySQL / MariaDB** uses three positional arguments:
//!   `XA START 'gtrid', 'bqual', formatID`. We pass the components
//!   directly, hex-encoded to keep the SQL ASCII-clean.
//! - **DB2** matches MySQL's three-argument grammar.
//!
//! See [`Xid::encode_postgres`], [`Xid::encode_mysql_components`] and
//! [`Xid::decode_postgres`].
//!
//! ## State machine
//!
//! ```text
//!                start              end                prepare
//!     [None] ──────────▶ [Active] ──────▶ [Idle] ─────────────▶ [Prepared]
//!                          │                │                       │
//!                          │ rollback       │ rollback              │ commit_prepared
//!                          ▼                ▼                       ▼
//!                       [RolledBack]   [RolledBack]              [Committed]
//!                                                                    or
//!                                                                [RolledBack]
//! ```
//!
//! `commit_one_phase` is a 1RM optimisation that fuses
//! `prepare → commit_prepared` for the case where the resource manager
//! is the only RM in the transaction. Avoids the disk write of the
//! prepare log; valid only when the caller is sure no other RM
//! enlisted.

mod apply;
mod hex;
mod mssql;
mod oracle;
#[cfg(test)]
mod tests;
mod transaction;
mod xid;

pub use transaction::{
    recover_prepared_xids, resume_prepared, PreparedXa, PreparingXa, XaState, XaTransaction,
};
pub use xid::Xid;
