import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/pool_state.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:result_dart/result_dart.dart';

/// Interface for ODBC service operations.
///
/// Allows decorators and alternative implementations to be used
/// interchangeably via dependency injection.
abstract class IOdbcService {
  Future<Result<void>> initialize();

  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  });

  Future<Result<void>> disconnect(String connectionId);

  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  );

  Future<Result<int>> beginTransaction(
    String connectionId, {
    IsolationLevel? isolationLevel,
  });

  Future<Result<void>> commitTransaction(
    String connectionId,
    int txnId,
  );

  Future<Result<void>> rollbackTransaction(
    String connectionId,
    int txnId,
  );

  Future<Result<void>> createSavepoint(
    String connectionId,
    int txnId,
    String name,
  );

  Future<Result<void>> rollbackToSavepoint(
    String connectionId,
    int txnId,
    String name,
  );

  Future<Result<void>> releaseSavepoint(
    String connectionId,
    int txnId,
    String name,
  );

  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  });

  Future<Result<int>> prepareNamed(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  });

  Future<Result<QueryResult>> executePrepared(
    String connectionId,
    int stmtId,
    List<dynamic>? params,
    StatementOptions? options,
  );

  Future<Result<QueryResult>> executePreparedNamed(
    String connectionId,
    int stmtId,
    Map<String, Object?> namedParams,
    StatementOptions? options,
  );

  Future<Result<void>> closeStatement(
    String connectionId,
    int stmtId,
  );

  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  );

  Future<Result<QueryResultMulti>> executeQueryMultiFull(
    String connectionId,
    String sql,
  );

  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  );

  Future<Result<QueryResult>> catalogTables({
    required String connectionId,
    String catalog = '',
    String schema = '',
  });

  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  );

  Future<Result<QueryResult>> catalogTypeInfo(String connectionId);

  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize,
  );

  Future<Result<Connection>> poolGetConnection(int poolId);

  Future<Result<void>> poolReleaseConnection(String connectionId);

  Future<Result<bool>> poolHealthCheck(int poolId);

  Future<Result<PoolState>> poolGetState(int poolId);

  Future<Result<void>> poolClose(int poolId);

  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  );

  Future<Result<int>> bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount, {
    int parallelism = 0,
  });

  Future<Result<OdbcMetrics>> getMetrics();

  bool isInitialized();

  Future<Result<void>> clearStatementCache();

  Future<Result<PreparedStatementMetrics>> getPreparedStatementsMetrics();

  Future<String?> detectDriver(String connectionString);

  Future<Result<QueryResult>> executeQuery(
    String sql, {
    List<dynamic>? params,
    String? connectionId,
  });

  void dispose();
}

/// High-level ODBC service that provides simplified API for database
/// operations.
///
/// This service wraps [IOdbcRepository] to provide a more convenient
/// interface for common database operations.
///
/// ## Usage
/// ```dart
/// final service = OdbcService(repository);
/// await service.initialize();
/// final result = await service.executeQuery(
///   'SELECT * FROM users',
///   connectionId: connection.id,
/// );
/// ```
class OdbcService implements IOdbcService {
  /// Creates a new [OdbcService] instance.
  ///
  /// The `repository` parameter provides the ODBC repository implementation.
  OdbcService(this._repository);
  final IOdbcRepository _repository;

  @override
  Future<Result<void>> initialize() async {
    return _repository.initialize();
  }

