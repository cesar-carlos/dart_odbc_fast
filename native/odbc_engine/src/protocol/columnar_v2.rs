//! Columnar wire format v2 — **experimental** header constants and helpers.
//!
//! # Experimental status
//!
//! This module is behind the `columnar-v2` Cargo feature. Enabling that
//! feature prints a `cargo:warning` at build time. Only magic/version
//! constants and placeholder benches exist today; the full emitter/parser
//! is not production-ready. See `doc/notes/columnar_protocol_sketch.md`.
//!
//! Do not enable `columnar-v2` in release consumer builds until the wire
//! format graduates from the sketch doc and golden tests cover encode/decode.

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

    #[test]
    fn version_constant_matches_sketch() {
        assert_eq!(COLUMNAR_V2_VERSION, 2);
    }

    #[test]
    fn magic_round_trips_through_le_bytes() {
        assert_eq!(
            u32::from_le_bytes(COLUMNAR_V2_MAGIC.to_le_bytes()),
            COLUMNAR_V2_MAGIC
        );
    }
}
