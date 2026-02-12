pub mod logging;
pub mod metrics;
pub mod tracing;
pub mod telemetry;

pub use logging::StructuredLogger;
pub use metrics::{Metrics, PoolMetrics, QueryMetrics};
pub use tracing::{QuerySpan, Tracer};

// OpenTelemetry FFI exports
pub use telemetry::{
    otel_cleanup_strings, otel_export_trace, otel_export_trace_to_string,
    otel_get_last_error, otel_init, otel_shutdown,
};
