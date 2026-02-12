// Console exporter - prints traces to stdout
//
// Prints OpenTelemetry traces to console for debugging and development.

/// Export a trace to stdout.
///
/// # Arguments
/// - `trace_json`: JSON string containing serialized trace data.
///
/// # Behavior
/// - Prints the JSON trace to console.
/// - Returns 0 on success (non-zero would indicate failure).
pub fn export_trace(trace_json: &str) -> i32 {
    println!("{}", trace_json);
    0
}
