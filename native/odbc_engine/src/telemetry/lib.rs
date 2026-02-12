// Telemetry module for dart_odbc_fast
//
// Integrates OpenTelemetry SDK for distributed tracing
// with ODBC operations.

use crate::std::ffi::CString;
use crate::odbc_engine;

/// OpenTelemetry SDK handle (lazy_static, initialized on first call).
static mut OTEL_HANDLE: Option<&'static libOpenTelemetry> = None;

/// Initialize OpenTelemetry SDK for Rust backend.
///
/// # Safety
/// This function is thread-safe and can be called multiple times.
/// Subsequent calls after the first are ignored.
#[no_mangle]
pub fn init_telemetry() {
    unsafe {
            OTEL_HANDLE.call_once(|| {
                // Default OTLP endpoint: http://localhost:4318
                let api_endpoint = std::ptr::null_mut();
                let mut resource = std::ptr::null_mut();

                let result = super::init(
                    api_endpoint,
                    resource,
                    resource,
                );

                if result == 0 {
                    OTEL_HANDLE = Some(Box::leak(otel_handle as *const _ as usize));
                } else {
                    // Failed to initialize
                    eprintln!("Failed to initialize OpenTelemetry: error code {}", result);
                }
            })
        }
    }
}

/// Export a trace to the OpenTelemetry collector.
///
/// Sends traces synchronously to OTLP endpoint.
/// Returns 0 on success, error code on failure.
#[no_mangle]
pub fn export_trace(
    sql: &str,
    connection_id: &str,
    row_count: i32,
    status: &str,
    error_type: &str,
    error_message: &str,
) -> i32 {
    unsafe {
            if let Some(handle) = &OTEL_HANDLE {
                // Prepare JSON for ODBC attributes
                let mut json = String::new();
                json.push_str(&format!(r#"{{"connection_id": "{}", "sql": "{}", "row_count": {}, "status": "{}"}}"#,
                    sql.replace('"', r#"\"#),
                    connection_id.replace('"', r#"\"#),
                    row_count,
                    status,
                );

                // Add custom ODBC attributes
                if !error_type.is_empty() {
                    json.push_str(&format!(r#", "error_type": "{}", "error_message": "{}""#, error_type.replace('"', r#"\"#)));
                }

                if !error_message.is_empty() {
                    json.push_str(&format!(r#", "error_message": "{}""#, error_message.replace('"', r#"\"#)));
                }

                // Convert to C string
                let json_cstring = std::ffi::CString::new(json.clone()).unwrap();

                // Get trace data
                let trace_json = crate::odbc_engine::async_bridge::get_current_trace();
                let trace_len = trace_json.len() as i32;

                // Export
                let result = super::export_trace(
                    json_cstring.as_ptr(),
                    trace_len,
                );

                // Free the JSON string
                let _ = json_cstring;

                match result {
                    Ok(_) => {
                        // Successfully exported
                        0
                    }
                    Err(code) => {
                        // Failed to export
                        code
                    }
                }
            }
        }
    }
}

/// Shutdown OpenTelemetry.
#[no_mangle]
pub fn shutdown_telemetry() {
    unsafe {
            if let Some(handle) = &OTEL_HANDLE {
                super::shutdown();
                OTEL_HANDLE = None;
            }
    }
}
