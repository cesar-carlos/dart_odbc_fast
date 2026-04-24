//! C2 - Telemetry FFI must honor caller-provided buffer capacity.

use odbc_engine::observability::telemetry::{
    otel_export_trace, otel_get_last_error, otel_init, otel_shutdown,
};

#[test]
fn get_last_error_does_not_copy_when_buffer_is_too_small() {
    unsafe {
        assert_eq!(
            otel_init(std::ptr::null(), std::ptr::null(), std::ptr::null()),
            0
        );
    }

    let mut buffer = [0xAAu8; 2];
    let mut len = buffer.len();
    let result = unsafe { otel_get_last_error(buffer.as_mut_ptr(), &mut len) };

    assert_ne!(result, 0);
    assert_eq!(len, "No error".len());
    assert_eq!(buffer, [0xAAu8; 2]);

    otel_shutdown();
}

#[test]
fn export_trace_invalid_utf8_sets_readable_error() {
    unsafe {
        assert_eq!(
            otel_init(std::ptr::null(), std::ptr::null(), std::ptr::null()),
            0
        );
    }

    let invalid = [0xFFu8, 0xFEu8];
    let result = unsafe { otel_export_trace(invalid.as_ptr(), invalid.len()) };
    assert_ne!(result, 0);

    let mut buffer = [0u8; 128];
    let mut len = buffer.len();
    let error_result = unsafe { otel_get_last_error(buffer.as_mut_ptr(), &mut len) };

    assert_eq!(error_result, 0);
    let error = std::str::from_utf8(&buffer[..len]).expect("valid error utf8");
    assert_eq!(error, "Invalid UTF-8 in trace JSON");

    otel_shutdown();
}
