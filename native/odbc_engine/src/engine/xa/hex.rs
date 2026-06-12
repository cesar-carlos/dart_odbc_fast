pub(crate) const HEX_LUT: &[u8; 16] = b"0123456789abcdef";
pub(crate) const HEX_LUT_UPPER: &[u8; 16] = b"0123456789ABCDEF";

pub(crate) fn hex_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX_LUT[(b >> 4) as usize] as char);
        out.push(HEX_LUT[(b & 0x0F) as usize] as char);
    }
    out
}

pub(crate) fn hex_encode_upper(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX_LUT_UPPER[(b >> 4) as usize] as char);
        out.push(HEX_LUT_UPPER[(b & 0x0F) as usize] as char);
    }
    out
}

pub(crate) fn hex_decode(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) {
        return None;
    }
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len() / 2);
    for chunk in bytes.chunks_exact(2) {
        let hi = hex_nibble(chunk[0])?;
        let lo = hex_nibble(chunk[1])?;
        out.push((hi << 4) | lo);
    }
    Some(out)
}

pub(crate) fn hex_nibble(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}
