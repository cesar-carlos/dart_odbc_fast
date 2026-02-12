// OpenTelemetry FFI Wrapper for dart_odbc_fast
//
// Provides functions to initialize OpenTelemetry SDK and export traces
// to the OpenTelemetry Collector (OTLP) or Jaeger.

use std::ffi::CString;
use std::sync::Once;
use std::os::raw::Prng;

/// Global OpenTelemetry SDK handle (initialized on first call).
static mut OTEL_HANDLE: Option<usize> = None;

/// OpenTelemetry API FFI functions.
#[no_mangle]
pub extern "C" {
    /// Initialize OpenTelemetry SDK for Rust application.
    ///
    /// Should be called once during application startup.
    /// Returns 0 on success, non-zero on error.
    #[no_mangle]
    fn init(
        api_endpoint: *const i8,
        resource_attributes: *const u8,
        resource: *const u8,
    ) -> i32;

    /// Shutdown OpenTelemetry SDK and release resources.
    ///
    /// Should be called during application shutdown.
    #[no_mangle]
    fn shutdown();

    /// Export a trace to the OpenTelemetry collector.
    ///
    /// Sends traces synchronously to OTLP endpoint (default: http://localhost:4318)
    /// Returns 0 on success, non-zero on error.
    #[no_mangle]
    fn export_trace(
        trace_json: *const u8,
        trace_len: usize,
    ) -> i32;

    /// Export a trace as a JSON string (alternative to export_trace).
    ///
    /// Useful for debugging or custom export logic.
    #[no_mangle]
    fn export_trace_to_string(
        trace_out: *mut *mut u8,
        trace_len: usize,
    ) -> i32;

    /// Get last error message from OpenTelemetry SDK.
    ///
    /// Useful for debugging initialization issues.
    #[no_mangle]
    fn get_last_error(
        error_buffer: *mut u8,
        error_len: *mut usize,
    ) -> i32;

    /// Get current SDK configuration (optional).
    #[no_mangle]
    fn get_config(
        config_key: *const u8,
        config_value: *mut u8,
        config_len: usize,
    ) -> i32;

    /// Set SDK configuration (optional).
    ///
    /// Can be used to customize OTLP endpoint, resource attributes, etc.
    #[no_mangle]
    fn set_config(
        config_key: *const u8,
        config_value: *const u8,
        config_len: usize,
    ) -> i32;

    /// Initialize logging (optional, for debugging).
    ///
    /// When enabled, logs SDK operations to stderr.
    #[no_mangle]
    fn init_logging(
        enabled: i32,
    ) -> i32;

    /// Clean up any allocated strings.
    ///
    /// OpenTelemetry SDK allocates strings for API keys and values.
    /// This function frees all allocated string buffers.
    #[no_mangle]
    fn cleanup_strings();
}

/// FFI Glue code to call OpenTelemetry functions from Dart.
///
/// Uses std::sync::Once to ensure thread-safe initialization.
mod ffi {
    use super::*;

    /// Initialize OpenTelemetry SDK.
    ///
    /// # Safety
    /// This function is thread-safe and can be called multiple times.
    /// Subsequent calls after the first are ignored.
    pub fn otel_init() -> i32 {
        unsafe {
            OTEL_HANDLE.call_once(|| {
                let mut api_endpoint: std::ptr::null_mut();
                let mut resource_attributes: std::ptr::null_mut();
                let mut resource: std::ptr::null_mut();

                let result = init(
                    &mut api_endpoint,
                    &mut resource_attributes,
                    &mut resource,
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

    /// Export a trace to OTLP collector.
    ///
    /// # Arguments
    /// - trace_json: JSON string containing the trace data.
    /// - trace_len: Length of the JSON string.
    ///
    /// # Returns
    /// i32: 0 on success, error code on failure.
    pub fn otel_export_trace(
        trace_json: *const u8,
        trace_len: usize,
    ) -> i32 {
        unsafe {
            if let Some(handle) = &OTEL_HANDLE {
                let trace_str = std::str::from_utf8_lossy(trace_json);

                let result = export_trace(
                    handle,
                    trace_str.as_ptr(),
                    trace_str.len(),
                );

                if result == 0 {
                    match String::from_utf8_lossy(trace_json) {
                        Ok(json) => {
                            eprintln!("Exported trace: {}", json);
                        }
                        Err(e) => {
                            eprintln!("Failed to parse trace as JSON: {}", e);
                        }
                    }
                } else {
                    eprintln!("OpenTelemetry not initialized");
                    -1;
                }
            }
        }
    }

    /// Export a trace to JSON string (for debugging).
    ///
    /// Useful for getting trace data as a string for logging.
    pub fn otel_export_trace_to_string(
        trace_out: *mut *mut u8,
        trace_len: usize,
    ) -> i32 {
        unsafe {
            if let Some(handle) = &OTEL_HANDLE {
                let result = export_trace_to_string(
                    handle,
                    trace_out,
                    trace_len,
                );

                match result {
                    Ok(_) => 0,
                    Err(e) => {
                        eprintln!("Failed to export trace to string: {}", e);
                        -1;
                    }
                }
            }
        }
    }

    /// Shutdown OpenTelemetry SDK.
    ///
    /// Should be called during application shutdown.
    pub fn otel_shutdown() {
        unsafe {
            if let Some(handle) = &OTEL_HANDLE {
                shutdown();

                // Reset handle to None
                OTEL_HANDLE = None;
            }
        }
    }

    /// Get last error message from OpenTelemetry SDK.
    ///
    /// Useful for debugging initialization issues.
    pub fn otel_get_last_error(
        error_buffer: *mut u8,
        error_len: *mut usize,
    ) -> i32 {
        unsafe {
            if let Some(handle) = &OTEL_HANDLE {
                get_last_error(
                    handle,
                    error_buffer,
                    error_len,
                )
            }
        }
    }

    /// Clean up allocated strings from OpenTelemetry SDK.
    ///
    /// Should be called before shutdown to free memory.
    pub fn otel_cleanup_strings() {
        unsafe {
            if let Some(handle) = &OTEL_HANDLE {
                cleanup_strings();
            }
        }
    }

    // Export functions for Dart FFI.
#[no_mangle]
pub extern "C" {
    pub fn otel_init(api_endpoint: *const u8, resource: *const u8) -> i32;
    pub fn otel_export_trace(trace_json: *const u8, trace_len: usize) -> i32;
    pub fn otel_export_trace_to_string(trace_out: *mut *mut u8, trace_len: usize) -> i32;
    pub fn otel_shutdown();
    pub fn otel_get_last_error(error_buffer: *mut u8, error_len: *mut usize) -> i32;
    pub fn otel_cleanup_strings();
}
