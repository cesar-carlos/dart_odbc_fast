import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/pool_state.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:result_dart/result_dart.dart';

/// High-level service for ODBC database operations.
///
/// Provides a clean API for connecting to databases, executing queries,
/// managing transactions, using prepared statements, connection pooling,
/// and catalog queries. Includes input validation and automatic error handling.
///
/// Example:
/// ```dart
/// final service = OdbcService(repository);
/// await service.initialize();
/// final connResult = await service.connect('DSN=MyDatabase');
/// ```
class OdbcService {
  /// Creates a new [OdbcService] instance.
  ///
  /// The [repository] must be a valid [IOdbcRepository] implementation.
  OdbcService(this._repository);
  final IOdbcRepository _repository;

  /// Initializes the ODBC environment.
  ///
  /// Must be called before any other operations. This method can be called
  /// multiple times safely - subsequent calls are ignored if already initialized.
  Future<Result<Unit>> initialize() async => _repository.initialize();

  /// Establishes a new database connection.
  ///
  /// The [connectionString] must be a non-empty ODBC connection string
  /// (e.g., 'DSN=MyDatabase' or 'Driver={SQL Server};Server=...').
  ///
  /// Automatically initializes the ODBC environment if not already initialized.
  /// Returns a [Connection] on success or a [ValidationError] if the
  /// connection string is empty, or a [ConnectionError] if connection fails.
  Future<Result<Connection>> connect(String connectionString) async {
    if (connectionString.trim().isEmpty) {
      return const Failure<Connection, OdbcError>(
        ValidationError(message: 'Connection string cannot be empty'),
      );
    }

    if (!_repository.isInitialized()) {
      final initResult = await _repository.initialize();
      final initError = initResult.exceptionOrNull();
      if (initError != null) {
        if (initError is OdbcError) {
          return Failure<Connection, OdbcError>(initError);
        }
        return Failure<Connection, OdbcError>(
          ConnectionError(message: initError.toString()),
        );
      }
    }

    return _repository.connect(connectionString);
  }

  /// Closes and disconnects a connection.
  ///
  /// The [connectionId] must be a valid connection identifier returned
  /// from [connect]. Returns [Unit] on success or an error [Result] if
  /// disconnection fails.
  Future<Result<Unit>> disconnect(String connectionId) async =>
      _repository.disconnect(connectionId);

