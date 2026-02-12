// Telemetry exporters module
//
// Provides different export strategies for OpenTelemetry traces.

pub mod console;
pub mod exporters;

pub use console::export_trace;
pub use exporters::{ConsoleExporter, TelemetryExporter};