  @override
  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  }) async {
    return _repository.connect(connectionString, options: options);
  }

  @override
  Future<Result<void>> disconnect(String connectionId) async {
    return _repository.disconnect(connectionId);
  }

  @override
  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  ) async {
    return _repository.executeQueryParams(
      connectionId,
      sql,
      params,
    );
  }

  @override
  Future<Result<int>> beginTransaction(
    String connectionId, {
    IsolationLevel? isolationLevel,
  }) async {
    return _repository.beginTransaction(
      connectionId,
      isolationLevel ?? IsolationLevel.readCommitted,
    );
  }

  @override
  Future<Result<void>> commitTransaction(
    String connectionId,
    int txnId,
  ) async {
    return _repository.commitTransaction(connectionId, txnId);
  }

  @override
  Future<Result<void>> rollbackTransaction(
    String connectionId,
    int txnId,
  ) async {
    return _repository.rollbackTransaction(connectionId, txnId);
  }

  @override
  Future<Result<void>> createSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    return _repository.createSavepoint(connectionId, txnId, name);
  }

  @override
  Future<Result<void>> rollbackToSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    return _repository.rollbackToSavepoint(
      connectionId,
      txnId,
      name,
    );
  }

  @override
  Future<Result<void>> releaseSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    return _repository.releaseSavepoint(connectionId, txnId, name);
  }

  @override
  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async {
    return _repository.prepare(
      connectionId,
      sql,
      timeoutMs: timeoutMs,
    );
  }

  @override
  Future<Result<int>> prepareNamed(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async {
    return _repository.prepareNamed(
      connectionId,
      sql,
      timeoutMs: timeoutMs,
    );
  }

  @override
  Future<Result<QueryResult>> executePrepared(
    String connectionId,
    int stmtId,
    List<dynamic>? params,
    StatementOptions? options,
  ) async {
    return _repository.executePrepared(
      connectionId,
      stmtId,
      params,
      options,
    );
  }

  @override
  Future<Result<QueryResult>> executePreparedNamed(
    String connectionId,
    int stmtId,
    Map<String, Object?> namedParams,
    StatementOptions? options,
  ) async {
    return _repository.executePreparedNamed(
      connectionId,
      stmtId,
      namedParams,
      options,
    );
  }

  @override
  Future<Result<void>> closeStatement(
    String connectionId,
    int stmtId,
  ) async {
    return _repository.closeStatement(connectionId, stmtId);
  }

  @override
  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  ) async {
    return _repository.executeQueryMulti(connectionId, sql);
  }

  @override
  Future<Result<QueryResultMulti>> executeQueryMultiFull(
    String connectionId,
    String sql,
  ) async {
    return _repository.executeQueryMultiFull(connectionId, sql);
  }

  @override
  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) async {
    return _repository.executeQueryNamed(connectionId, sql, namedParams);
  }

  @override
  Future<Result<QueryResult>> catalogTables({
    required String connectionId,
    String catalog = '',
    String schema = '',
  }) async {
    return _repository.catalogTables(
      connectionId,
      catalog: catalog,
      schema: schema,
    );
  }

  @override
  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  ) async {
    return _repository.catalogColumns(connectionId, table);
  }

  @override
  Future<Result<QueryResult>> catalogTypeInfo(
    String connectionId,
  ) async {
    return _repository.catalogTypeInfo(connectionId);
  }

  @override
  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize,
  ) async {
    return _repository.poolCreate(connectionString, maxSize);
  }

  @override
  Future<Result<Connection>> poolGetConnection(int poolId) async {
    return _repository.poolGetConnection(poolId);
  }

  @override
  Future<Result<void>> poolReleaseConnection(
    String connectionId,
  ) async {
    return _repository.poolReleaseConnection(connectionId);
  }

  @override
  Future<Result<bool>> poolHealthCheck(int poolId) async {
    return _repository.poolHealthCheck(poolId);
  }

  @override
  Future<Result<PoolState>> poolGetState(int poolId) async {
    return _repository.poolGetState(poolId);
  }

  @override
  Future<Result<void>> poolClose(int poolId) async {
    return _repository.poolClose(poolId);
  }

  @override
  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  ) async {
    return _repository.bulkInsert(
      connectionId,
      table,
      columns,
      dataBuffer,
      rowCount,
    );
  }

  @override
  Future<Result<int>> bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount, {
    int parallelism = 0,
  }) async {
    return _repository.bulkInsertParallel(
      poolId,
      table,
      columns,
      dataBuffer,
      rowCount,
      parallelism: parallelism,
    );
  }

  @override
  Future<Result<OdbcMetrics>> getMetrics() async {
    return _repository.getMetrics();
  }

  @override
  bool isInitialized() {
    return _repository.isInitialized();
  }

  @override
  Future<Result<void>> clearStatementCache() async {
    return _repository.clearStatementCache();
  }

  @override
  Future<Result<PreparedStatementMetrics>>
      getPreparedStatementsMetrics() async {
    return _repository.getPreparedStatementsMetrics();
  }

  @override
  Future<String?> detectDriver(String connectionString) async {
    return _repository.detectDriver(connectionString);
  }

  @override
  Future<Result<QueryResult>> executeQuery(
    String sql, {
    List<dynamic>? params,
    String? connectionId,
  }) async {
    if (connectionId == null || connectionId.isEmpty) {
      throw const ConnectionError(
        message: 'No active connection. Call connect() first.',
      );
    }

    if (params == null || params.isEmpty) {
      return executeQueryParams(connectionId, sql, []);
    }

    return executeQueryParams(connectionId, sql, params);
  }

  @override
  void dispose() {}
}
