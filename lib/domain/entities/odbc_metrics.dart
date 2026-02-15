import 'dart:typed_data';

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

/// Metrics for prepared statement cache.
///
/// Provides insights into cache effectiveness, memory usage, and
/// statement execution patterns.
///
/// Example:
/// ```dart
/// final metrics = await service.getPreparedStatementsMetrics();
/// print('Cache hit rate: ${metrics.cacheHitRate}%');
/// print('Avg executions per statement: ${metrics.avgExecutionsPerStmt}');
/// ```
class PreparedStatementMetrics {
  /// Creates a new [PreparedStatementMetrics] instance.
  const PreparedStatementMetrics({
    required this.cacheSize,
    required this.cacheMaxSize,
    required this.cacheHits,
    required this.cacheMisses,
    required this.totalPrepares,
    required this.totalExecutions,
    required this.memoryUsageBytes,
    required this.avgExecutionsPerStmt,
  });

  /// Deserializes [PreparedStatementMetrics] from binary format.
  ///
  /// Binary format (64 bytes, little-endian):
  /// - Bytes 0-7: cacheSize (u64)
  /// - Bytes 8-15: cacheMaxSize (u64)
  /// - Bytes 16-23: cacheHits (u64)
  /// - Bytes 24-31: cacheMisses (u64)
  /// - Bytes 32-39: totalPrepares (u64)
  /// - Bytes 40-47: totalExecutions (u64)
  /// - Bytes 48-55: memoryUsageBytes (u64)
  /// - Bytes 56-63: avgExecutionsPerStmt (f64)
  factory PreparedStatementMetrics.fromBytes(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    return PreparedStatementMetrics(
      cacheSize: data.getUint64(0, Endian.little),
      cacheMaxSize: data.getUint64(8, Endian.little),
      cacheHits: data.getUint64(16, Endian.little),
      cacheMisses: data.getUint64(24, Endian.little),
      totalPrepares: data.getUint64(32, Endian.little),
      totalExecutions: data.getUint64(40, Endian.little),
      memoryUsageBytes: data.getUint64(48, Endian.little),
      avgExecutionsPerStmt: data.getFloat64(56, Endian.little),
    );
  }

  /// Current number of cached SQL statements.
  final int cacheSize;

  /// Maximum cache capacity (LRU eviction threshold).
  final int cacheMaxSize;

  /// Number of times a prepared statement was found in cache.
  final int cacheHits;

  /// Number of times a prepared statement was not in cache (was prepared).
  final int cacheMisses;

  /// Total number of statement prepare operations performed.
  final int totalPrepares;

  /// Total number of statement executions performed.
  final int totalExecutions;

  /// Estimated memory usage of cache in bytes.
  final int memoryUsageBytes;

  /// Average executions per prepared statement.
  ///
  /// Calculated as [totalExecutions] / [totalPrepares] when [totalPrepares] > 0.
  final double avgExecutionsPerStmt;

  /// Total cache accesses (hits + misses).
  int get totalCacheAccesses => cacheHits + cacheMisses;

  /// Cache hit rate as a percentage (0.0 to 100.0).
  ///
  /// Returns 0 if there are no accesses.
  double get cacheHitRate {
    final total = totalCacheAccesses;
    if (total == 0) return 0;
    return (cacheHits / total) * 100.0;
  }

  /// Cache miss rate as a percentage (0.0 to 100.0).
  ///
  /// Returns 0 if there are no accesses.
  double get cacheMissRate {
    final total = totalCacheAccesses;
    if (total == 0) return 0;
    return (cacheMisses / total) * 100.0;
  }

  /// Cache utilization as a percentage (0.0 to 100.0).
  ///
  /// Returns 0 if cacheMaxSize is 0.
  double get cacheUtilization {
    if (cacheMaxSize == 0) return 0;
    return (cacheSize / cacheMaxSize) * 100.0;
  }
}
