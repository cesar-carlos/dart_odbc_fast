import 'package:odbc_fast/domain/entities/directed_param.dart';
import 'package:odbc_fast/domain/entities/param_value.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/repositories/i_query_repository.dart';
import 'package:result_dart/result_dart.dart';

/// Query / catalog / bulk capability delegate for the ODBC service façade.
class OdbcQueryService {
  OdbcQueryService(this._repository);

  final IQueryRepository _repository;

  Future<Result<QueryResult>> executeQueryParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    ResultEncoding? resultEncoding,
  }) =>
      _repository.executeQueryParamValues(
        connectionId,
        sql,
        params,
        resultEncoding: resultEncoding,
      );

  Future<Result<QueryResult>> executeQueryDirectedParams(
    String connectionId,
    String sql,
    List<DirectedParam> params,
  ) =>
      _repository.executeQueryDirectedParams(connectionId, sql, params);

  Stream<Result<QueryResult>> streamQuery(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      _repository.streamQuery(
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
      );

  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) =>
      _repository.prepare(connectionId, sql, timeoutMs: timeoutMs);

  Future<Result<int>> prepareNamed(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) =>
      _repository.prepareNamed(connectionId, sql, timeoutMs: timeoutMs);

  Future<Result<QueryResult>> executePreparedParamValues(
    String connectionId,
    int stmtId,
    List<ParamValue>? params,
    StatementOptions? options,
  ) =>
      _repository.executePreparedParamValues(
        connectionId,
        stmtId,
        params,
        options,
      );

  Future<Result<QueryResult>> executePreparedNamed(
    String connectionId,
    int stmtId,
    Map<String, Object?> namedParams,
    StatementOptions? options,
  ) =>
      _repository.executePreparedNamed(
        connectionId,
        stmtId,
        namedParams,
        options,
      );

  Future<Result<void>> closeStatement(String connectionId, int stmtId) =>
      _repository.closeStatement(connectionId, stmtId);

  Future<Result<void>> cancelStatement(String connectionId, int stmtId) =>
      _repository.cancelStatement(connectionId, stmtId);

  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  ) =>
      _repository.executeQueryMulti(connectionId, sql);

  Future<Result<QueryResultMulti>> executeQueryMultiFull(
    String connectionId,
    String sql,
  ) =>
      _repository.executeQueryMultiFull(connectionId, sql);

  Future<Result<QueryResultMulti>> executeQueryMultiParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params,
  ) =>
      _repository.executeQueryMultiParamValues(connectionId, sql, params);

  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      _repository.streamQueryMulti(
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
      );

  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) =>
      _repository.executeQueryNamed(connectionId, sql, namedParams);

  Stream<Result<QueryResult>> streamQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      _repository.streamQueryNamed(
        connectionId,
        sql,
        namedParams,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
      );

  Future<Result<TypedColumnarResult>> executeQueryColumnarParamValues(
    String connectionId,
    String sql, {
    List<ParamValue>? params,
  }) =>
      _repository.executeQueryColumnarParamValues(
        connectionId,
        sql,
        params ?? const <ParamValue>[],
      );

  Stream<Result<TypedColumnarResult>> streamQueryColumnar(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) async* {
    await for (final chunk in _repository.streamQueryColumnar(
      connectionId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
    )) {
      yield chunk;
    }
  }

  Future<Result<QueryResult>> catalogTables({
    required String connectionId,
    String catalog = '',
    String schema = '',
  }) =>
      _repository.catalogTables(
        connectionId,
        catalog: catalog,
        schema: schema,
      );

  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  ) =>
      _repository.catalogColumns(connectionId, table);

  Future<Result<QueryResult>> catalogTypeInfo(String connectionId) =>
      _repository.catalogTypeInfo(connectionId);

  Future<Result<QueryResult>> catalogPrimaryKeys(
    String connectionId,
    String table,
  ) =>
      _repository.catalogPrimaryKeys(connectionId, table);

  Future<Result<QueryResult>> catalogForeignKeys(
    String connectionId,
    String table,
  ) =>
      _repository.catalogForeignKeys(connectionId, table);

  Future<Result<QueryResult>> catalogIndexes(
    String connectionId,
    String table,
  ) =>
      _repository.catalogIndexes(connectionId, table);

  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  ) =>
      _repository.bulkInsert(
        connectionId,
        table,
        columns,
        dataBuffer,
        rowCount,
      );

  Future<Result<int>> bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount, {
    int parallelism = 0,
  }) =>
      _repository.bulkInsertParallel(
        poolId,
        table,
        columns,
        dataBuffer,
        rowCount,
        parallelism: parallelism,
      );

  Future<Result<QueryResult>> executeQuery(
    String sql, {
    String? connectionId,
  }) async {
    if (connectionId == null || connectionId.isEmpty) {
      return const Failure(
        ConnectionError(
          message: 'No active connection. Call connect() first.',
        ),
      );
    }

    return executeQueryParamValues(
      connectionId,
      sql,
      const <ParamValue>[],
    );
  }
}
