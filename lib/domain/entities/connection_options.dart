/// Default maximum result buffer size in bytes (16 MB).
///
/// Used when [ConnectionOptions.maxResultBufferBytes] is null.
const int defaultMaxResultBufferBytes = 16 * 1024 * 1024;

/// Default maximum number of reconnect attempts when
/// [ConnectionOptions.autoReconnectOnConnectionLost] is true.
const int defaultMaxReconnectAttempts = 3;

/// Default delay between reconnect attempts when
/// [ConnectionOptions.autoReconnectOnConnectionLost] is true.
const Duration defaultReconnectBackoff = Duration(seconds: 1);

/// Default initial result buffer size in bytes (64 KB) when not set per
/// connection.
const int defaultInitialResultBufferBytes = 64 * 1024;

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
    this.initialResultBufferBytes,
    this.autoReconnectOnConnectionLost = false,
    this.maxReconnectAttempts,
    this.reconnectBackoff,
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

  /// Initial size in bytes for query result buffer allocation. When null,
  /// [defaultInitialResultBufferBytes] is used. Larger values can reduce
  /// reallocation rounds for large result sets.
  final int? initialResultBufferBytes;

  /// When true, the repository may attempt to reconnect and re-execute the
  /// operation on connection-lost errors. Default is false.
  final bool autoReconnectOnConnectionLost;

  /// Maximum number of reconnect attempts when
  /// [ConnectionOptions.autoReconnectOnConnectionLost] is true.
  /// When null, [defaultMaxReconnectAttempts] is used.
  final int? maxReconnectAttempts;

  /// Delay between reconnect attempts.
  /// When null, [defaultReconnectBackoff] is used.
  final Duration? reconnectBackoff;

  /// Effective login timeout in milliseconds:
  /// [loginTimeout] ?? [connectionTimeout], or 0 if neither is set.
  int get loginTimeoutMs {
    final d = loginTimeout ?? connectionTimeout;
    if (d == null) return 0;
    return d.inMilliseconds.clamp(0, 0x7FFFFFFF);
  }

  /// Effective max reconnect attempts when
  /// [ConnectionOptions.autoReconnectOnConnectionLost] is true.
  int get effectiveMaxReconnectAttempts =>
      maxReconnectAttempts ?? defaultMaxReconnectAttempts;

  /// Effective delay between reconnect attempts.
  Duration get effectiveReconnectBackoff =>
      reconnectBackoff ?? defaultReconnectBackoff;

  /// Returns a human-readable validation message when options are invalid.
  ///
  /// Returns null when all configured values are valid.
  String? validate() {
    if (connectionTimeout != null && connectionTimeout! < Duration.zero) {
      return 'connectionTimeout cannot be negative';
    }
    if (loginTimeout != null && loginTimeout! < Duration.zero) {
      return 'loginTimeout cannot be negative';
    }
    if (queryTimeout != null && queryTimeout! < Duration.zero) {
      return 'queryTimeout cannot be negative';
    }
    if (maxResultBufferBytes != null && maxResultBufferBytes! <= 0) {
      return 'maxResultBufferBytes must be greater than zero';
    }
    if (initialResultBufferBytes != null && initialResultBufferBytes! <= 0) {
      return 'initialResultBufferBytes must be greater than zero';
    }
    if (maxResultBufferBytes != null &&
        initialResultBufferBytes != null &&
        initialResultBufferBytes! > maxResultBufferBytes!) {
      return 'initialResultBufferBytes cannot be greater than '
          'maxResultBufferBytes';
    }
    if (maxReconnectAttempts != null && maxReconnectAttempts! < 0) {
      return 'maxReconnectAttempts cannot be negative';
    }
    if (reconnectBackoff != null && reconnectBackoff! < Duration.zero) {
      return 'reconnectBackoff cannot be negative';
    }
    return null;
  }
}
