/// SQL dialect used to emit `SAVEPOINT` statements within a transaction.
///
/// Different RDBMSs use incompatible syntax for nested savepoints:
///
/// - **SQL-92**: `SAVEPOINT name` / `ROLLBACK TO SAVEPOINT name` /
///   `RELEASE SAVEPOINT name` (PostgreSQL, MySQL, MariaDB, Oracle, SQLite,
///   Db2, Snowflake, ...).
/// - **SQL Server**: `SAVE TRANSACTION name` / `ROLLBACK TRANSACTION name`
///   (no `RELEASE` — savepoints are released automatically on
///   commit/rollback).
///
/// The native engine maps each value to the integer code below before sending
/// it across the FFI boundary.
///
/// See also `Transaction::begin_with_dialect` (Rust) and the `B2` fix in v3.1
/// that closed the gap where Dart could not reach the SQL Server dialect.
enum SavepointDialect {
  /// Detect the right dialect at runtime by asking the live driver via
  /// `SQLGetInfo(SQL_DBMS_NAME)`. SQL Server resolves to [sqlServer]; every
  /// other engine (PostgreSQL, MySQL, MariaDB, Oracle, SQLite, Db2,
  /// Snowflake, ...) resolves to [sql92].
  ///
  /// **Recommended default** since v3.1: callers no longer need to know which
  /// engine they are talking to.
  auto(0),

  /// SQL Server / Sybase ASE syntax. Use when the connection is known to be
  /// SQL Server (or a Sybase variant that mimics it) and you want to skip the
  /// `SQLGetInfo` round-trip.
  sqlServer(1),

  /// SQL-92 syntax (PostgreSQL, MySQL, MariaDB, Oracle, SQLite, Db2,
  /// Snowflake). Use when the connection is known not to be SQL Server.
  sql92(2);

  const SavepointDialect(this.code);

  /// Stable wire code passed to the native FFI `odbc_transaction_begin`.
  final int code;
}
