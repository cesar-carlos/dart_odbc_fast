import 'package:odbc_fast/domain/entities/directed_param.dart';
import 'package:odbc_fast/domain/entities/param_value.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/helpers/typed_columnar_converter.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart'
    show paramValuesFromObjects;
import 'package:result_dart/result_dart.dart';

/// Query / catalog / bulk capability delegate for the ODBC service façade.
class OdbcQueryService {
  OdbcQueryService(this._repository);

  final IOdbcRepository _repository;

  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) =>
      executeQueryParamValues(
        connectionId,
        sql,
        paramValuesFromObjects(params),
        resultEncoding: resultEncoding,
      );

  Future<Result<QueryResult>> executeQueryParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
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

  Stream<Result<QueryResult>> streamQuery(String connectionId, String sql) =>
      _repository.streamQuery(connectionId, sql);

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

  Future<Result<QueryResult>> executePrepared(
    String connectionId,
    int stmtId,
    List<dynamic>? params,
    StatementOptions? options,
  ) =>
      executePreparedParamValues(
        connectionId,
        stmtId,
        params == null || params.isEmpty
            ? null
            : paramValuesFromObjects(params),
        options,
      );

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

  Future<Result<QueryResultMulti>> executeQueryMultiParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  ) =>
      executeQueryMultiParamValues(
        connectionId,
        sql,
        paramValuesFromObjects(params),
      );

  Future<Result<QueryResultMulti>> executeQueryMultiParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params,
  ) =>
      _repository.executeQueryMultiParamValues(connectionId, sql, params);

  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql,
  ) =>
      _repository.streamQueryMulti(connectionId, sql);

  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) =>
      _repository.executeQueryNamed(connectionId, sql, namedParams);

  Stream<Result<QueryResult>> streamQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) =>
      _repository.streamQueryNamed(connectionId, sql, namedParams);

  Future<Result<TypedColumnarResult>> executeQueryColumnar(
    String connectionId,
    String sql, {
    List<dynamic>? params,
  }) =>
      executeQueryColumnarParamValues(
        connectionId,
        sql,
        params: params == null ? null : paramValuesFromObjects(params),
      );

  Future<Result<TypedColumnarResult>> executeQueryColumnarParamValues(
    String connectionId,
    String sql, {
    List<ParamValue>? params,
  }) async {
    final r = await _repository.executeQueryParamValues(
      connectionId,
      sql,
      params ?? const <ParamValue>[],
      resultEncoding: ResultEncoding.columnar,
    );
    return r.fold(
      (qr) => Success<TypedColumnarResult, OdbcError>(toTypedColumnar(qr)),
      (e) => Failure<TypedColumnarResult, OdbcError>(e as OdbcError),
    );
  }

  Stream<Result<TypedColumnarResult>> streamQueryColumnar(
    String connectionId,
    String sql,
  ) async* {
    await for (final chunk in _repository.streamQuery(connectionId, sql)) {
      yield chunk.fold(
        (qr) => Success<TypedColumnarResult, OdbcError>(toTypedColumnar(qr)),
        (e) => Failure<TypedColumnarResult, OdbcError>(e as OdbcError),
      );
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
    List<dynamic>? params,
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
      params == null || params.isEmpty
          ? const <ParamValue>[]
          : paramValuesFromObjects(params),
    );
  }
}
