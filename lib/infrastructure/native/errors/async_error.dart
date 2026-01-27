import 'package:odbc_fast/domain/errors/odbc_error.dart';

/// Error codes for async operations that cross isolate boundaries.
///
/// These codes are used by [AsyncError] to categorize different types of
/// failures that can occur during async database operations. They are
/// designed to be sendable across isolate boundaries.
enum AsyncErrorCode {
  /// Connection to the database failed.
  connectionFailed,

  /// Query execution failed.
  queryFailed,

  /// Transaction operation failed.
  transactionFailed,

  /// Prepared statement operation failed.
  prepareFailed,

  /// Invalid parameter provided.
  invalidParameter,

  /// Environment not initialized.
  notInitialized,
}

/// Sendable error type that can cross isolate boundaries.
///
/// When async operations execute in background isolates, regular [OdbcError]
/// objects cannot cross isolate boundaries directly. [AsyncError] provides
/// a sendable alternative that preserves all error information and can be
/// converted back to [OdbcError] after crossing the isolate boundary.
///
/// Example:
/// ```dart
/// try {
///   return await Isolate.run(() => native.connect(dsn));
/// } catch (e) {
///   if (e is AsyncError) rethrow;
///   throw AsyncError(
///     code: AsyncErrorCode.connectionFailed,
///     message: e.toString(),
///   );
/// }
/// ```
///
/// See also:
/// - [AsyncError.toOdbcError] to convert back to domain error types
class AsyncError implements Exception {
  /// Creates a new [AsyncError] with the given properties.
  ///
  /// All parameters are required except [sqlState] and [nativeCode],
  /// which are optional and provide additional diagnostic information.
  const AsyncError({
    required this.code,
    required this.message,
    this.sqlState,
    this.nativeCode,
  });

  /// The error code categorizing the type of failure.
  final AsyncErrorCode code;

  /// Human-readable error message.
  final String message;

  /// SQLSTATE code from the ODBC driver (if available).
  ///
  /// This is a 5-character SQLSTATE code that provides more specific
  /// information about the error. For example:
  /// - `08001` - Unable to connect to data source
  /// - `42000` - Syntax error or access violation
  /// - `23000` - Integrity constraint violation
  final String? sqlState;

  /// Database-specific native error code (if available).
  ///
  /// This is the error code from the underlying database driver.
  /// Interpretation depends on the specific database system.
  final int? nativeCode;

  @override
  String toString() {
    final buffer = StringBuffer('AsyncError: $code - $message');
    if (sqlState != null) buffer.write(' (SQLSTATE: $sqlState)');
    if (nativeCode != null) buffer.write(' (Native: $nativeCode)');
    return buffer.toString();
  }

  /// Converts this [AsyncError] to the corresponding [OdbcError] domain type.
  ///
  /// This method maps [AsyncErrorCode] to the appropriate [OdbcError]
  /// subclass (e.g., [ConnectionError], [QueryError], [ValidationError])
  /// preserving all error information including SQLSTATE and native codes.
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   final result = await asyncOperation();
  /// } on AsyncError catch (e) {
  ///   final domainError = e.toOdbcError();
  ///   // domainError is now a ConnectionError, QueryError, etc.
  ///   throw domainError;
  /// }
  /// ```
  OdbcError toOdbcError() {
    return switch (code) {
      AsyncErrorCode.connectionFailed => ConnectionError(
        message: message,
        sqlState: sqlState,
        nativeCode: nativeCode,
      ),
      AsyncErrorCode.queryFailed => QueryError(
        message: message,
        sqlState: sqlState,
        nativeCode: nativeCode,
      ),
      AsyncErrorCode.transactionFailed => QueryError(
        message: message,
        sqlState: sqlState,
        nativeCode: nativeCode,
      ),
      AsyncErrorCode.prepareFailed => QueryError(
        message: message,
        sqlState: sqlState,
        nativeCode: nativeCode,
      ),
      AsyncErrorCode.invalidParameter => ValidationError(message: message),
      AsyncErrorCode.notInitialized => const EnvironmentNotInitializedError(),
    };
  }
}
