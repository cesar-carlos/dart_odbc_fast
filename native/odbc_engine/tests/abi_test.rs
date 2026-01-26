#[test]
fn test_abi_stability() {
    assert_eq!(std::mem::size_of::<i32>(), 4);
    assert_eq!(std::mem::size_of::<i64>(), 8);
    assert_eq!(std::mem::size_of::<u32>(), 4);
    assert_eq!(std::mem::size_of::<u64>(), 8);

    assert_eq!(std::mem::align_of::<i32>(), 4);
    assert_eq!(std::mem::align_of::<i64>(), 8);
    assert_eq!(std::mem::align_of::<u32>(), 4);
    assert_eq!(std::mem::align_of::<u64>(), 8);
}

#[test]
fn test_ffi_types() {
    use std::os::raw::{c_int, c_uint};

    assert_eq!(std::mem::size_of::<c_int>(), 4);
    assert_eq!(std::mem::size_of::<c_uint>(), 4);
}
