import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/pool_state.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:result_dart/result_dart.dart';

/// Repository interface for ODBC database operations.
///
/// Defines the contract for all ODBC operations including connection
/// management, query execution, transactions, prepared statements,
/// connection pooling, and catalog queries.
///
/// Implementations should handle errors and return [Result] types
/// for type-safe error handling.
abstract class IOdbcRepository {
  /// Initializes the ODBC environment.
  ///
  /// Must be called before any other operations. Returns [Unit] on success
  /// or an error [Result] if initialization fails.
  Future<Result<Unit>> initialize();

  /// Establishes a new database connection.
  ///
  /// The [connectionString] should be a valid ODBC connection string
  /// (e.g., 'DSN=MyDatabase' or 'Driver={SQL Server};Server=...').
  /// [options] can specify connection/login timeout.
  ///
  /// Returns a [Connection] on success or an error [Result] if the connection
  /// cannot be established.
  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  });

  /// Closes and disconnects a connection.
  ///
  /// The [connectionId] must be a valid connection identifier returned
  /// from [connect]. Returns [Unit] on success or an error [Result] if
  /// disconnection fails.
  Future<Result<Unit>> disconnect(String connectionId);

  /// Executes a SQL query and returns the result set.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a valid SQL SELECT statement.
  ///
  /// Returns a [QueryResult] containing columns and rows on success,
  /// or an error [Result] if execution fails.
  Future<Result<QueryResult>> executeQuery(
    String connectionId,
    String sql,
  );

  /// Begins a new transaction with the specified isolation level.
  ///
  /// The [connectionId] must be a valid active connection.
  /// Returns a transaction ID on success, which must be used for
  /// [commitTransaction] or [rollbackTransaction].
  Future<Result<int>> beginTransaction(
    String connectionId,
    IsolationLevel isolationLevel,
  );

  /// Commits a transaction.
  ///
  /// The [connectionId] and [txnId] must be valid and correspond to
  /// an active transaction started with [beginTransaction].
  Future<Result<Unit>> commitTransaction(
    String connectionId,
    int txnId,
  );

  /// Rolls back a transaction.
  ///
  /// The [connectionId] and [txnId] must be valid and correspond to
  /// an active transaction started with [beginTransaction].
  Future<Result<Unit>> rollbackTransaction(
    String connectionId,
    int txnId,
  );

  /// Creates a savepoint within an active transaction.
  ///
  /// The [connectionId] and [txnId] must be valid and correspond to
  /// an active transaction started with [beginTransaction].
  Future<Result<Unit>> createSavepoint(
    String connectionId,
    int txnId,
    String name,
  );

  /// Rolls back to a savepoint. The transaction remains active.
  ///
  /// The [connectionId] and [txnId] must be valid.
  Future<Result<Unit>> rollbackToSavepoint(
    String connectionId,
    int txnId,
    String name,
  );

  /// Releases a savepoint. The transaction remains active.
  ///
  /// The [connectionId] and [txnId] must be valid.
  Future<Result<Unit>> releaseSavepoint(
    String connectionId,
    int txnId,
    String name,
  );

  /// Prepares a SQL statement for execution.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a parameterized SQL statement (e.g.,
  /// 'SELECT * FROM users WHERE id = ?').
  ///
  /// The [timeoutMs] specifies the statement timeout in milliseconds.
  /// Returns a statement ID on success, which must be used with
  /// [executePrepared] and [closeStatement].
  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  });

  /// Executes a prepared statement with optional parameters.
  ///
  /// The [connectionId] and [stmtId] must be valid and correspond to
  /// a statement prepared with [prepare].
  ///
  /// The [params] list should contain values for each parameter placeholder
  /// in the prepared SQL statement, in order.
  Future<Result<QueryResult>> executePrepared(
    String connectionId,
    int stmtId, [
    List<dynamic>? params,
  ]);

  /// Closes and releases a prepared statement.
  ///
  /// The [connectionId] and [stmtId] must be valid and correspond to
  /// a statement prepared with [prepare].
  Future<Result<Unit>> closeStatement(String connectionId, int stmtId);

  /// Executes a SQL query with parameters.
  ///
  /// Convenience method that combines prepare and execute in a single call.
  /// The [params] list should contain values for each '?' placeholder in [sql].
  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  );

  /// Executes a SQL query that returns multiple result sets.
  ///
  /// Some databases support queries that return multiple result sets.
  /// This method handles such queries and returns the first result set.
  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  );

  /// Queries the database catalog for table information.
  ///
  /// Returns metadata about tables in the specified [catalog] and [schema].
  /// Empty strings for [catalog] or [schema] match all values.
  Future<Result<QueryResult>> catalogTables(
    String connectionId, {
    String catalog = '',
    String schema = '',
  });

  /// Queries the database catalog for column information.
  ///
  /// Returns metadata about columns in the specified [table].
  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  );

  /// Queries the database catalog for data type information.
  ///
  /// Returns metadata about data types supported by the database.
  Future<Result<QueryResult>> catalogTypeInfo(String connectionId);

  /// Creates a new connection pool.
  ///
  /// The [connectionString] is used to establish connections in the pool.
  /// The [maxSize] specifies the maximum number of connections in the pool.
  ///
  /// Returns a pool ID on success, which must be used for pool operations.
  Future<Result<int>> poolCreate(String connectionString, int maxSize);

  /// Gets a connection from the pool.
  ///
  /// The [poolId] must be a valid pool created with [poolCreate].
  /// Returns a [Connection] that must be released with [poolReleaseConnection]
  /// when done.
  Future<Result<Connection>> poolGetConnection(int poolId);

  /// Releases a connection back to the pool.
  ///
  /// The [connectionId] must be a connection obtained from [poolGetConnection].
  Future<Result<Unit>> poolReleaseConnection(String connectionId);

  /// Performs a health check on the connection pool.
  ///
  /// Returns true if the pool is healthy and can provide connections,
  /// false otherwise.
  Future<Result<bool>> poolHealthCheck(int poolId);

  /// Gets the current state of the connection pool.
  ///
  /// Returns [PoolState] containing pool size and idle connection count.
  Future<Result<PoolState>> poolGetState(int poolId);

  /// Closes the connection pool and releases all connections.
  ///
  /// The [poolId] must be a valid pool created with [poolCreate].
  Future<Result<Unit>> poolClose(int poolId);

  /// Performs a bulk insert operation.
  ///
  /// Inserts multiple rows into [table] using the specified [columns].
  /// The [dataBuffer] contains the data as a flat list of integers
  /// (binary representation of values).
  ///
  /// The [rowCount] specifies how many rows are in [dataBuffer].
  /// Returns the number of rows inserted on success.
  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  );

  /// Gets performance and operational metrics.
  ///
  /// Returns [OdbcMetrics] containing query counts, error counts,
  /// uptime, and latency information.
  Future<Result<OdbcMetrics>> getMetrics();

  /// Checks if the ODBC environment has been initialized.
  ///
  /// Returns true if [initialize] has been called successfully,
  /// false otherwise.
  bool isInitialized();
}
