/// Options for a single prepared statement execution.
///
/// These options apply to a single execution and override
/// any connection-level or global options.
///
/// > **v3.0.0**: the legacy `asyncFetch` flag has been removed (it had no
/// > runtime effect since v2.x). For asynchronous execution use
/// > `AsyncNativeOdbcConnection` or configure `OdbcService` with the async
/// > backend.
class StatementOptions {
  const StatementOptions({
    this.timeout,
    this.fetchSize,
    this.maxBufferSize,
  });

  /// Timeout for this specific execution (overrides connection/global).
  ///
  /// When null, the connection or global timeout is used.
  final Duration? timeout;

  /// Number of rows to fetch per batch.
  ///
  /// Default: 1000. Lower values reduce memory usage for large results.
  final int? fetchSize;

  /// Maximum result buffer size in bytes.
  ///
  /// When set, caps the result buffer; otherwise uses package default.
  /// Reduces memory usage for large result sets.
  final int? maxBufferSize;
}
