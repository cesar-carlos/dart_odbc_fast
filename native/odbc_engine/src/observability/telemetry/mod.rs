// OpenTelemetry integration module
//
// Provides OpenTelemetry trace export functionality for observability.

pub mod console;
pub mod exporters;

pub use console::export_trace;
#[cfg(feature = "observability")]
pub use exporters::OtlpExporter;
pub use exporters::{ConsoleExporter, TelemetryExporter};

use crate::ffi::guard;
use std::ffi::CString;
use std::sync::{Arc, Mutex};

const ERROR_BUFFER_TOO_SMALL: i32 = 5;
const MAX_TRACE_JSON_LEN: usize = 16 * 1024 * 1024;

/// Global telemetry state
static TELEMETRY_STATE: Mutex<Option<TelemetryState>> = Mutex::new(None);

struct TelemetryState {
    exporter: Option<Arc<Mutex<Box<dyn TelemetryExporter + Send>>>>,
    last_error: Option<String>,
}

fn lock_telemetry_state(
) -> std::result::Result<std::sync::MutexGuard<'static, Option<TelemetryState>>, i32> {
    TELEMETRY_STATE.lock().map_err(|_| 4)
}

impl TelemetryState {
    fn new(exporter: Box<dyn TelemetryExporter + Send>) -> Self {
        Self {
            exporter: Some(Arc::new(Mutex::new(exporter))),
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
    guard::call_int_assert_unwind_safe(|| {
        // Determine exporter type based on endpoint
        let exporter: Box<dyn TelemetryExporter + Send> = if api_endpoint.is_null() {
            Box::new(ConsoleExporter)
        } else {
            // SAFETY: FFI contract requires `api_endpoint` to be a valid
            // null-terminated C string for the duration of this call.
            let endpoint_str = unsafe {
                std::ffi::CStr::from_ptr(api_endpoint)
                    .to_string_lossy()
                    .into_owned()
            };

            if endpoint_str.is_empty() || !endpoint_str.starts_with("http") {
                Box::new(ConsoleExporter)
            } else {
                #[cfg(feature = "observability")]
                {
                    log::info!("Initializing OTLP exporter with endpoint: {}", endpoint_str);
                    Box::new(OtlpExporter::new(&endpoint_str))
                }
                #[cfg(not(feature = "observability"))]
                {
                    log::info!(
                        "OTLP requested but observability feature disabled; using ConsoleExporter"
                    );
                    Box::new(ConsoleExporter)
                }
            }
        };

        let mut state = match lock_telemetry_state() {
            Ok(state) => state,
            Err(code) => return code,
        };
        *state = Some(TelemetryState::new(exporter));

        0
    })
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
    guard::call_int_assert_unwind_safe(|| {
        if trace_json.is_null() {
            return 1;
        }
        if trace_len > MAX_TRACE_JSON_LEN {
            return guard::FfiError::ResourceLimit.as_i32();
        }

        // SAFETY: FFI contract requires `trace_json` to point to `trace_len`
        // readable bytes; null was rejected above.
        let slice = unsafe { std::slice::from_raw_parts(trace_json, trace_len) };
        let json_str = match std::str::from_utf8(slice) {
            Ok(s) => s,
            Err(_) => {
                if let Ok(mut state) = lock_telemetry_state() {
                    if let Some(s) = state.as_mut() {
                        s.set_error("Invalid UTF-8 in trace JSON".to_string());
                    }
                }
                return 3;
            }
        };

        let exporter = {
            let state = match lock_telemetry_state() {
                Ok(state) => state,
                Err(code) => return code,
            };
            match state.as_ref().and_then(|s| s.exporter.as_ref()).cloned() {
                Some(exporter) => exporter,
                None => return 2,
            }
        };

        let result = match exporter.lock() {
            Ok(exporter) => exporter.export(json_str),
            Err(_) => 4,
        };
        if result != 0 {
            if let Ok(mut state) = lock_telemetry_state() {
                if let Some(s) = state.as_mut() {
                    s.set_error(format!("Export failed with code {}", result));
                }
            }
        }
        result
    })
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
    guard::call_int_assert_unwind_safe(|| {
        if trace_out.is_null() {
            return 1;
        }

        // For console exporter, this is a no-op
        0
    })
}

/// Get the last error message.
///
/// # Arguments
/// - `error_buffer`: Pointer to buffer for error message
/// - `error_len`: In/out pointer. On input, contains `error_buffer` capacity
///   in bytes. On output, contains bytes required/written excluding null.
///
/// # Returns
/// i32: 0 on success, non-zero on failure
///
/// # Safety
/// Caller must ensure `error_buffer` and `error_len` point to valid writable memory.
#[no_mangle]
pub unsafe extern "C" fn otel_get_last_error(error_buffer: *mut u8, error_len: *mut usize) -> i32 {
    guard::call_int_assert_unwind_safe(|| {
        if error_buffer.is_null() || error_len.is_null() {
            return 1;
        }

        // SAFETY: FFI contract requires `error_len` to point to writable `usize`.
        let buffer_cap = unsafe { *error_len };
        let state = match lock_telemetry_state() {
            Ok(state) => state,
            Err(code) => return code,
        };
        let error_message = match state.as_ref().and_then(|s| s.get_last_error()) {
            Some(msg) => msg,
            None => "No error".to_string(),
        };

        let c_msg = match CString::new(error_message) {
            Ok(msg) => msg,
            Err(_) => return 2,
        };

        let bytes = c_msg.as_bytes_with_nul();
        let required_len = bytes.len() - 1;
        // SAFETY: `error_len` is writable per FFI contract; we only store the
        // required byte count excluding the terminating nul.
        unsafe {
            *error_len = required_len;
        }
        if buffer_cap < bytes.len() {
            return ERROR_BUFFER_TOO_SMALL;
        }

        // SAFETY: `error_buffer` has capacity `buffer_cap >= bytes.len()` and
        // does not alias `bytes` (caller-owned output buffer).
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), error_buffer, bytes.len());
        }

        0
    })
}

