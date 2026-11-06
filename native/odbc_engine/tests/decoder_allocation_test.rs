use odbc_engine::protocol::BinaryProtocolDecoder;
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

struct TrackingAllocator;
thread_local! {
    static LARGEST: Cell<Option<usize>> = const { Cell::new(None) };
}

// SAFETY: All allocations and releases are forwarded unchanged to System.
unsafe impl GlobalAlloc for TrackingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        // Constant TLS initialization does not allocate. Other test-runner
        // threads and allocations during TLS teardown are not measured.
        let _ = LARGEST.try_with(|largest| {
            if let Some(size) = largest.get() {
                largest.set(Some(size.max(layout.size())));
            }
        });
        // SAFETY: The caller supplies a valid allocation layout.
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        // SAFETY: The allocation originated from System with this layout.
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: TrackingAllocator = TrackingAllocator;

#[test]
fn should_reject_mismatched_payload_without_allocating_declared_rows() {
    let mut wire = Vec::new();
    wire.extend_from_slice(&0x4F444243u32.to_le_bytes());
    wire.extend_from_slice(&1u16.to_le_bytes());
    wire.extend_from_slice(&0u16.to_le_bytes());
    wire.extend_from_slice(&1_000_000u32.to_le_bytes());
    wire.extend_from_slice(&1u32.to_le_bytes());

    LARGEST.set(Some(0));
    let result = BinaryProtocolDecoder::parse(&wire);
    let largest = LARGEST.replace(None).expect("allocation tracking enabled");

    assert!(result
        .expect_err("invalid payload must fail")
        .to_string()
        .contains("Payload size mismatch"));
    assert!(
        largest < 1024,
        "a 16-byte invalid header caused a {}-byte allocation",
        largest
    );
}
