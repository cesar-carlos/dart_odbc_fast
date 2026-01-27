/// Options for connection establishment and statement execution.
///
/// Used when calling connect to configure timeouts. [loginTimeout] is passed
/// to the ODBC driver as the login/connection timeout.
class ConnectionOptions {
  const ConnectionOptions({
    this.connectionTimeout,
    this.loginTimeout,
    this.queryTimeout,
  });

  /// Timeout for establishing the connection. When set, used as [loginTimeout]
  /// for the ODBC driver if [loginTimeout] is null.
  final Duration? connectionTimeout;

  /// Login timeout (ODBC SQL_ATTR_LOGIN_TIMEOUT). Takes precedence over
  /// [connectionTimeout] when both are set.
  final Duration? loginTimeout;

  /// Timeout for individual queries. Applied when using prepared statements
  /// with a timeout (e.g. [prepare] with [timeoutMs]).
  final Duration? queryTimeout;

  /// Effective login timeout in milliseconds: [loginTimeout] ?? [connectionTimeout],
  /// or 0 if neither is set.
  int get loginTimeoutMs {
    final d = loginTimeout ?? connectionTimeout;
    if (d == null) return 0;
    return d.inMilliseconds.clamp(0, 0x7FFFFFFF);
  }
}
