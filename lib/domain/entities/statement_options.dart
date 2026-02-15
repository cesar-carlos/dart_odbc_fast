/// Options for a single prepared statement execution.
///
/// These options apply to a single execution and override
/// any connection-level or global options.
class StatementOptions {
  const StatementOptions({
    this.timeout,
    this.fetchSize,
    this.maxBufferSize,
    @Deprecated(
      'asyncFetch has no runtime effect and will be removed in a future '
      'major version. Use AsyncNativeOdbcConnection/OdbcService async mode.',
    )
    this.asyncFetch = false,
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

  /// Use async fetch when available.
  ///
  /// Deprecated: this flag has no runtime effect.
  ///
  /// Keep using async mode via `AsyncNativeOdbcConnection` or service
  /// configured with async backend.
  @Deprecated(
    'asyncFetch has no runtime effect and will be removed in a future '
    'major version. Use AsyncNativeOdbcConnection/OdbcService async mode.',
  )
  final bool asyncFetch;
}
