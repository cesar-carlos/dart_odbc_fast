part of 'odbc_native.dart';

/// Performance and operational metrics from the ODBC engine.
///
/// Contains query counts, error counts, uptime, and latency statistics.
class OdbcMetrics {
  /// Creates a new [OdbcMetrics] instance.
  ///
  /// The [queryCount] is the total number of queries executed.
  /// The [errorCount] is the total number of errors encountered.
  /// The [uptimeSecs] is the engine uptime in seconds.
  /// The [totalLatencyMillis] is the total query latency in milliseconds.
  /// The [avgLatencyMillis] is the average query latency in milliseconds.
  const OdbcMetrics({
    required this.queryCount,
    required this.errorCount,
    required this.uptimeSecs,
    required this.totalLatencyMillis,
    required this.avgLatencyMillis,
  });

  /// Total number of queries executed.
  final int queryCount;

  /// Total number of errors encountered.
  final int errorCount;

  /// Uptime in seconds.
  final int uptimeSecs;

  /// Total query latency in milliseconds.
  final int totalLatencyMillis;

  /// Average query latency in milliseconds.
  final int avgLatencyMillis;

  /// Deserializes [OdbcMetrics] from binary data.
  ///
  /// The [b] must contain at least 40 bytes of metrics data.
  // Factory method pattern preferred for deserialization.
  // Reason: fromBytes mirrors cbindgen layout factory; AUDIT-DART-2026-06,
  // remove when a named constructor can replace the static without ABI churn.
  // ignore: prefer_constructors_over_static_methods
  static OdbcMetrics fromBytes(Uint8List b) {
    final d = ByteData.sublistView(b);
    return OdbcMetrics(
      queryCount: d.getUint64(0, Endian.little),
      errorCount: d.getUint64(8, Endian.little),
      uptimeSecs: d.getUint64(16, Endian.little),
      totalLatencyMillis: d.getUint64(24, Endian.little),
      avgLatencyMillis: d.getUint64(32, Endian.little),
    );
  }
}

/// Deserializes [PreparedStatementMetrics] from binary data.
///
/// The [b] must contain at least 64 bytes of metrics data.
PreparedStatementMetrics fromBytes(Uint8List b) {
  final d = ByteData.sublistView(b);
  return PreparedStatementMetrics(
    cacheSize: d.getUint64(0, Endian.little),
    cacheMaxSize: d.getUint64(8, Endian.little),
    cacheHits: d.getUint64(16, Endian.little),
    cacheMisses: d.getUint64(24, Endian.little),
    totalPrepares: d.getUint64(32, Endian.little),
    totalExecutions: d.getUint64(40, Endian.little),
    memoryUsageBytes: d.getUint64(48, Endian.little),
    avgExecutionsPerStmt: d.getFloat64(56, Endian.little),
  );
}

/// Result of a stream fetch operation.
///
/// Contains success status, fetched data, and whether more data is available.
class StreamFetchResult {
  /// Creates a new [StreamFetchResult] instance.
  ///
  /// The [success] indicates if the fetch operation succeeded.
  /// The [data] contains the fetched data, or null if no data or on failure.
  /// The [hasMore] indicates if more data is available in the stream.
  StreamFetchResult({
    required this.success,
    required this.data,
    required this.hasMore,
  });

  /// Whether the fetch operation succeeded.
  final bool success;

  /// Fetched data, or null if no data or on failure.
  final Uint8List? data;

  /// Whether more data is available in the stream.
  final bool hasMore;
}
