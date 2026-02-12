// Telemetry exporters for dart_odbc_fast
//
// Provides different export strategies for OpenTelemetry traces
// Console: Prints traces to stdout (for debugging)
// OTLP: Sends traces to OTLP collector (http://localhost:4318)

use std::fmt;
use std::time::Duration;
use ureq::{Agent, AgentBuilder};
use serde_json::json;

/// Exporter trait for telemetry data.
pub trait TelemetryExporter: Send {
    /// Export a trace with its associated spans and metrics.
    ///
    /// # Arguments
    /// - `trace_json`: JSON string containing serialized trace data.
    ///
    /// # Returns
    /// i32: 0 on success, error code on failure.
    fn export(&self, trace_json: &str) -> i32;

    /// Flush any pending telemetry data.
    ///
    /// # Returns
    /// i32: 0 on success, error code on failure.
    fn flush(&self) -> i32 {
        0
    }

    /// Get name of this exporter (for logging).
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
    /// - `trace_json`: JSON string containing trace.
    ///
    /// # Behavior
    /// - Prints JSON trace to console.
    /// - Returns 0 on success (non-zero would indicate failure).
    fn export(&self, trace_json: &str) -> i32 {
        println!("{}", trace_json);
        0
    }
}

/// OTLP exporter - sends traces to OpenTelemetry Protocol collector.
///
/// Uses HTTP POST to send trace data in OTLP JSON format to a collector.
/// This is the recommended exporter for production use.
pub struct OtlpExporter {
    agent: Agent,
    endpoint: String,
    timeout_seconds: u64,
}

impl OtlpExporter {
    const DEFAULT_TIMEOUT: u64 = 30;
    const DEFAULT_USER_AGENT: &str = "dart_odbc_fast/0.1.0";

    /// Creates a new OTLP exporter with specified endpoint.
    ///
    /// # Arguments
    /// - `endpoint`: OTLP collector endpoint (e.g., "http://localhost:4318/v1/traces").
    ///
    /// # Example
    /// ```
    /// let exporter = OtlpExporter::new("http://localhost:4318/v1/traces");
    /// ```
    pub fn new(endpoint: &str) -> Self {
        Self::with_timeout(endpoint, Self::DEFAULT_TIMEOUT)
    }

    /// Creates a new OTLP exporter with custom timeout.
    ///
    /// # Arguments
    /// - `endpoint`: OTLP collector endpoint.
    /// - `timeout_seconds`: Request timeout in seconds.
    pub fn with_timeout(endpoint: &str, timeout_seconds: u64) -> Self {
        let agent = AgentBuilder::new()
            .timeout(Duration::from_secs(timeout_seconds))
            .user_agent(Self::DEFAULT_USER_AGENT)
            .build();

        Self {
            agent,
            endpoint: endpoint.to_string(),
            timeout_seconds,
        }
    }

    /// Sends trace data to OTLP collector via HTTP POST.
    ///
    /// # Arguments
    /// - `trace_json`: JSON string containing trace data.
    ///
    /// # Behavior
    /// - Wraps trace JSON in OTLP ResourceSpans format.
    /// - Sends HTTP POST to configured endpoint.
    /// - Returns 0 on success, error code on failure.
    ///
    /// # OTLP Format
    /// The exporter wraps the trace JSON in OTLP v1 JSON format:
    /// ```json
    /// {
    ///   "resourceSpans": [{
    ///     "resource": {
    ///       "attributes": [{"key": "service.name", "value": {"stringValue": "odbc_fast"}}]
    ///     },
    ///     "scopeSpans": [{
    ///       "scope": {"name": "odbc_fast"},
    ///       "spans": [TRACE_JSON]
    ///     }]
    ///   }]
    /// }
    /// ```
    fn export_trace(&self, trace_json: &str) -> i32 {
        // Parse incoming trace JSON
        let trace_data: serde_json::Value = match serde_json::from_str(trace_json) {
            Ok(data) => data,
            Err(e) => {
                log::error!("Failed to parse trace JSON: {}", e);
                return 1;
            }
        };

        // Build OTLP v1 JSON format
        let otlp_payload = self.build_otlp_payload(trace_data);

        // Send HTTP POST
        let result = self.send_http_post(&otlp_payload);

        match result {
            Ok(_) => {
                log::debug!("Successfully exported trace to {}", self.endpoint);
                0
            }
            Err(e) => {
                log::error!("Failed to export trace: {}", e);
                2
            }
        }
    }