  /// Executes a SQL query and returns the result set.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] must be a non-empty SQL SELECT statement.
  ///
  /// Returns a [QueryResult] containing columns and rows on success,
  /// or a [ValidationError] if SQL is empty, or a [QueryError] if execution fails.
  Future<Result<QueryResult>> executeQuery(
    String connectionId,
    String sql,
  ) async {
    if (sql.trim().isEmpty) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'SQL query cannot be empty'),
      );
    }
    return _repository.executeQuery(connectionId, sql);
  }

  /// Begins a new transaction with the specified isolation level.
  ///
  /// The [connectionId] must be a valid active connection.
  /// Returns a transaction ID on success, which must be used for
  /// [commitTransaction] or [rollbackTransaction].
  Future<Result<int>> beginTransaction(
    String connectionId,
    IsolationLevel isolationLevel,
  ) async =>
      _repository.beginTransaction(connectionId, isolationLevel);

  /// Commits a transaction.
  ///
  /// The [connectionId] and [txnId] must be valid and correspond to
  /// an active transaction started with [beginTransaction].
  Future<Result<Unit>> commitTransaction(
    String connectionId,
    int txnId,
  ) async =>
      _repository.commitTransaction(connectionId, txnId);

  /// Rolls back a transaction.
  ///
  /// The [connectionId] and [txnId] must be valid and correspond to
  /// an active transaction started with [beginTransaction].
  Future<Result<Unit>> rollbackTransaction(
    String connectionId,
    int txnId,
  ) async =>
      _repository.rollbackTransaction(connectionId, txnId);

  /// Prepares a SQL statement for execution.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] must be a non-empty parameterized SQL statement
  /// (e.g., 'SELECT * FROM users WHERE id = ?').
  ///
  /// The [timeoutMs] specifies the statement timeout in milliseconds (0 = no timeout).
  /// Returns a statement ID on success, which must be used with
  /// [executePrepared] and [closeStatement].
  ///
  /// Returns a [ValidationError] if SQL is empty.
  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async {
    if (sql.trim().isEmpty) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'SQL cannot be empty'),
      );
    }
    return _repository.prepare(connectionId, sql, timeoutMs: timeoutMs);
  }

  /// Executes a prepared statement with optional parameters.
  ///
  /// The [connectionId] and [stmtId] must be valid and correspond to
  /// a statement prepared with [prepare].
  ///
  /// The [params] list should contain values for each parameter placeholder
  /// in the prepared SQL statement, in order. Can be null if no parameters.
  Future<Result<QueryResult>> executePrepared(
    String connectionId,
    int stmtId, [
    List<dynamic>? params,
  ]) async =>
      _repository.executePrepared(connectionId, stmtId, params);

  /// Closes and releases a prepared statement.
  ///
  /// The [connectionId] and [stmtId] must be valid and correspond to
  /// a statement prepared with [prepare].
  Future<Result<Unit>> closeStatement(
    String connectionId,
    int stmtId,
  ) async =>
      _repository.closeStatement(connectionId, stmtId);

  /// Executes a SQL query with parameters.
  ///
  /// Convenience method that combines prepare and execute in a single call.
  /// The [connectionId] must be a valid active connection.
  /// The [sql] must be a non-empty parameterized SQL statement.
  /// The [params] list should contain values for each '?' placeholder in [sql].
  ///
  /// Returns a [ValidationError] if SQL is empty.
  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  ) async {
    if (sql.trim().isEmpty) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'SQL query cannot be empty'),
      );
    }
    return _repository.executeQueryParams(connectionId, sql, params);
  }

  /// Executes a SQL query that returns multiple result sets.
  ///
  /// Some databases support queries that return multiple result sets.
  /// This method handles such queries and returns the first result set.
  /// The [connectionId] must be a valid active connection.
  /// The [sql] must be a non-empty SQL statement.
  ///
  /// Returns a [ValidationError] if SQL is empty.
  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  ) async {
    if (sql.trim().isEmpty) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'SQL query cannot be empty'),
      );
    }
    return _repository.executeQueryMulti(connectionId, sql);
  }

  /// Queries the database catalog for table information.
  ///
  /// Returns metadata about tables in the specified [catalog] and [schema].
  /// Empty strings for [catalog] or [schema] match all values.
  /// The [connectionId] must be a valid active connection.
  Future<Result<QueryResult>> catalogTables(
    String connectionId, {
    String catalog = '',
    String schema = '',
  }) async =>
      _repository.catalogTables(
        connectionId,
        catalog: catalog,
        schema: schema,
      );

  /// Queries the database catalog for column information.
  ///
  /// Returns metadata about columns in the specified [table].
  /// The [connectionId] must be a valid active connection.
  /// The [table] must be a non-empty table name.
  ///
  /// Returns a [ValidationError] if table name is empty.
  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  ) async {
    if (table.trim().isEmpty) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Table name cannot be empty'),
      );
    }
    return _repository.catalogColumns(connectionId, table);
  }

  /// Queries the database catalog for data type information.
  ///
  /// Returns metadata about data types supported by the database.
  /// The [connectionId] must be a valid active connection.
  Future<Result<QueryResult>> catalogTypeInfo(String connectionId) async =>
      _repository.catalogTypeInfo(connectionId);

  /// Creates a new connection pool.
  ///
  /// The [connectionString] must be a non-empty ODBC connection string
  /// used to establish connections in the pool.
  /// The [maxSize] must be at least 1, specifying the maximum number
  /// of connections in the pool.
  ///
  /// Returns a pool ID on success, which must be used for pool operations.
  /// Returns a [ValidationError] if connection string is empty or maxSize < 1.
  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize,
  ) async {
    if (connectionString.trim().isEmpty) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Connection string cannot be empty'),
      );
    }
    if (maxSize < 1) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Pool max size must be at least 1'),
      );
    }
    return _repository.poolCreate(connectionString, maxSize);
  }

  Future<Result<Connection>> poolGetConnection(int poolId) async =>
      _repository.poolGetConnection(poolId);

  Future<Result<Unit>> poolReleaseConnection(String connectionId) async =>
      _repository.poolReleaseConnection(connectionId);

  Future<Result<bool>> poolHealthCheck(int poolId) async =>
      _repository.poolHealthCheck(poolId);

  Future<Result<PoolState>> poolGetState(int poolId) async =>
      _repository.poolGetState(poolId);

  Future<Result<Unit>> poolClose(int poolId) async =>
      _repository.poolClose(poolId);

  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  ) async {
    if (table.trim().isEmpty) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Table name cannot be empty'),
      );
    }
    if (columns.isEmpty) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'At least one column required'),
      );
    }
    if (rowCount < 1) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Row count must be at least 1'),
      );
    }
    return _repository.bulkInsert(
      connectionId,
      table,
      columns,
      dataBuffer,
      rowCount,
    );
  }

  /// Gets performance and operational metrics.
  ///
  /// Returns [OdbcMetrics] containing query counts, error counts,
  /// uptime, and latency information.
  Future<Result<OdbcMetrics>> getMetrics() async => _repository.getMetrics();
}
