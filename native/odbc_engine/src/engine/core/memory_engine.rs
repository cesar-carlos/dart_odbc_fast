use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

pub struct BufferPool {
    buffers: Arc<Mutex<VecDeque<Vec<u8>>>>,
    buffer_size: usize,
    max_buffers: usize,
}

impl BufferPool {
    pub fn new(buffer_size: usize, max_buffers: usize) -> Self {
        Self {
            buffers: Arc::new(Mutex::new(VecDeque::new())),
            buffer_size,
            max_buffers,
        }
    }

    pub fn acquire(&self) -> Vec<u8> {
        let mut buffers = self.buffers.lock().unwrap();
        buffers
            .pop_front()
            .unwrap_or_else(|| vec![0u8; self.buffer_size])
    }

    pub fn release(&self, mut buffer: Vec<u8>) {
        let mut buffers = self.buffers.lock().unwrap();
        if buffers.len() < self.max_buffers {
            buffer.clear();
            buffer.resize(self.buffer_size, 0);
            buffers.push_back(buffer);
        }
    }
}

pub struct MemoryEngine {
    buffer_pool: Arc<BufferPool>,
}

impl MemoryEngine {
    pub fn new(buffer_size: usize, max_buffers: usize) -> Self {
        Self {
            buffer_pool: Arc::new(BufferPool::new(buffer_size, max_buffers)),
        }
    }

    pub fn acquire_buffer(&self) -> Vec<u8> {
        self.buffer_pool.acquire()
    }

    pub fn release_buffer(&self, buffer: Vec<u8>) {
        self.buffer_pool.release(buffer);
    }
}

impl Default for MemoryEngine {
    fn default() -> Self {
        Self::new(64 * 1024, 10)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_buffer_pool_new() {
        let pool = BufferPool::new(1024, 5);
        let buffer = pool.acquire();
        assert_eq!(buffer.len(), 1024);
    }

    #[test]
    fn test_buffer_pool_acquire_new_buffer() {
        let pool = BufferPool::new(512, 3);
        let buffer = pool.acquire();
        assert_eq!(buffer.len(), 512);
        assert!(buffer.iter().all(|&b| b == 0));
    }

    #[test]
    fn test_buffer_pool_acquire_and_release() {
        let pool = BufferPool::new(256, 2);

        let buffer1 = pool.acquire();
        assert_eq!(buffer1.len(), 256);

        pool.release(buffer1);

        let buffer2 = pool.acquire();
        assert_eq!(buffer2.len(), 256);
    }

    #[test]
    fn test_buffer_pool_release_max_buffers() {
        let pool = BufferPool::new(128, 2);

        let buffer1 = pool.acquire();
        let buffer2 = pool.acquire();

        pool.release(buffer1);
        pool.release(buffer2);

        let buffer3 = pool.acquire();
        assert_eq!(buffer3.len(), 128);
    }

    #[test]
    fn test_buffer_pool_release_exceeds_max() {
        let pool = BufferPool::new(64, 1);

        let buffer1 = pool.acquire();
        pool.release(buffer1);

        let buffer2 = pool.acquire();
        pool.release(buffer2);

        let buffer3 = pool.acquire();
        assert_eq!(buffer3.len(), 64);
    }

    #[test]
    fn test_memory_engine_new() {
        let engine = MemoryEngine::new(2048, 5);
        let buffer = engine.acquire_buffer();
        assert_eq!(buffer.len(), 2048);
    }

    #[test]
    fn test_memory_engine_default() {
        let engine = MemoryEngine::default();
        let buffer = engine.acquire_buffer();
        assert_eq!(buffer.len(), 64 * 1024);
    }

    #[test]
    fn test_memory_engine_acquire_and_release() {
        let engine = MemoryEngine::new(512, 3);

        let buffer1 = engine.acquire_buffer();
        assert_eq!(buffer1.len(), 512);

        engine.release_buffer(buffer1);

        let buffer2 = engine.acquire_buffer();
        assert_eq!(buffer2.len(), 512);
    }

    #[test]
    fn test_memory_engine_multiple_buffers() {
        let engine = MemoryEngine::new(256, 2);

        let buffer1 = engine.acquire_buffer();
        let buffer2 = engine.acquire_buffer();

        assert_eq!(buffer1.len(), 256);
        assert_eq!(buffer2.len(), 256);

        engine.release_buffer(buffer1);
        engine.release_buffer(buffer2);
    }
}
