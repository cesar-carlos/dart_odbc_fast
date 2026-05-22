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

#[cfg(test)]
mod tests {
    use super::export_trace;

    #[test]
    fn should_return_zero_after_printing_trace_json() {
        assert_eq!(export_trace(r#"{"trace_id":"abc"}"#), 0);
    }

    #[test]
    fn should_accept_empty_trace_json() {
        assert_eq!(export_trace(""), 0);
    }
}