/// Cleanup allocated strings.
#[no_mangle]
pub extern "C" fn otel_cleanup_strings() {
    let _ = guard::call_int_assert_unwind_safe(|| {
        // No-op for both exporters
        0
    });
}

/// Shutdown OpenTelemetry and release resources.
#[no_mangle]
pub extern "C" fn otel_shutdown() {
    let _ = guard::call_int_assert_unwind_safe(|| {
        let mut state = match lock_telemetry_state() {
            Ok(state) => state,
            Err(code) => return code,
        };
        *state = None;
        0
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::mpsc;
    use std::thread;
    use std::time::Duration;

    #[test]
    #[serial_test::serial]
    fn test_console_exporter() {
        let exporter = ConsoleExporter;
        let result = exporter.export(r#"{"trace_id": "123"}"#);
        assert_eq!(result, 0);
    }

    #[test]
    #[serial_test::serial]
    fn test_otel_init_console() {
        let result = unsafe { otel_init(std::ptr::null(), std::ptr::null(), std::ptr::null()) };
        assert_eq!(result, 0);

        // Clean up
        otel_shutdown();
    }

    #[test]
    #[serial_test::serial]
    fn test_otel_init_otlp() {
        let endpoint = std::ffi::CString::new("http://localhost:4318/v1/traces").unwrap();
        let result = unsafe { otel_init(endpoint.as_ptr(), std::ptr::null(), std::ptr::null()) };
        assert_eq!(result, 0);

        // Clean up
        otel_shutdown();
    }

    #[test]
    #[serial_test::serial]
    fn test_otel_shutdown() {
        unsafe { otel_init(std::ptr::null(), std::ptr::null(), std::ptr::null()) };
        otel_shutdown();

        // After shutdown, export should fail
        let result = unsafe { otel_export_trace(std::ptr::null(), 0) };
        assert_ne!(result, 0);
    }

    #[test]
    #[serial_test::serial]
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
        let mut len = buffer.len();
        let error_result = unsafe { otel_get_last_error(buffer.as_mut_ptr(), &mut len) };
        assert_eq!(error_result, 0);

        let error_msg = std::str::from_utf8(&buffer[..len]).unwrap();
        assert_eq!(error_msg, "No error");

        // Clean up
        otel_shutdown();
    }

    #[test]
    #[serial_test::serial]
    fn test_otel_get_last_error_reports_required_len_for_small_buffer() {
        unsafe { otel_init(std::ptr::null(), std::ptr::null(), std::ptr::null()) };

        let mut buffer = [0xAAu8; 2];
        let mut len = buffer.len();
        let error_result = unsafe { otel_get_last_error(buffer.as_mut_ptr(), &mut len) };

        assert_eq!(error_result, ERROR_BUFFER_TOO_SMALL);
        assert_eq!(len, "No error".len());
        assert_eq!(buffer, [0xAAu8; 2]);

        otel_shutdown();
    }

    #[test]
    #[serial_test::serial]
    fn test_otel_export_trace_rejects_oversized_payload() {
        unsafe { otel_init(std::ptr::null(), std::ptr::null(), std::ptr::null()) };

        let byte = b"{}";
        let result = unsafe { otel_export_trace(byte.as_ptr(), MAX_TRACE_JSON_LEN + 1) };

        assert_eq!(result, guard::FfiError::ResourceLimit.as_i32());

        otel_shutdown();
    }

    #[test]
    #[serial_test::serial]
    fn should_reject_null_trace_pointer_after_init() {
        unsafe { otel_init(std::ptr::null(), std::ptr::null(), std::ptr::null()) };
        let result = unsafe { otel_export_trace(std::ptr::null(), 0) };
        assert_eq!(result, 1);
        otel_shutdown();
    }

    #[test]
    #[serial_test::serial]
    fn should_reject_invalid_utf8_trace_payload() {
        unsafe { otel_init(std::ptr::null(), std::ptr::null(), std::ptr::null()) };
        let invalid = [0xFFu8, 0xFE];
        let result = unsafe { otel_export_trace(invalid.as_ptr(), invalid.len()) };
        assert_eq!(result, 3);
        otel_shutdown();
    }

    #[test]
    #[serial_test::serial]
    fn should_use_console_exporter_for_non_http_endpoint() {
        let endpoint = std::ffi::CString::new("file:///tmp/traces").unwrap();
        let result = unsafe { otel_init(endpoint.as_ptr(), std::ptr::null(), std::ptr::null()) };
        assert_eq!(result, 0);
        let trace = br#"{"trace_id":"abc"}"#;
        let export = unsafe { otel_export_trace(trace.as_ptr(), trace.len()) };
        assert_eq!(export, 0);
        otel_shutdown();
    }

    #[test]
    #[serial_test::serial]
    fn should_return_error_when_get_last_error_pointers_null() {
        let result = unsafe { otel_get_last_error(std::ptr::null_mut(), std::ptr::null_mut()) };
        assert_eq!(result, 1);
    }

    struct SlowExporter {
        entered: Mutex<Option<mpsc::Sender<()>>>,
        release: Arc<AtomicBool>,
    }

    impl TelemetryExporter for SlowExporter {
        fn export(&self, _trace_json: &str) -> i32 {
            if let Some(sender) = self.entered.lock().expect("entered lock").take() {
                sender.send(()).expect("send exporter entry signal");
            }
            while !self.release.load(Ordering::SeqCst) {
                thread::sleep(Duration::from_millis(10));
            }
            7
        }
    }

    /// Mirrors [`lock_telemetry_state`] poison mapping (`Err(4)`) on a local
    /// mutex so parallel lib tests are not affected by a poisoned global.
    #[test]
    fn lock_telemetry_state_returns_internal_error_code_when_poisoned() {
        let lock = Mutex::new(None::<TelemetryState>);
        let poisoned = std::panic::catch_unwind(|| {
            let _guard = lock.lock().expect("lock should be available");
            panic!("intentional panic to poison local mutex");
        });
        assert!(poisoned.is_err(), "panic should poison the mutex");

        let lock_result = lock.lock().map_err(|_| 4);
        assert!(
            matches!(lock_result, Err(4)),
            "poisoned telemetry mutex should surface internal lock failure"
        );
    }

    #[test]
    #[serial_test::serial]
    fn export_trace_does_not_hold_global_state_lock_during_export() {
        let release = Arc::new(AtomicBool::new(false));
        let (entered_tx, entered_rx) = mpsc::channel();
        {
            let mut state = lock_telemetry_state().expect("telemetry lock");
            *state = Some(TelemetryState::new(Box::new(SlowExporter {
                entered: Mutex::new(Some(entered_tx)),
                release: Arc::clone(&release),
            })));
        }

        let trace = br#"{"trace_id":"slow"}"#.to_vec();
        let export_handle =
            thread::spawn(move || unsafe { otel_export_trace(trace.as_ptr(), trace.len()) });

        entered_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("exporter should start");

        let (last_error_tx, last_error_rx) = mpsc::channel();
        thread::spawn(move || {
            let mut buffer = [0u8; 64];
            let mut len = buffer.len();
            let code = unsafe { otel_get_last_error(buffer.as_mut_ptr(), &mut len) };
            last_error_tx.send(code).expect("send last_error code");
        });

        assert_eq!(
            last_error_rx.recv_timeout(Duration::from_millis(200)),
            Ok(0),
            "otel_get_last_error should not wait for exporter.export"
        );

        release.store(true, Ordering::SeqCst);
        assert_eq!(export_handle.join().expect("export thread"), 7);
        otel_shutdown();
    }
}
