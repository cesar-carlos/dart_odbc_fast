/// Performance and operational metrics for the ODBC engine.
///
/// Provides insights into query execution, error rates, and system uptime.
/// Useful for monitoring, debugging, and performance analysis.
///
/// Example:
/// ```dart
/// final metrics = await service.getMetrics();
/// print('Queries executed: ${metrics.queryCount}');
/// print('Average latency: ${metrics.avgLatencyMillis}ms');
/// ```
class OdbcMetrics {
  /// Creates a new [OdbcMetrics] instance.
  const OdbcMetrics({
    required this.queryCount,
    required this.errorCount,
    required this.uptimeSecs,
    required this.totalLatencyMillis,
    required this.avgLatencyMillis,
  });

  /// Total number of queries executed since engine initialization.
  final int queryCount;

  /// Total number of errors encountered since engine initialization.
  final int errorCount;

  /// Total uptime in seconds since engine initialization.
  final int uptimeSecs;

  /// Total cumulative latency in milliseconds for all queries.
  final int totalLatencyMillis;

  /// Average query latency in milliseconds.
  ///
  /// Calculated as [totalLatencyMillis] / [queryCount] when [queryCount] > 0.
  final int avgLatencyMillis;
}
