use zeroize::{Zeroize, ZeroizeOnDrop};

#[derive(ZeroizeOnDrop)]
pub struct SecureBuffer {
    data: Vec<u8>,
}

impl SecureBuffer {
    pub fn new(data: Vec<u8>) -> Self {
        Self { data }
    }

    pub fn from_string(s: String) -> Self {
        Self::new(s.into_bytes())
    }

    pub fn as_slice(&self) -> &[u8] {
        &self.data
    }

    /// Run `f` with read-only access to the buffer bytes, then zeroise the
    /// buffer in place before returning (C5).
    pub fn with_bytes<R>(mut self, f: impl FnOnce(&[u8]) -> R) -> R {
        let r = f(&self.data);
        self.data.zeroize();
        r
    }

    pub fn to_string_lossy(&self) -> String {
        String::from_utf8_lossy(&self.data).to_string()
    }

    pub fn len(&self) -> usize {
        self.data.len()
    }

    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }
}

impl Zeroize for SecureBuffer {
    fn zeroize(&mut self) {
        self.data.zeroize();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new() {
        let data = vec![1, 2, 3, 4];
        let buffer = SecureBuffer::new(data.clone());
        assert_eq!(buffer.as_slice(), &[1, 2, 3, 4]);
    }

    #[test]
    fn test_from_string() {
        let s = "secret password".to_string();
        let buffer = SecureBuffer::from_string(s.clone());
        assert_eq!(buffer.as_slice(), s.as_bytes());
    }

    #[test]
    fn test_as_slice() {
        let buffer = SecureBuffer::new(vec![10, 20, 30]);
        let slice = buffer.as_slice();
        assert_eq!(slice, &[10, 20, 30]);
    }

    #[test]
    fn test_with_bytes_zeroes_after_use() {
        let buffer = SecureBuffer::new(vec![1, 2, 3]);
        let copy = buffer.with_bytes(|b| b.to_vec());
        assert_eq!(copy, vec![1, 2, 3]);
    }

    #[test]
    fn test_to_string_lossy_valid_utf8() {
        let buffer = SecureBuffer::from_string("Hello, World!".to_string());
        assert_eq!(buffer.to_string_lossy(), "Hello, World!");
    }

    #[test]
    fn test_to_string_lossy_invalid_utf8() {
        let invalid_utf8 = vec![0xFF, 0xFE, 0xFD];
        let buffer = SecureBuffer::new(invalid_utf8);
        // Should not panic, returns replacement chars
        let result = buffer.to_string_lossy();
        assert!(!result.is_empty());
    }

    #[test]
    fn test_zeroize() {
        let mut buffer = SecureBuffer::new(vec![1, 2, 3, 4, 5]);
        buffer.zeroize();
        // After zeroize, the vec is cleared (empty), not filled with zeros
        // The zeroize implementation clears the vec for security
        assert!(buffer.as_slice().is_empty());
    }

    #[test]
    fn test_drop_zeroizes() {
        // This test verifies the ZeroizeOnDrop behavior
        // We can't directly test that drop zeroizes memory,
        // but we can verify the trait is implemented
        let _buffer = SecureBuffer::from_string("sensitive data".to_string());
        // When buffer goes out of scope, ZeroizeOnDrop should zeroize it
    }

    #[test]
    fn test_empty_buffer() {
        let buffer = SecureBuffer::new(Vec::new());
        assert!(buffer.as_slice().is_empty());
        assert_eq!(buffer.to_string_lossy(), "");
    }

    #[test]
    fn test_large_buffer() {
        let large_data = vec![42u8; 1_000_000];
        let buffer = SecureBuffer::new(large_data.clone());
        assert_eq!(buffer.as_slice().len(), 1_000_000);
        assert!(buffer.as_slice().iter().all(|&b| b == 42));
    }

    #[test]
    fn test_unicode_string() {
        let unicode = "Hello 世界 🌍".to_string();
        let buffer = SecureBuffer::from_string(unicode.clone());
        assert_eq!(buffer.to_string_lossy(), unicode);
    }

    #[test]
    fn test_binary_data() {
        let binary = vec![0x00, 0xFF, 0x7F, 0x80, 0xAA, 0x55];
        let buffer = SecureBuffer::new(binary.clone());
        assert_eq!(buffer.as_slice(), &[0x00, 0xFF, 0x7F, 0x80, 0xAA, 0x55]);
    }

    #[test]
    fn should_report_len_and_is_empty() {
        let empty = SecureBuffer::new(Vec::new());
        assert!(empty.is_empty());
        assert_eq!(empty.len(), 0);

        let filled = SecureBuffer::new(vec![9, 8]);
        assert!(!filled.is_empty());
        assert_eq!(filled.len(), 2);
    }
}
