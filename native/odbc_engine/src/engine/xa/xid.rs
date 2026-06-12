use crate::error::{OdbcError, Result};

use super::hex::{hex_decode, hex_encode, hex_encode_upper};

// XID size limits per X/Open. We enforce them at construction so a
// malformed XID can never reach the engine — every backend rejects
// oversize gtrid/bqual but with cryptic messages.
const XID_MAX_GTRID_LEN: usize = 64;
const XID_MAX_BQUAL_LEN: usize = 64;

/// Global transaction identifier (X/Open XA `XID`).
///
/// The 32-bit `format_id` is application-defined; common values are
/// `0` (default) or `0x1B` (the IBM/JTA convention). `gtrid` is the
/// global transaction id (1..64 bytes); `bqual` is the branch
/// qualifier (0..64 bytes). All three together must be unique within
/// the recovery set of every participating Resource Manager.
///
/// Construct via [`Xid::new`] (validating) or [`Xid::for_test`]
/// (no-op constructor for unit tests).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Xid {
    format_id: i32,
    gtrid: Vec<u8>,
    bqual: Vec<u8>,
}

impl Xid {
    /// Construct a new XID, validating the `gtrid` / `bqual` lengths
    /// against the X/Open limits (1..=64 bytes for `gtrid`,
    /// 0..=64 bytes for `bqual`). Empty `gtrid` is rejected because
    /// every RM treats it as a malformed transaction id.
    pub fn new(format_id: i32, gtrid: Vec<u8>, bqual: Vec<u8>) -> Result<Self> {
        if gtrid.is_empty() {
            return Err(OdbcError::ValidationError(
                "Xid: gtrid must be non-empty (1..=64 bytes)".to_string(),
            ));
        }
        if gtrid.len() > XID_MAX_GTRID_LEN {
            return Err(OdbcError::ValidationError(format!(
                "Xid: gtrid is {} bytes; X/Open limit is {}",
                gtrid.len(),
                XID_MAX_GTRID_LEN,
            )));
        }
        if bqual.len() > XID_MAX_BQUAL_LEN {
            return Err(OdbcError::ValidationError(format!(
                "Xid: bqual is {} bytes; X/Open limit is {}",
                bqual.len(),
                XID_MAX_BQUAL_LEN,
            )));
        }
        Ok(Self {
            format_id,
            gtrid,
            bqual,
        })
    }

    pub fn format_id(&self) -> i32 {
        self.format_id
    }

    pub fn gtrid(&self) -> &[u8] {
        &self.gtrid
    }

    pub fn bqual(&self) -> &[u8] {
        &self.bqual
    }

    /// Canonical PostgreSQL identifier:
    /// `"<format_id>_<gtrid_hex>_<bqual_hex>"`. Round-trippable via
    /// [`Xid::decode_postgres`]. The hex encoding keeps the
    /// identifier ASCII-clean so it survives `pg_prepared_xacts`
    /// without quoting surprises.
    pub fn encode_postgres(&self) -> String {
        format!(
            "{}_{}_{}",
            self.format_id,
            hex_encode(&self.gtrid),
            hex_encode(&self.bqual),
        )
    }

    /// Inverse of [`Xid::encode_postgres`]. Returns `None` for any
    /// input that doesn't match the canonical shape — including XIDs
    /// that PostgreSQL knows about but were prepared by another
    /// client using a different naming scheme.
    pub fn decode_postgres(s: &str) -> Option<Self> {
        let mut parts = s.splitn(3, '_');
        let format_id_str = parts.next()?;
        let gtrid_hex = parts.next()?;
        let bqual_hex = parts.next()?;
        let format_id: i32 = format_id_str.parse().ok()?;
        let gtrid = hex_decode(gtrid_hex)?;
        let bqual = hex_decode(bqual_hex)?;
        Self::new(format_id, gtrid, bqual).ok()
    }

    /// MySQL / MariaDB / DB2 split the XID into three positional
    /// arguments: `XA START 'gtrid', 'bqual', formatID`. We
    /// hex-encode `gtrid` / `bqual` so the SQL stays ASCII-clean
    /// regardless of the byte content (which X/Open allows to be
    /// arbitrary binary).
    ///
    /// Returns `(gtrid_hex, bqual_hex, format_id)`.
    pub fn encode_mysql_components(&self) -> (String, String, i32) {
        (
            hex_encode(&self.gtrid),
            hex_encode(&self.bqual),
            self.format_id,
        )
    }

    /// Inverse of [`Xid::encode_mysql_components`]. Used by
    /// [`super::apply::apply_xa_recover`] to rebuild the XID list returned by
    /// `XA RECOVER`.
    pub fn decode_mysql_components(
        gtrid_hex: &str,
        bqual_hex: &str,
        format_id: i32,
    ) -> Option<Self> {
        let gtrid = hex_decode(gtrid_hex)?;
        let bqual = hex_decode(bqual_hex)?;
        Self::new(format_id, gtrid, bqual).ok()
    }

    /// Oracle `DBMS_XA` PL/SQL takes a `SYS.DBMS_XA_XID(formatid INTEGER,
    /// gtrid RAW(64), bqual RAW(64))` constructor. We pass the binary
    /// components as `HEXTORAW('<uppercase hex>')` literals — uppercase
    /// because Oracle's own `RAWTOHEX` returns uppercase, which keeps
    /// recovery round-trips byte-identical.
    ///
    /// Returns `(format_id, gtrid_hex_upper, bqual_hex_upper)`.
    pub fn encode_oracle_components(&self) -> (i32, String, String) {
        (
            self.format_id,
            hex_encode_upper(&self.gtrid),
            hex_encode_upper(&self.bqual),
        )
    }

    /// Inverse of [`Xid::encode_oracle_components`]. Hex parsing is
    /// case-insensitive so we round-trip both our own `HEXTORAW`
    /// literals and the uppercase form returned by Oracle's
    /// `RAWTOHEX(globalid)` in `DBA_PENDING_TRANSACTIONS`.
    pub fn decode_oracle_components(
        format_id: i32,
        gtrid_hex: &str,
        bqual_hex: &str,
    ) -> Option<Self> {
        let gtrid = hex_decode(gtrid_hex)?;
        let bqual = hex_decode(bqual_hex)?;
        Self::new(format_id, gtrid, bqual).ok()
    }
}

#[cfg(any(test, feature = "test-helpers"))]
impl Xid {
    /// Test-only constructor that bypasses validation. Useful when a
    /// test wants to construct a known-bad XID (e.g. to feed `decode_*`).
    /// Hidden from rustdoc.
    #[doc(hidden)]
    pub fn for_test(format_id: i32, gtrid: Vec<u8>, bqual: Vec<u8>) -> Self {
        Self {
            format_id,
            gtrid,
            bqual,
        }
    }
}
