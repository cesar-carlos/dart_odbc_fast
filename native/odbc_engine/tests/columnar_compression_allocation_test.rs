use odbc_engine::protocol::{
    columnar::{ColumnData, ColumnMetadata, RowBufferV2},
    ColumnarEncoder, OdbcType,
};
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

struct CountingAllocator;
thread_local! {
    static ALLOCATIONS: Cell<Option<usize>> = const { Cell::new(None) };
}

fn record_allocation() {
    // Constant TLS initialization does not allocate; teardown is not measured.
    let _ = ALLOCATIONS.try_with(|count| {
        if let Some(value) = count.get() {
            count.set(Some(value + 1));
        }
    });
}

// SAFETY: Every allocation operation is forwarded unchanged to System.
unsafe impl GlobalAlloc for CountingAllocator {
    /// # Safety
    /// `layout` must satisfy the allocation contract of `GlobalAlloc`.
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        record_allocation();
        // SAFETY: The caller provides the valid allocation layout.
        unsafe { System.alloc(layout) }
    }
    /// # Safety
    /// `ptr`, `layout` and `new_size` must satisfy `GlobalAlloc::realloc`.
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        record_allocation();
        // SAFETY: System owns ptr; the caller supplies its layout and valid size.
        unsafe { System.realloc(ptr, layout, new_size) }
    }
    /// # Safety
    /// `ptr` must be a live System allocation described by `layout`.
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        // SAFETY: System allocated ptr with this layout.
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

#[test]
fn should_encode_small_compression_enabled_batch_with_two_allocations() {
    let mut buffer = RowBufferV2::new();
    buffer.set_row_count(100);
    buffer.add_column(
        ColumnMetadata {
            name: "i".to_string(),
            odbc_type: OdbcType::Integer,
        },
        ColumnData::Integer(vec![Some(7); 100]),
    );
    buffer.add_column(
        ColumnMetadata {
            name: "b".to_string(),
            odbc_type: OdbcType::BigInt,
        },
        ColumnData::BigInt(vec![None; 100]),
    );
    let mut expected = ColumnarEncoder::encode(&buffer, false).expect("reference");
    expected[14] = 1;

    ALLOCATIONS.set(Some(0));
    let result = ColumnarEncoder::encode(&buffer, true);
    let count = ALLOCATIONS.replace(None).expect("tracking enabled");

    assert_eq!(result.expect("compressed encoding"), expected);
    assert!(
        count <= 2,
        "expected output and scratch allocations only, got {count}"
    );
}
