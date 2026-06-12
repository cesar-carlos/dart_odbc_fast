pub(super) fn parse_multi_stream_frame(bytes: &[u8]) -> (u8, Vec<u8>) {
    assert!(bytes.len() >= 5, "frame must include tag + u32 len");
    let tag = bytes[0];
    let len = u32::from_le_bytes([bytes[1], bytes[2], bytes[3], bytes[4]]) as usize;
    assert_eq!(bytes.len(), 5 + len);
    (tag, bytes[5..].to_vec())
}
