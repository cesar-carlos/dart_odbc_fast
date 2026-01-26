/// Error category for decision-making (retry, abort, reconnect, etc.)
enum ErrorCategory {
  /// Transient error - retry may resolve
  transient,

  /// Fatal error - should abort operation
  fatal,

  /// Validation error - invalid user input
  validation,

  /// Connection lost - should reconnect
  connectionLost,
}

/// Base class for all ODBC-related errors.
///
/// Provides categorization helpers to help applications make intelligent
/// decisions about error handling (retry, abort, reconnect, etc.).
sealed class OdbcError implements Exception {

  const OdbcError({
    required this.message,
    this.sqlState,
    this.nativeCode,
  });
  final String message;
  final String? sqlState;
  final int? nativeCode;

  @override
  String toString() =>
      'OdbcError: $message${sqlState != null ? ' (SQLSTATE: $sqlState)' : ''}${nativeCode != null ? ' (Code: $nativeCode)' : ''}';

  /// Returns true if the error is transient and may be retried.
  ///
  /// Connection errors with SQLSTATE starting with '08' are typically retryable,
  /// as they often indicate temporary network issues or timeouts.
  bool get isRetryable {
    if (sqlState == null) return false;
    // Connection errors (08xxx) are often retryable
    return sqlState!.startsWith('08');
  }

  /// Returns true if this is a connection-related error.
  ///
  /// Connection errors typically require reconnection rather than simple retry.
  bool get isConnectionError {
    return this is ConnectionError ||
        (sqlState != null && sqlState!.startsWith('08'));
  }

  /// Returns the error category for decision-making.
  ///
  /// Use this to determine the appropriate error handling strategy:
  /// - [ErrorCategory.transient]: Retry the operation
  /// - [ErrorCategory.fatal]: Abort the operation
  /// - [ErrorCategory.validation]: Fix user input
  /// - [ErrorCategory.connectionLost]: Reconnect and retry
  ErrorCategory get category {
    if (this is ValidationError) return ErrorCategory.validation;
    if (isConnectionError) return ErrorCategory.connectionLost;
    if (isRetryable) return ErrorCategory.transient;
    return ErrorCategory.fatal;
  }
}

/// Error during database connection establishment or maintenance.
///
/// Can indicate:
/// - Invalid credentials
/// - Server unreachable
/// - Connection timeout
/// - ODBC driver not found
/// - Network issues
///
/// Generally NOT retryable, except if SQLSTATE starts with '08' (connection errors).
/// In that case, check [isRetryable] before retrying.
final class ConnectionError extends OdbcError {
  const ConnectionError({
    required super.message,
    super.sqlState,
    super.nativeCode,
  });
}

/// Error during SQL query execution.
///
/// Can indicate:
/// - Invalid SQL syntax
/// - Constraint violation
/// - Query timeout
/// - Insufficient permissions
/// - Table/column not found
///
/// Check [isRetryable] before retrying. Most query errors are NOT retryable
/// unless they are transient (e.g., deadlock, timeout).
final class QueryError extends OdbcError {
  const QueryError({
    required super.message,
    super.sqlState,
    super.nativeCode,
  });
}

final class ValidationError extends OdbcError {
  const ValidationError({required super.message});
}

/// Error indicating the ODBC environment was not properly initialized.
///
/// This typically occurs when trying to use ODBC functions before calling
/// the initialization function. This is a fatal error and NOT retryable.
final class EnvironmentNotInitializedError extends OdbcError {
  const EnvironmentNotInitializedError()
      : super(message: 'ODBC environment not initialized');
}
