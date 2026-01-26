/// Transaction isolation levels for database transactions.
///
/// Isolation levels control how transactions interact with concurrent
/// transactions and what data they can see. Higher isolation levels provide
/// better consistency but may reduce concurrency.
///
/// Example:
/// ```dart
/// final txnId = await service.beginTransaction(
///   connectionId,
///   IsolationLevel.readCommitted,
/// );
/// ```
enum IsolationLevel {
  /// Read uncommitted - lowest isolation level.
  ///
  /// Allows dirty reads, non-repeatable reads, and phantom reads.
  /// Transactions can see uncommitted changes from other transactions.
  readUncommitted(0),

  /// Read committed - default for most databases.
  ///
  /// Prevents dirty reads but allows non-repeatable reads and phantom reads.
  /// Transactions can only see committed changes.
  readCommitted(1),

  /// Repeatable read - prevents non-repeatable reads.
  ///
  /// Prevents dirty reads and non-repeatable reads but allows phantom reads.
  /// Same query within a transaction always returns the same results.
  repeatableRead(2),

  /// Serializable - highest isolation level.
  ///
  /// Prevents all concurrency issues: dirty reads, non-repeatable reads,
  /// and phantom reads. Provides the strongest consistency guarantees.
  serializable(3);

  /// Creates an [IsolationLevel] with the given numeric value.
  const IsolationLevel(this.value);

  /// Numeric value used by the ODBC driver for this isolation level.
  final int value;
}
