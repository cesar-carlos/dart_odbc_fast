/// Whether a transaction is allowed to mutate state.
///
/// Equivalent of the SQL-92 `READ ONLY` / `READ WRITE` modifier on
/// `SET TRANSACTION`. Setting [readOnly] lets the engine skip locking
/// (PostgreSQL, MySQL/MariaDB), pick a snapshot path (Oracle), or simply
/// reject any DML attempt during the transaction.
///
/// Engines without an equivalent SQL hint (SQL Server, SQLite, Snowflake)
/// silently treat [readOnly] as a no-op so callers can program against
/// the abstraction unconditionally.
///
/// Example:
/// ```dart
/// final txnId = await service.beginTransaction(
///   connectionId,
///   IsolationLevel.repeatableRead,
///   savepointDialect: SavepointDialect.auto,
///   accessMode: TransactionAccessMode.readOnly,
/// );
/// ```
///
/// Sprint 4.1 — see `doc/notes/FUTURE_IMPLEMENTATIONS.md` §4.1.
enum TransactionAccessMode {
  /// Default. Transaction may execute any DML/DDL allowed by the user's
  /// privileges. Equivalent to `READ WRITE` on SQL-92 engines.
  readWrite(0),

  /// Transaction may not execute DML or DDL. Drivers that support the
  /// hint use it to skip locking and (where applicable) take a snapshot
  /// read path.
  ///
  /// **Engine matrix**:
  /// - PostgreSQL, MySQL, MariaDB, DB2, Oracle: emits
  ///   `SET TRANSACTION READ ONLY`.
  /// - SQL Server, SQLite, Snowflake, others: silent no-op (logged at
  ///   debug); enforce with explicit `DENY` grants instead.
  readOnly(1);

  const TransactionAccessMode(this.code);

  /// Stable wire code passed to the native FFI `odbc_transaction_begin_v2`.
  /// Must match `TransactionAccessMode::from_u32` on the Rust side.
  final int code;
}
