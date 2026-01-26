class OdbcMetrics {
  const OdbcMetrics({
    required this.queryCount,
    required this.errorCount,
    required this.uptimeSecs,
    required this.totalLatencyMillis,
    required this.avgLatencyMillis,
  });

  final int queryCount;
  final int errorCount;
  final int uptimeSecs;
  final int totalLatencyMillis;
  final int avgLatencyMillis;
}
