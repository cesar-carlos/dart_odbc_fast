/// Default maximum result buffer size in bytes (16 MB).
///
/// Used when [ConnectionOptions.maxResultBufferBytes] is null.
const int defaultMaxResultBufferBytes = 16 * 1024 * 1024;

/// Options for connection establishment and statement execution.
///
/// Used when calling connect to configure timeouts. [loginTimeout] is passed
/// to the ODBC driver as the login/connection timeout.
/// [maxResultBufferBytes] caps the size of query result buffers for this
/// connection (default [defaultMaxResultBufferBytes] when null).
class ConnectionOptions {
  const ConnectionOptions({
    this.connectionTimeout,
    this.loginTimeout,
    this.queryTimeout,
    this.maxResultBufferBytes,
  });

  /// Timeout for establishing the connection. When set, used as [loginTimeout]
  /// for the ODBC driver if [loginTimeout] is null.
  final Duration? connectionTimeout;

  /// Login timeout (ODBC SQL_ATTR_LOGIN_TIMEOUT). Takes precedence over
  /// [connectionTimeout] when both are set.
  final Duration? loginTimeout;

  /// Timeout for individual queries. Applied when using prepared statements
  /// with a timeout (e.g. `prepare` with `timeoutMs`).
  final Duration? queryTimeout;

  /// Maximum size in bytes for query result buffers on this connection.
  /// When null, [defaultMaxResultBufferBytes] is used.
  final int? maxResultBufferBytes;

  /// Effective login timeout in milliseconds:
  /// [loginTimeout] ?? [connectionTimeout], or 0 if neither is set.
  int get loginTimeoutMs {
    final d = loginTimeout ?? connectionTimeout;
    if (d == null) return 0;
    return d.inMilliseconds.clamp(0, 0x7FFFFFFF);
  }
}
