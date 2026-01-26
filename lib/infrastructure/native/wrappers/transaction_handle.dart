import 'package:odbc_fast/infrastructure/native/odbc_connection_backend.dart';

/// Wrapper for transaction operations.
///
/// Provides convenient methods to commit or rollback a transaction.
///
/// Example:
/// ```dart
/// final txn = TransactionHandle(backend, txnId);
/// // ... perform operations ...
/// txn.commit();
/// ```
class TransactionHandle {
  /// Creates a new [TransactionHandle] instance.
  ///
  /// The [backend] must be a valid [OdbcConnectionBackend] instance.
  /// The [txnId] must be a valid transaction identifier.
  TransactionHandle(this._backend, this._txnId);

  final OdbcConnectionBackend _backend;
  final int _txnId;

  /// The transaction identifier.
  int get txnId => _txnId;

  /// Commits the transaction.
  ///
  /// Returns true on success, false on failure.
  bool commit() => _backend.commitTransaction(_txnId);

  /// Rolls back the transaction.
  ///
  /// Returns true on success, false on failure.
  bool rollback() => _backend.rollbackTransaction(_txnId);
}
