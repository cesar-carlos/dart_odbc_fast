/// Metrics for prepared statement cache and execution.
///
/// Provides insights into cache effectiveness, statement reuse,
/// and execution patterns. Useful for performance analysis and tuning.
///
/// Example:
/// ```dart
/// final metrics = service.getPreparedStatementsMetrics();
/// print('Cache hit rate: ${metrics.hitRate * 100}%');
/// print('Total executions: ${metrics.totalExecutions}');
/// ```
class PreparedStatementMetrics {
  /// Creates a new [PreparedStatementMetrics] instance.
  const PreparedStatementMetrics({
    required this.totalStatements,
    required this.totalExecutions,
    required this.cacheHits,
    required this.totalPrepares,
  });

  /// Current number of statements in the cache.
  final int totalStatements;

  /// Total number of prepared statement executions.
  final int totalExecutions;

  /// Total number of cache hits (reusing existing prepared statement).
  final int cacheHits;

  /// Total number of prepare operations (including cache misses).
  final int totalPrepares;

  /// Cache hit rate (0.0 to 1.0).
  ///
  /// Calculated as [cacheHits] / [totalPrepares] when [totalPrepares] > 0.
  double get hitRate {
    if (totalPrepares == 0) return 0.0;
    return cacheHits / totalPrepares;
  }

  /// Average executions per prepared statement.
  ///
  /// Calculated as [totalExecutions] / [totalStatements] when [totalStatements] > 0.
  double get avgExecutionsPerStatement {
    if (totalStatements == 0) return 0.0;
    return totalExecutions / totalStatements;
  }
}
