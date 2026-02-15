// OpenTelemetry integration module
//
// Provides OpenTelemetry trace export functionality for observability.

pub mod console;
pub mod exporters;

pub use console::export_trace;
pub use exporters::{ConsoleExporter, OtlpExporter, TelemetryExporter};

use std::ffi::CString;
use std::sync::Mutex;

/// Global telemetry state
static TELEMETRY_STATE: Mutex<Option<TelemetryState>> = Mutex::new(None);

struct TelemetryState {
    exporter: Option<Box<dyn TelemetryExporter + Send>>,
    last_error: Option<String>,
}

impl TelemetryState {
    fn new(exporter: Box<dyn TelemetryExporter + Send>) -> Self {
        Self {
            exporter: Some(exporter),
            last_error: None,
        }
    }

    fn set_error(&mut self, error: String) {
        self.last_error = Some(error);
    }

    fn get_last_error(&self) -> Option<String> {
        self.last_error.clone()
    }
}

/// Initialize OpenTelemetry with specified exporter type.
///
/// # Arguments
/// - `api_endpoint`: OTLP endpoint URL (e.g., "http://localhost:4318/v1/traces")
///   - If null or empty string, uses ConsoleExporter
///   - If valid URL, uses OtlpExporter
/// - `_resource_attributes`: Unused (reserved for resource attributes)
/// - `_resource`: Unused (reserved for resource name)
///
/// # Returns
/// i32: 0 on success, non-zero on failure
///
/// # Safety
/// Caller must ensure `api_endpoint` points to a valid null-terminated C string
/// for the lifetime of the function call. The `_resource_attributes`
/// and `_resource` parameters are unused and reserved for future use.
#[no_mangle]
pub unsafe extern "C" fn otel_init(
    api_endpoint: *const i8,
    _resource_attributes: *const u8,
    _resource: *const u8,
) -> i32 {
    // Determine exporter type based on endpoint
    let exporter: Box<dyn TelemetryExporter + Send> = if api_endpoint.is_null() {
        Box::new(ConsoleExporter)
    } else {
        let endpoint_str = unsafe {
            std::ffi::CStr::from_ptr(api_endpoint)
                .to_string_lossy()
                .into_owned()
        };

        if endpoint_str.is_empty() || !endpoint_str.starts_with("http") {
            // Use console exporter for invalid/empty endpoints
            Box::new(ConsoleExporter)
        } else {
            // Use OTLP exporter for valid HTTP endpoints
            log::info!("Initializing OTLP exporter with endpoint: {}", endpoint_str);
            Box::new(OtlpExporter::new(&endpoint_str))
        }
    };

    let mut state = TELEMETRY_STATE.lock().unwrap();
    *state = Some(TelemetryState::new(exporter));

    0
}

/// Export a trace using the configured exporter.
///
/// # Arguments
/// - `trace_json`: Pointer to JSON string containing trace data
/// - `trace_len`: Length of the trace JSON string
///
/// # Returns
/// i32: 0 on success, non-zero on failure
///
/// # Safety
/// Caller must ensure `trace_json` points to valid memory for `trace_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn otel_export_trace(trace_json: *const u8, trace_len: usize) -> i32 {
    if trace_json.is_null() {
        return 1;
    }

    let mut state = TELEMETRY_STATE.lock().unwrap();
    let telemetry_state = match state.as_ref() {
        Some(s) => s,
        None => return 2,
    };

    // Convert bytes to string
    let slice = unsafe { std::slice::from_raw_parts(trace_json, trace_len) };
    let json_str = match std::str::from_utf8(slice) {
        Ok(s) => s,
        Err(_) => {
            if let Some(s) = state.as_mut() {
                s.set_error("Invalid UTF-8 in trace JSON".to_string());
            }
            return 3;
        }
    };

    // Export using configured exporter
    let result = if let Some(exporter) = &telemetry_state.exporter {
        exporter.export(json_str)
    } else {
        0
    };
    if result != 0 {
        if let Some(s) = state.as_mut() {
            s.set_error(format!("Export failed with code {}", result));
        }
    }
    result
}

