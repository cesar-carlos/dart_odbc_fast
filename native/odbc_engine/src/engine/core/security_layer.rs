use zeroize::ZeroizeOnDrop;

#[derive(ZeroizeOnDrop)]
pub struct SecureBuffer {
    data: Vec<u8>,
}

impl SecureBuffer {
    pub fn new(data: Vec<u8>) -> Self {
        Self { data }
    }

    pub fn as_slice(&self) -> &[u8] {
        &self.data
    }

    pub fn into_vec(mut self) -> Vec<u8> {
        std::mem::take(&mut self.data)
    }
}

pub struct SecurityLayer;

impl SecurityLayer {
    pub fn new() -> Self {
        Self
    }

    pub fn secure_buffer(&self, data: Vec<u8>) -> SecureBuffer {
        SecureBuffer::new(data)
    }

    pub fn zeroize_buffer(buffer: &mut [u8]) {
        zeroize::Zeroize::zeroize(buffer);
    }
}

impl Default for SecurityLayer {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_security_layer_new() {
        let layer = SecurityLayer::new();
        let buffer = layer.secure_buffer(vec![1, 2, 3, 4]);
        assert_eq!(buffer.as_slice(), &[1, 2, 3, 4]);
    }

    #[test]
    fn test_security_layer_default() {
        let layer = SecurityLayer;
        let buffer = layer.secure_buffer(vec![5, 6, 7]);
        assert_eq!(buffer.as_slice(), &[5, 6, 7]);
    }

    #[test]
    fn test_secure_buffer_new() {
        let data = vec![1, 2, 3, 4, 5];
        let buffer = SecureBuffer::new(data.clone());
        assert_eq!(buffer.as_slice(), &data);
    }

    #[test]
    fn test_secure_buffer_as_slice() {
        let data = vec![10, 20, 30];
        let buffer = SecureBuffer::new(data);
        let slice = buffer.as_slice();
        assert_eq!(slice, &[10, 20, 30]);
    }

    #[test]
    fn test_secure_buffer_into_vec() {
        let data = vec![100, 200, 255];
        let buffer = SecureBuffer::new(data.clone());
        let vec = buffer.into_vec();
        assert_eq!(vec, data);
    }

    #[test]
    fn test_secure_buffer_empty() {
        let buffer = SecureBuffer::new(vec![]);
        assert!(buffer.as_slice().is_empty());
    }

    #[test]
    fn test_zeroize_buffer() {
        let mut data = vec![1, 2, 3, 4, 5];
        SecurityLayer::zeroize_buffer(&mut data);
        assert!(data.iter().all(|&b| b == 0));
    }

    #[test]
    fn test_zeroize_buffer_empty() {
        let mut data = vec![];
        SecurityLayer::zeroize_buffer(&mut data);
        assert_eq!(data.len(), 0);
    }

    #[test]
    fn test_secure_buffer_large_data() {
        let data: Vec<u8> = (0..1000).map(|i| (i % 256) as u8).collect();
        let buffer = SecureBuffer::new(data.clone());
        assert_eq!(buffer.as_slice().len(), 1000);
    }
}
