/// Options for a single prepared statement execution.
///
/// These options apply to a single execution and override
/// any connection-level or global options.
class StatementOptions {
  const StatementOptions({
    this.timeout,
    this.fetchSize,
  });

  /// Timeout for this specific execution (overrides connection/global).
  ///
  /// When null, the connection or global timeout is used.
  final Duration? timeout;

  /// Number of rows to fetch per batch.
  ///
  /// Default: 1000. Lower values reduce memory usage for large results.
  final int? fetchSize;
}
