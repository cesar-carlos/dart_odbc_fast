pub struct Arena {
    chunks: Vec<Vec<u8>>,
    current_chunk: Vec<u8>,
    chunk_size: usize,
    current_offset: usize,
}

impl Arena {
    pub fn new(chunk_size: usize) -> Self {
        Self {
            chunks: Vec::new(),
            current_chunk: vec![0u8; chunk_size],
            chunk_size,
            current_offset: 0,
        }
    }

    /// Returns a pointer to a buffer of `size` bytes. The pointer is valid until the next
    /// `allocate` or `allocate_aligned` call, or until the arena is dropped.
    ///
    /// # Safety
    ///
    /// `current_chunk` is guaranteed valid with at least `chunk_size` bytes. `current_offset`
    /// is always within bounds due to the check above. The returned pointer is valid for
    /// `size` bytes within the current chunk.
    ///
    /// When `size > chunk_size`, a dedicated oversized chunk is allocated so that the
    /// returned pointer is always valid for exactly `size` bytes.
    pub fn allocate(&mut self, size: usize) -> *mut u8 {
        if self.current_offset + size > self.chunk_size {
            if size > self.chunk_size {
                // Oversized request: allocate a dedicated chunk exactly large enough.
                // The current chunk is left in place for subsequent smaller allocations.
                let mut oversized = vec![0u8; size];
                let ptr = oversized.as_mut_ptr();
                self.chunks.push(oversized);
                return ptr;
            }
            self.allocate_new_chunk();
        }

        // SAFETY: `current_offset + size <= chunk_size` (checked above);
        // `current_chunk` has `chunk_size` bytes initialised to 0. The returned
        // pointer is valid for `size` bytes within `current_chunk`.
        let ptr = unsafe { self.current_chunk.as_mut_ptr().add(self.current_offset) };
        self.current_offset += size;
        ptr
    }

    fn allocate_new_chunk(&mut self) {
        let old_chunk = std::mem::replace(&mut self.current_chunk, vec![0u8; self.chunk_size]);
        self.chunks.push(old_chunk);
        self.current_offset = 0;
    }

    /// Returns an aligned pointer to a buffer of `size` bytes. `align` must be a power of two.
    ///
    /// # Safety
    ///
    /// Same as `allocate`. After the bounds check, `aligned_offset` is within `chunk_size`
    /// and the pointer is valid for `size` bytes.
    pub fn allocate_aligned(&mut self, size: usize, align: usize) -> *mut u8 {
        debug_assert!(align.is_power_of_two(), "align must be a power of two");

        // For oversized requests allocate a dedicated chunk to avoid infinite
        // recursion (align would never reduce `size` below `chunk_size`).
        if size > self.chunk_size {
            let aligned_size = size.next_multiple_of(align.max(1));
            let mut oversized = vec![0u8; aligned_size];
            let ptr = oversized.as_mut_ptr();
            self.chunks.push(oversized);
            return ptr;
        }

        let aligned_offset = (self.current_offset + align - 1) & !(align - 1);

        if aligned_offset + size > self.chunk_size {
            self.allocate_new_chunk();
            // After a fresh chunk current_offset = 0, aligned_offset will be 0.
            // Re-enter non-recursively with a clean state.
            return self.allocate_aligned(size, align);
        }

        self.current_offset = aligned_offset + size;
        // SAFETY: `aligned_offset + size <= chunk_size` (checked above);
        // `current_chunk` has `chunk_size` initialised bytes. The pointer is valid
        // for `size` bytes starting at `aligned_offset`.
        unsafe { self.current_chunk.as_mut_ptr().add(aligned_offset) }
    }
}

impl Default for Arena {
    fn default() -> Self {
        Self::new(64 * 1024)
    }
}

// Safety: Arena owns its Vec<u8> chunks and current_chunk. Access is only through
// `&mut self` methods, so no shared mutable state across threads. Safe to Send.
unsafe impl Send for Arena {}

// Safety: Arena has no interior mutability; Sync would require sharing &Arena across
// threads. We use it only behind Mutex/Arc in practice. Marking Sync for use in
// Arc<Mutex<Arena>> patterns.
unsafe impl Sync for Arena {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_arena_new() {
        let arena = Arena::new(1024);
        assert_eq!(arena.chunk_size, 1024);
        assert_eq!(arena.current_offset, 0);
        assert_eq!(arena.chunks.len(), 0);
    }

    #[test]
    fn test_arena_default() {
        let arena = Arena::default();
        assert_eq!(arena.chunk_size, 64 * 1024);
        assert_eq!(arena.current_offset, 0);
    }

