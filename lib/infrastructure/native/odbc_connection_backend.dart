import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';

/// Backend interface for low-level ODBC operations.
///
/// Defines the contract for transaction management, prepared statement
/// execution, catalog queries, and connection pooling operations.
/// Implementations provide the actual ODBC driver integration.
abstract class OdbcConnectionBackend {
  /// Commits a transaction.
  ///
  /// The [txnId] must be a valid transaction identifier.
  /// Returns true on success, false on failure.
  bool commitTransaction(int txnId);

  /// Rolls back a transaction.
  ///
  /// The [txnId] must be a valid transaction identifier.
  /// Returns true on success, false on failure.
  bool rollbackTransaction(int txnId);

  /// Creates a savepoint within an active transaction.
  ///
  /// The [txnId] must be a valid transaction identifier.
  /// Returns true on success, false on failure.
  bool createSavepoint(int txnId, String name);

  /// Rolls back to a savepoint. The transaction remains active.
  ///
  /// The [txnId] must be a valid transaction identifier.
  /// Returns true on success, false on failure.
  bool rollbackToSavepoint(int txnId, String name);

  /// Releases a savepoint. The transaction remains active.
  ///
  /// The [txnId] must be a valid transaction identifier.
  /// Returns true on success, false on failure.
  bool releaseSavepoint(int txnId, String name);

  /// Executes a prepared statement with optional parameters.
  ///
  /// The [stmtId] must be a valid prepared statement identifier.
  /// The [params] list contains parameter values for the statement.
  /// The [timeoutOverrideMs] overrides statement timeout (0 = use stored).
  /// The [fetchSize] specifies rows per batch (default: 1000).
  /// When [maxBufferBytes] is set, caps the result buffer size.
  /// Returns binary result data on success, null on failure.
  Uint8List? executePrepared(
    int stmtId,
    List<ParamValue>? params,
    int timeoutOverrideMs,
    int fetchSize, {
    int? maxBufferBytes,
  });

  /// Closes and releases a prepared statement.
  ///
  /// The [stmtId] must be a valid prepared statement identifier.
  /// Returns true on success, false on failure.
  bool closeStatement(int stmtId);

  /// Clears all prepared statements.
  ///
  /// Returns 0 on success, non-zero on failure.
  int clearAllStatements();

  /// Gets prepared statement metrics.
  ///
  /// Returns metrics including cache hits, executions, etc.
  /// Returns null if metrics cannot be retrieved.
  PreparedStatementMetrics? getCacheMetrics();

  /// Queries the database catalog for table information.
  ///
  /// The [connectionId] must be a valid active connection.
  /// Empty strings for [catalog] or [schema] match all values.
  /// Returns binary result data on success, null on failure.
  Uint8List? catalogTables(
    int connectionId, {
    String catalog = '',
    String schema = '',
  });

  /// Queries the database catalog for column information.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [table] is the table name to query.
  /// Returns binary result data on success, null on failure.
  Uint8List? catalogColumns(int connectionId, String table);

  /// Queries the database catalog for data type information.
  ///
  /// The [connectionId] must be a valid active connection.
  /// Returns binary result data on success, null on failure.
  Uint8List? catalogTypeInfo(int connectionId);

  /// Gets a connection from the pool.
  ///
  /// The [poolId] must be a valid pool identifier.
  /// Returns a connection ID on success, 0 on failure.
  int poolGetConnection(int poolId);

  /// Releases a connection back to the pool.
  ///
  /// The [connectionId] must be a connection obtained from [poolGetConnection].
  /// Returns true on success, false on failure.
  bool poolReleaseConnection(int connectionId);

  /// Performs a health check on the connection pool.
  ///
  /// The [poolId] must be a valid pool identifier.
  /// Returns true if the pool is healthy, false otherwise.
  bool poolHealthCheck(int poolId);

  /// Gets the current state of the connection pool.
  ///
  /// The [poolId] must be a valid pool identifier.
  /// Returns a record with pool size and idle count, or null on failure.
  ({int size, int idle})? poolGetState(int poolId);

  /// Closes the connection pool and releases all connections.
  ///
  /// The [poolId] must be a valid pool identifier.
  /// Returns true on success, false on failure.
  bool poolClose(int poolId);
}