/// Export a trace to a string buffer.
///
/// # Arguments
/// - `trace_out`: Pointer to output buffer
/// - `_trace_len`: Length of the trace data (unused for console exporter)
///
/// # Returns
/// i32: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn otel_export_trace_to_string(trace_out: *mut u8, _trace_len: usize) -> i32 {
    if trace_out.is_null() {
        return 1;
    }

    // For console exporter, this is a no-op
    0
}

/// Get the last error message.
///
/// # Arguments
/// - `error_buffer`: Pointer to buffer for error message
/// - `error_len`: Pointer to length of error message
///
/// # Returns
/// i32: 0 on success, non-zero on failure
///
/// # Safety
/// Caller must ensure `error_buffer` and `error_len` point to valid writable memory.
#[no_mangle]
pub unsafe extern "C" fn otel_get_last_error(error_buffer: *mut u8, error_len: *mut usize) -> i32 {
    if error_buffer.is_null() || error_len.is_null() {
        return 1;
    }

    let state = TELEMETRY_STATE.lock().unwrap();
    let error_message = match state.as_ref().and_then(|s| s.get_last_error()) {
        Some(msg) => msg,
        None => "No error".to_string(),
    };

    let c_msg = match CString::new(error_message) {
        Ok(msg) => msg,
        Err(_) => return 2,
    };

    let bytes = c_msg.as_bytes_with_nul();
    let len = bytes.len();

    unsafe {
        // Copy error message to buffer
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), error_buffer, len);

        // Set length
        *error_len = len - 1; // Exclude null terminator
    }

    0
}

/// Cleanup allocated strings.
#[no_mangle]
pub extern "C" fn otel_cleanup_strings() {
    // No-op for both exporters
}

/// Shutdown OpenTelemetry and release resources.
#[no_mangle]
pub extern "C" fn otel_shutdown() {
    let mut state = TELEMETRY_STATE.lock().unwrap();
    *state = None;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_console_exporter() {
        let exporter = ConsoleExporter;
        let result = exporter.export(r#"{"trace_id": "123"}"#);
        assert_eq!(result, 0);
    }

    #[test]
    fn test_otel_init_console() {
        let result = unsafe { otel_init(std::ptr::null(), std::ptr::null(), std::ptr::null()) };
        assert_eq!(result, 0);

        // Clean up
        otel_shutdown();
    }

    #[test]
    fn test_otel_init_otlp() {
        let endpoint = std::ffi::CString::new("http://localhost:4318/v1/traces").unwrap();
        let result = unsafe { otel_init(endpoint.as_ptr(), std::ptr::null(), std::ptr::null()) };
        assert_eq!(result, 0);

        // Clean up
        otel_shutdown();
    }

    #[test]
    fn test_otel_shutdown() {
        unsafe { otel_init(std::ptr::null(), std::ptr::null(), std::ptr::null()) };
        otel_shutdown();

        // After shutdown, export should fail
        let result = unsafe { otel_export_trace(std::ptr::null(), 0) };
        assert_ne!(result, 0);
    }

    #[test]
    fn test_otel_get_last_error() {
        // Initialize with null endpoint (console exporter)
        unsafe { otel_init(std::ptr::null(), std::ptr::null(), std::ptr::null()) };

        // Export a valid trace
        let trace_json =
            r#"{"trace_id": "test", "name": "test.op", "start_time": "2024-01-01T00:00:00Z"}"#;
        let trace_bytes = trace_json.as_bytes();
        let result = unsafe { otel_export_trace(trace_bytes.as_ptr(), trace_bytes.len()) };
        assert_eq!(result, 0);

        // Get last error should be "No error"
        let mut buffer = [0u8; 256];
        let mut len = 0usize;
        let error_result = unsafe { otel_get_last_error(buffer.as_mut_ptr(), &mut len) };
        assert_eq!(error_result, 0);

        let error_msg = std::str::from_utf8(&buffer[..len]).unwrap();
        assert_eq!(error_msg, "No error");

        // Clean up
        otel_shutdown();
    }
}