    #[test]
    fn test_arena_allocate() {
        let mut arena = Arena::new(1024);
        let ptr1 = arena.allocate(100);
        assert!(!ptr1.is_null());
        assert_eq!(arena.current_offset, 100);

        let ptr2 = arena.allocate(200);
        assert!(!ptr2.is_null());
        assert_eq!(arena.current_offset, 300);
    }

    #[test]
    fn test_arena_allocate_new_chunk() {
        let mut arena = Arena::new(100);
        let ptr1 = arena.allocate(50);
        assert!(!ptr1.is_null());
        assert_eq!(arena.current_offset, 50);

        let ptr2 = arena.allocate(60);
        assert!(!ptr2.is_null());
        assert_eq!(arena.chunks.len(), 1);
        assert_eq!(arena.current_offset, 60);
    }

    #[test]
    fn test_arena_allocate_aligned() {
        let mut arena = Arena::new(1024);
        arena.allocate(1);
        let ptr = arena.allocate_aligned(8, 8);
        assert!(!ptr.is_null());
        // Safety: ptr is from allocate_aligned within current_chunk
        let offset = unsafe { ptr.offset_from(arena.current_chunk.as_ptr()) } as usize;
        assert_eq!(offset % 8, 0);
    }

    #[test]
    fn test_arena_allocate_aligned_new_chunk() {
        let mut arena = Arena::new(100);
        arena.allocate(90);
        let ptr = arena.allocate_aligned(20, 16);
        assert!(!ptr.is_null());
        assert_eq!(arena.chunks.len(), 1);
        // Safety: ptr is from allocate_aligned within current_chunk
        let offset = unsafe { ptr.offset_from(arena.current_chunk.as_ptr()) } as usize;
        assert_eq!(offset % 16, 0);
    }

    #[test]
    fn test_arena_multiple_chunks() {
        let mut arena = Arena::new(100);
        arena.allocate(50); // offset = 50
        arena.allocate(60); // 50 + 60 = 110 > 100, triggers new chunk, offset = 60
        arena.allocate(30); // 60 + 30 = 90, still in current chunk, offset = 90
        assert_eq!(arena.chunks.len(), 1); // Only one old chunk (the first one)
        assert_eq!(arena.current_offset, 90);
    }

    #[test]
    fn test_arena_write_to_allocated() {
        let mut arena = Arena::new(1024);
        let ptr = arena.allocate(10);
        // Safety: ptr valid for 10 bytes from allocate
        unsafe {
            std::ptr::write_bytes(ptr, 0x42, 10);
            for i in 0..10 {
                assert_eq!(*ptr.add(i), 0x42);
            }
        }
    }

    #[test]
    fn test_arena_alignment_power_of_two() {
        let mut arena = Arena::new(1024);
        arena.allocate(1);
        let ptr = arena.allocate_aligned(4, 4);
        // Safety: ptr from allocate_aligned within current_chunk
        let offset = unsafe { ptr.offset_from(arena.current_chunk.as_ptr()) } as usize;
        assert_eq!(offset % 4, 0);
    }

    #[test]
    fn test_arena_alignment_large() {
        let mut arena = Arena::new(1024);
        arena.allocate(1);
        let ptr = arena.allocate_aligned(16, 32);
        // Safety: ptr from allocate_aligned within current_chunk
        let offset = unsafe { ptr.offset_from(arena.current_chunk.as_ptr()) } as usize;
        assert_eq!(offset % 32, 0);
    }

    #[test]
    fn allocate_oversized_returns_valid_pointer() {
        // Request larger than chunk_size must NOT overflow the chunk.
        let mut arena = Arena::new(64);
        let ptr = arena.allocate(256);
        assert!(!ptr.is_null());
        // Write to every byte to ensure no out-of-bounds.
        // SAFETY: pointer is valid for 256 bytes per the documented contract.
        unsafe { std::ptr::write_bytes(ptr, 0xAB, 256) };
        // Arena should have placed the oversized chunk in `chunks`.
        assert!(!arena.chunks.is_empty());
    }

    #[test]
    fn allocate_aligned_oversized_does_not_recurse_infinitely() {
        // align = 1, size > chunk_size — must NOT recurse infinitely.
        let mut arena = Arena::new(32);
        let ptr = arena.allocate_aligned(128, 16);
        assert!(!ptr.is_null());
        // SAFETY: pointer is valid for 128 bytes per the documented contract.
        unsafe { std::ptr::write_bytes(ptr, 0xCD, 128) };
    }

    #[test]
    fn allocate_mixed_sizes_after_oversized() {
        // After an oversized allocation the regular current_chunk must still be usable.
        let mut arena = Arena::new(64);
        let big = arena.allocate(256);
        assert!(!big.is_null());
        // Regular small allocation should succeed using the original current_chunk.
        let small = arena.allocate(16);
        assert!(!small.is_null());
    }
}
