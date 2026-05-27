/// Snapshot of Dart-side state held by the repository layer.
///
/// Useful for debugging id leaks in production (active connections,
/// statement metadata, pool checkouts) without crossing the FFI boundary.
/// Returned by `OdbcRepositoryImpl.dartSideMetrics()`.
class DartSideMetrics {
  const DartSideMetrics({
    required this.connectionCount,
    required this.statementCount,
    required this.namedParamMetadataCount,
    required this.pooledConnectionCount,
    required this.poolCheckoutCount,
    required this.connectionOptionsCount,
  });

  /// Number of live connection ids currently tracked Dart-side.
  final int connectionCount;

  /// Number of prepared statement ids currently tracked Dart-side.
  final int statementCount;

  /// Number of prepared statements that still hold cached named-param order.
  final int namedParamMetadataCount;

  /// Number of connection ids known to be checked out from a native pool.
  final int pooledConnectionCount;

  /// Total number of pooled connection checkouts across all pools (the sum
  /// of every pool's outstanding-id set).
  final int poolCheckoutCount;

  /// Number of connections that have explicit per-connection options stored.
  final int connectionOptionsCount;

  Map<String, int> toJson() => {
        'connectionCount': connectionCount,
        'statementCount': statementCount,
        'namedParamMetadataCount': namedParamMetadataCount,
        'pooledConnectionCount': pooledConnectionCount,
        'poolCheckoutCount': poolCheckoutCount,
        'connectionOptionsCount': connectionOptionsCount,
      };

  @override
  String toString() {
    final body = toJson().entries.map((e) => '${e.key}=${e.value}').join(', ');
    return 'DartSideMetrics($body)';
  }
}
