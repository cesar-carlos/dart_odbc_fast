// Telemetry exporters for dart_odbc_fast
//
// Provides different export strategies for OpenTelemetry traces
// Console: Prints traces to stdout (for debugging)
// OTLP: Sends traces to OTLP collector (http://localhost:4318)

use crate::odbc_engine::error::OdbcError;

/// Exporter trait for telemetry data.
pub trait TelemetryExporter {
    /// Export a trace with its associated spans and metrics.
    ///
    /// # Arguments
    /// - trace_json: JSON string containing serialized trace data.
    ///
    /// # Returns
    /// i32: 0 on success, error code on failure.
    fn export(&self, trace_json: &str) -> i32;

    /// Get the name of this exporter (for logging).
    fn name(&self) -> &'static str {
        "TelemetryExporter"
    }
}

/// Console exporter - prints traces to stdout for debugging.
///
/// This is useful during development to see trace data in real-time.
pub struct ConsoleExporter;

impl TelemetryExporter for ConsoleExporter {
    fn name(&self) -> &'static str {
        "ConsoleExporter"
    }

    /// Export a trace to stdout.
    ///
    /// # Arguments
    /// - trace_json: JSON string containing the trace.
    ///
    /// # Behavior
    /// - Prints the JSON trace to console.
    /// - Returns 0 on success (non-zero would indicate failure).
    fn export(&self, trace_json: &str) -> i32 {
        println!("{}", trace_json);
        0
    }
}
