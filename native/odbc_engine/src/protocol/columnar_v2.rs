//! Columnar wire format v2 — header constants and helpers.
//!
//! Full emitter/parser lives in follow-up work; see
//! `doc/notes/columnar_protocol_sketch.md`. Gated by Cargo feature
//! `columnar-v2` so default builds stay unchanged.

/// Little-endian `b"ODBC"` — first four bytes of the v2 header in the
/// design sketch.
pub const COLUMNAR_V2_MAGIC: u32 = u32::from_le_bytes(*b"ODBC");

/// Protocol version field value from the sketch (`ver` = `u16` after magic).
pub const COLUMNAR_V2_VERSION: u16 = 2;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn magic_matches_sketch_label() {
        let bytes = COLUMNAR_V2_MAGIC.to_le_bytes();
        assert_eq!(&bytes, b"ODBC");
    }
}
