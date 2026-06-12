use odbc_engine::ffi::guard::FfiError;
use odbc_engine::protocol::{ParamDirection, MULTI_RESULT_MAGIC, MULTI_RESULT_VERSION};
use std::mem::{align_of, size_of};

#[test]
fn test_abi_stability() {
    assert_eq!(size_of::<i32>(), 4);
    assert_eq!(size_of::<i64>(), 8);
    assert_eq!(size_of::<u32>(), 4);
    assert_eq!(size_of::<u64>(), 8);

    assert_eq!(align_of::<i32>(), 4);
    assert_eq!(align_of::<i64>(), 8);
    assert_eq!(align_of::<u32>(), 4);
    assert_eq!(align_of::<u64>(), 8);
}

#[test]
fn test_ffi_types() {
    use std::os::raw::{c_int, c_uint};

    assert_eq!(size_of::<c_int>(), 4);
    assert_eq!(size_of::<c_uint>(), 4);
}

#[test]
fn ffi_error_repr_is_i32_and_negative() {
    assert_eq!(size_of::<FfiError>(), size_of::<i32>());
    assert_eq!(align_of::<FfiError>(), align_of::<i32>());
    assert!(FfiError::NullPointer.as_i32() < 0);
    assert!(FfiError::InternalLock.as_i32() < 0);
}

#[test]
fn ffi_error_codes_match_documented_values() {
    assert_eq!(FfiError::NullPointer.as_i32(), -1);
    assert_eq!(FfiError::InvalidHandle.as_i32(), -2);
    assert_eq!(FfiError::InvalidArgument.as_i32(), -3);
    assert_eq!(FfiError::Panic.as_i32(), -4);
    assert_eq!(FfiError::InternalLock.as_i32(), -5);
    assert_eq!(FfiError::OdbcError.as_i32(), -6);
    assert_eq!(FfiError::Timeout.as_i32(), -7);
    assert_eq!(FfiError::ResourceLimit.as_i32(), -8);
    assert_eq!(FfiError::Cancelled.as_i32(), -9);
    assert_eq!(FfiError::Generic.as_i32(), -100);
}

#[test]
fn param_direction_repr_u8_layout() {
    assert_eq!(size_of::<ParamDirection>(), 1);
    assert_eq!(ParamDirection::Input as u8, 0);
    assert_eq!(ParamDirection::Output as u8, 1);
    assert_eq!(ParamDirection::InOut as u8, 2);
}

#[test]
fn multi_result_header_constants_are_stable() {
    assert_eq!(MULTI_RESULT_MAGIC, 0x544C_554D);
    assert_eq!(MULTI_RESULT_VERSION, 2);
    assert_eq!(MULTI_RESULT_MAGIC.to_le_bytes(), [b'M', b'U', b'L', b'T']);
}
