pub mod logging;
pub mod metrics;
pub mod telemetry;
pub mod tracing;

pub use logging::{sanitize_sql_for_log, StructuredLogger, ENV_LOG_RAW_SQL};
pub use metrics::{Metrics, PoolMetrics, QueryMetrics};
pub use tracing::{QuerySpan, SpanGuard, Tracer};

// OpenTelemetry FFI exports
pub use telemetry::{
    otel_cleanup_strings, otel_export_trace, otel_export_trace_to_string, otel_get_last_error,
    otel_init, otel_shutdown,
};
