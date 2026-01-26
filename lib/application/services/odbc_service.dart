import 'package:result_dart/result_dart.dart';

import '../../domain/entities/connection.dart';
import '../../domain/entities/isolation_level.dart';
import '../../domain/entities/odbc_metrics.dart';
import '../../domain/entities/pool_state.dart';
import '../../domain/entities/query_result.dart';
import '../../domain/errors/odbc_error.dart';
import '../../domain/repositories/odbc_repository.dart';

class OdbcService {
  final IOdbcRepository _repository;

  OdbcService(this._repository);

  Future<Result<Unit>> initialize() async => _repository.initialize();

  Future<Result<Connection>> connect(String connectionString) async {
    if (connectionString.trim().isEmpty) {
      return Failure<Connection, OdbcError>(
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

  Future<Result<Unit>> disconnect(String connectionId) async =>
      _repository.disconnect(connectionId);

  Future<Result<QueryResult>> executeQuery(
    String connectionId,
    String sql,
  ) async {
    if (sql.trim().isEmpty) {
      return Failure<QueryResult, OdbcError>(
        ValidationError(message: 'SQL query cannot be empty'),
      );
    }
    return _repository.executeQuery(connectionId, sql);
  }

  Future<Result<int>> beginTransaction(
    String connectionId,
    IsolationLevel isolationLevel,
  ) async =>
      _repository.beginTransaction(connectionId, isolationLevel);

  Future<Result<Unit>> commitTransaction(
    String connectionId,
    int txnId,
  ) async =>
      _repository.commitTransaction(connectionId, txnId);

  Future<Result<Unit>> rollbackTransaction(
    String connectionId,
    int txnId,
  ) async =>
      _repository.rollbackTransaction(connectionId, txnId);

  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async {
    if (sql.trim().isEmpty) {
      return Failure<int, OdbcError>(
        ValidationError(message: 'SQL cannot be empty'),
      );
    }
    return _repository.prepare(connectionId, sql, timeoutMs: timeoutMs);
  }

  Future<Result<QueryResult>> executePrepared(
    String connectionId,
    int stmtId, [
    List<dynamic>? params,
  ]) async =>
      _repository.executePrepared(connectionId, stmtId, params);

  Future<Result<Unit>> closeStatement(
    String connectionId,
    int stmtId,
  ) async =>
      _repository.closeStatement(connectionId, stmtId);

  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  ) async {
    if (sql.trim().isEmpty) {
      return Failure<QueryResult, OdbcError>(
        ValidationError(message: 'SQL query cannot be empty'),
      );
    }
    return _repository.executeQueryParams(connectionId, sql, params);
  }

  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  ) async {
    if (sql.trim().isEmpty) {
      return Failure<QueryResult, OdbcError>(
        ValidationError(message: 'SQL query cannot be empty'),
      );
    }
    return _repository.executeQueryMulti(connectionId, sql);
  }

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

  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  ) async {
    if (table.trim().isEmpty) {
      return Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Table name cannot be empty'),
      );
    }
    return _repository.catalogColumns(connectionId, table);
  }

  Future<Result<QueryResult>> catalogTypeInfo(String connectionId) async =>
      _repository.catalogTypeInfo(connectionId);

  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize,
  ) async {
    if (connectionString.trim().isEmpty) {
      return Failure<int, OdbcError>(
        ValidationError(message: 'Connection string cannot be empty'),
      );
    }
    if (maxSize < 1) {
      return Failure<int, OdbcError>(
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
      return Failure<int, OdbcError>(
        ValidationError(message: 'Table name cannot be empty'),
      );
    }
    if (columns.isEmpty) {
      return Failure<int, OdbcError>(
        ValidationError(message: 'At least one column required'),
      );
    }
    if (rowCount < 1) {
      return Failure<int, OdbcError>(
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

  Future<Result<OdbcMetrics>> getMetrics() async => _repository.getMetrics();
}
