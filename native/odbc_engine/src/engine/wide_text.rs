//! Shared UTF-16 LE → UTF-8 conversion for ODBC wide-text cells.
//!
//! Drivers deliver `NVARCHAR` / `WVARCHAR` via `SQL_C_WCHAR` as UTF-16 LE.
//! The hot path below keeps the historical `String::from_utf16_lossy`
//! semantics (unpaired surrogates → U+FFFD) while short-circuiting the
//! common ASCII-only case that never needs a UTF-16 decoder.

use crate::protocol::CellBytes;

/// Convert a UTF-16 LE slice to UTF-8 bytes.
///
/// ASCII-only input (every code unit `< 0x80`) is copied in a single pass
/// without allocating an intermediate `String`. Mixed / non-ASCII input
/// falls back to [`String::from_utf16_lossy`] so unpaired surrogates still
/// become U+FFFD — matching the legacy cell-reader contract.
#[inline]
pub fn wide_text_to_utf8_vec(wide: &[u16]) -> Vec<u8> {
    if is_ascii_wide(wide) {
        let mut out = Vec::with_capacity(wide.len());
        out.extend(wide.iter().map(|&u| u as u8));
        out
    } else {
        String::from_utf16_lossy(wide).into_bytes()
    }
}

/// Same as [`wide_text_to_utf8_vec`] but returns [`CellBytes`] so short
/// ASCII values (≤ 8 bytes) stay inline in `SmallVec<[u8; 8]>`.
#[inline]
pub fn wide_text_to_utf8_bytes(wide: &[u16]) -> CellBytes {
    if is_ascii_wide(wide) {
        let mut cell = CellBytes::with_capacity(wide.len());
        cell.extend(wide.iter().map(|&u| u as u8));
        cell
    } else {
        String::from_utf16_lossy(wide).into_bytes().into()
    }
}

#[inline]
fn is_ascii_wide(wide: &[u16]) -> bool {
    wide.iter().all(|&u| u < 0x80)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ascii_fast_path_matches_lossy() {
        let wide: Vec<u16> = b"Hello, world!".iter().map(|&b| u16::from(b)).collect();
        assert_eq!(
            wide_text_to_utf8_vec(&wide),
            String::from_utf16_lossy(&wide).into_bytes()
        );
        assert_eq!(wide_text_to_utf8_bytes(&wide).as_slice(), b"Hello, world!");
    }

    #[test]
    fn short_ascii_stays_inline_in_cell_bytes() {
        let wide = [b'H' as u16, b'i' as u16];
        let cell = wide_text_to_utf8_bytes(&wide);
        assert_eq!(cell.as_slice(), b"Hi");
        assert!(!cell.spilled());
    }

    #[test]
    fn cjk_matches_lossy_round_trip() {
        let wide: Vec<u16> = "你好".encode_utf16().collect();
        assert_eq!(wide_text_to_utf8_vec(&wide), "你好".as_bytes());
        assert_eq!(wide_text_to_utf8_bytes(&wide).as_slice(), "你好".as_bytes());
    }

    #[test]
    fn unpaired_surrogate_becomes_replacement_char() {
        let out = wide_text_to_utf8_vec(&[0xD800]);
        assert_eq!(out, "\u{FFFD}".as_bytes());
    }

    #[test]
    fn empty_slice_is_empty_utf8() {
        assert!(wide_text_to_utf8_vec(&[]).is_empty());
        assert!(wide_text_to_utf8_bytes(&[]).is_empty());
    }

    #[test]
    fn latin1_above_ascii_uses_lossy_path() {
        // U+00E9 LATIN SMALL LETTER E WITH ACUTE — not ASCII fast-path.
        let wide = [0x00E9u16];
        assert_eq!(wide_text_to_utf8_vec(&wide), "é".as_bytes());
    }
}