    /// Build OTLP v1 JSON payload from trace data.
    fn build_otlp_payload(&self, trace_data: serde_json::Value) -> serde_json::Value {
        // Build the OTLP payload structure manually
        let resource_spans = vec![json!({
            "resource": {
                "attributes": [{
                    "key": "service.name",
                    "value": {
                        "stringValue": "odbc_fast"
                    }
                }]
            },
            "scopeSpans": [{
                "scope": {
                    "name": "odbc_fast"
                },
                "spans": [trace_data]
            }]
        })];

        json!({ "resourceSpans": resource_spans })
    }

    /// Send HTTP POST request to OTLP endpoint.
    fn send_http_post(&self, payload: &serde_json::Value) -> Result<(), Box<dyn std::error::Error + Send>> {
        let payload_str = serde_json::to_string(payload)
            .map_err(|e| Box::new(e) as Box<dyn std::error::Error + Send>)?;

        log::debug!("Sending OTLP payload to {}: {}", self.endpoint, payload_str);

        let response = self.agent
            .post(&self.endpoint)
            .set("Content-Type", "application/json")
            .send_string(&payload_str)
            .map_err(|e| Box::new(e) as Box<dyn std::error::Error + Send>)?;

        if response.status() >= 200 && response.status() < 300 {
            Ok(())
        } else {
            Err(Box::new(std::io::Error::other(
                format!("HTTP status: {}", response.status())
            )))
        }
    }
}

impl TelemetryExporter for OtlpExporter {
    fn name(&self) -> &'static str {
        "OtlpExporter"
    }

    fn export(&self, trace_json: &str) -> i32 {
        Self::export_trace(self, trace_json)
    }
}

impl fmt::Debug for OtlpExporter {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("OtlpExporter")
            .field("endpoint", &self.endpoint)
            .field("timeout_seconds", &self.timeout_seconds)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_console_exporter_name() {
        let exporter = ConsoleExporter;
        assert_eq!(exporter.name(), "ConsoleExporter");
    }

    #[test]
    fn test_console_exporter_export() {
        let exporter = ConsoleExporter;
        let result = exporter.export(r#"{"test": "data"}"#);
        assert_eq!(result, 0);
    }

    #[test]
    fn test_otlp_exporter_name() {
        let exporter = OtlpExporter::new("http://localhost:4318");
        assert_eq!(exporter.name(), "OtlpExporter");
    }

    #[test]
    fn test_otlp_exporter_creation() {
        let exporter = OtlpExporter::new("http://localhost:4318/v1/traces");
        assert_eq!(exporter.endpoint, "http://localhost:4318/v1/traces");
        assert_eq!(exporter.timeout_seconds, 30);
    }

    #[test]
    fn test_otlp_exporter_with_custom_timeout() {
        let exporter = OtlpExporter::with_timeout("http://localhost:4318/v1/traces", 60);
        assert_eq!(exporter.endpoint, "http://localhost:4318/v1/traces");
        assert_eq!(exporter.timeout_seconds, 60);
    }

    #[test]
    fn test_otlp_payload_building() {
        let exporter = OtlpExporter::new("http://localhost:4318");

        let trace_json = r#"{
            "trace_id": "test123",
            "name": "test.operation",
            "start_time": "2024-01-01T00:00:00Z",
            "end_time": "2024-01-01T00:00:01Z",
            "attributes": {"key": "value"}
        }"#;

        let trace_data: serde_json::Value = serde_json::from_str(trace_json).unwrap();
        let payload = exporter.build_otlp_payload(trace_data);

        // Verify OTLP structure
        assert!(payload["resourceSpans"].is_array());
        assert!(payload["resourceSpans"][0]["resource"].is_object());
        assert!(payload["resourceSpans"][0]["scopeSpans"].is_array());
    }
}
