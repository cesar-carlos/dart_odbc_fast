/// Represents a telemetry trace for a single operation.
///
/// Contains information about operation execution including
/// operation name, duration, and any associated attributes.
class Trace {
  const Trace({
    required this.traceId,
    required this.name,
    required this.startTime,
    this.endTime,
    this.attributes = const {},
  });

  /// Unique identifier for this trace.
  final String traceId;

  /// Name of the operation (e.g., "odbc.query", "odbc.prepare").
  final String name;

  /// Timestamp when the operation started.
  final DateTime startTime;

  /// Timestamp when the operation ended.
  final DateTime? endTime;

  /// Additional attributes associated with this trace.
  final Map<String, String> attributes;

  /// Returns a copy of this trace with updated attributes.
  Trace copyWith({
    Map<String, String>? attributes,
    DateTime? endTime,
  }) {
    return Trace(
      traceId: traceId,
      name: name,
      startTime: startTime,
      endTime: endTime ?? this.endTime,
      attributes: attributes ?? this.attributes,
    );
  }

  @override
  String toString() {
    return 'Trace(traceId: $traceId, name: $name)';
  }
}

/// Represents a telemetry span - a segment of work with timing.
///
/// Spans can be nested to represent parent-child relationships.
class Span {
  const Span({
    required this.spanId,
    required this.name,
    required this.startTime,
    this.endTime,
    this.duration = Duration.zero,
    this.parentSpanId,
    this.traceId,
    this.attributes = const {},
  });

  /// Unique identifier for this span.
  final String spanId;

  /// Parent span ID if this is a child span.
  final String? parentSpanId;

  /// Trace ID this span belongs to.
  final String? traceId;

  /// Name of the span (e.g., "odbc.query.execution").
  final String name;

  /// Timestamp when the span started.
  final DateTime startTime;

  /// Timestamp when the span ended.
  final DateTime? endTime;

  /// Duration of the span.
  final Duration duration;

  /// Additional attributes associated with this span.
  final Map<String, String> attributes;

  /// Returns a copy of this span with updated attributes.
  Span copyWith({
    Map<String, String>? attributes,
    DateTime? endTime,
    String? parentSpanId,
  }) {
    return Span(
      spanId: spanId,
      name: name,
      startTime: startTime,
      endTime: endTime ?? this.endTime,
      duration: duration,
      parentSpanId: parentSpanId ?? this.parentSpanId,
      traceId: traceId,
      attributes: attributes ?? this.attributes,
    );
  }

  @override
  String toString() {
    return 'Span(spanId: $spanId, name: $name, '
        'duration: ${duration.inMilliseconds}ms, '
        'parent: ${parentSpanId ?? "none"})';
  }
}

/// Represents a metric value collected during operations.
///
/// Metrics can be counters, gauges, or histograms.
class Metric {
  const Metric({
    required this.name,
    required this.value,
    required this.unit,
    required this.timestamp,
    this.attributes = const {},
  });

  /// Name of the metric (e.g., "odbc.query.count", "odbc.pool.size").
  final String name;

  /// Value of the metric.
  final double value;

  /// Unit of measurement (e.g., "ms", "count", "bytes").
  final String unit;

  /// Additional attributes for filtering (e.g., connection_id, sql_hash).
  final Map<String, String> attributes;

  /// Timestamp when metric was recorded.
  final DateTime timestamp;

  @override
  String toString() {
    return 'Metric(name: $name, value: $value, '
        'unit: $unit, attributes: $attributes)';
  }
}

/// Attributes for ODBC-specific telemetry.
///
/// Provides typed access to common ODBC telemetry attributes.
class OdbcTelemetryAttributes {
  /// SQL statement being executed.
  static const String sql = 'odbc.sql';

  /// Connection ID for the operation.
  static const String connectionId = 'odbc.connection_id';

  /// Statement ID for prepared statements.
  static const String statementId = 'odbc.statement_id';

  /// Number of parameters in the query.
  static const String parameterCount = 'odbc.parameter_count';

  /// Query result row count.
  static const String rowCount = 'odbc.row_count';

  /// Error code/SQLSTATE from ODBC.
  static const String errorCode = 'odbc.error_code';

  /// Error type/category.
  static const String errorType = 'odbc.error_type';

  /// Error message text.
  static const String errorMessage = 'odbc.error_message';

  /// Cache hit/miss status.
  static const String cacheStatus = 'odbc.cache_status';

  /// Pool ID.
  static const String poolId = 'odbc.pool_id';

  /// ODBC driver name.
  static const String driverName = 'odbc.driver_name';

  /// DSN or connection string (sanitized).
  static const String dsn = 'odbc.dsn';

  /// Timeout value in milliseconds.
  static const String timeoutMs = 'odbc.timeout_ms';

  /// Fetch size used.
  static const String fetchSize = 'odbc.fetch_size';

  /// Bulk operation type.
  static const String bulkOperationType = 'odbc.bulk_operation_type';

  /// Transaction ID.
  static const String transactionId = 'odbc.transaction_id';

  /// Isolation level.
  static const String isolationLevel = 'odbc.isolation_level';

  /// Retry count.
  static const String retryCount = 'odbc.retry_count';

  /// Retry attempt number.
  static const String retryAttempt = 'odbc.retry_attempt';

  /// Query hash for cache key.
  static const String queryHash = 'odbc.query_hash';

  /// Cache size (current).
  static const String cacheSize = 'odbc.cache_size';

  /// Cache max size.
  static const String cacheMaxSize = 'odbc.cache_max_size';

  /// Memory usage in bytes.
  static const String memoryUsage = 'odbc.memory_usage';
}

/// Severity levels for telemetry events.
enum TelemetrySeverity {
  /// Debug information for development.
  debug,

  /// Informational messages about normal operation.
  info,

  /// Warning conditions that may require attention.
  warn,

  /// Error conditions that prevent normal operation.
  error,
}

/// Telemetry event for logging significant occurrences.
class TelemetryEvent {
  const TelemetryEvent({
    required this.name,
    required this.severity,
    required this.message,
    required this.timestamp,
    this.context = const {},
  });

  /// Name of the event.
  final String name;

  /// Severity level of the event.
  final TelemetrySeverity severity;

  /// Message describing the event.
  final String message;

  /// Timestamp when the event occurred.
  final DateTime timestamp;

  /// Additional context data.
  final Map<String, dynamic> context;

  @override
  String toString() {
    return 'TelemetryEvent(name: $name, severity: $severity, '
        'message: $message)';
  }
}
