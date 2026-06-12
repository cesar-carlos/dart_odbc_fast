import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator_base.dart';
import 'package:odbc_fast/domain/entities/directed_param.dart';
import 'package:odbc_fast/domain/entities/param_value.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:result_dart/result_dart.dart';

/// Query-shaped `IOdbcService` forwards for the telemetry decorator façade.
mixin TelemetryOdbcServiceQueryForwards on TelemetryOdbcServiceDecoratorBase {
  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) =>
      query.executeQueryParams(
        connectionId,
        sql,
        params,
        resultEncoding: resultEncoding,
      );

  Future<Result<QueryResult>> executeQueryParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) =>
      query.executeQueryParamValues(
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
      query.executeQueryDirectedParams(connectionId, sql, params);

  Stream<Result<QueryResult>> streamQuery(String connectionId, String sql) =>
      query.streamQuery(connectionId, sql);

  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) =>
      query.prepare(connectionId, sql, timeoutMs: timeoutMs);

  Future<Result<int>> prepareNamed(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) =>
      query.prepareNamed(connectionId, sql, timeoutMs: timeoutMs);

  Future<Result<QueryResult>> executePrepared(
    String connectionId,
    int stmtId,
    List<dynamic>? params,
    StatementOptions? options,
  ) =>
      query.executePrepared(connectionId, stmtId, params, options);

  Future<Result<QueryResult>> executePreparedParamValues(
    String connectionId,
    int stmtId,
    List<ParamValue>? params,
    StatementOptions? options,
  ) =>
      query.executePreparedParamValues(
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
      query.executePreparedNamed(
        connectionId,
        stmtId,
        namedParams,
        options,
      );

  Future<Result<void>> closeStatement(String connectionId, int stmtId) =>
      query.closeStatement(connectionId, stmtId);

  Future<Result<void>> cancelStatement(String connectionId, int stmtId) =>
      query.cancelStatement(connectionId, stmtId);

  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  ) =>
      query.executeQueryMulti(connectionId, sql);

  Future<Result<QueryResultMulti>> executeQueryMultiFull(
    String connectionId,
    String sql,
  ) =>
      query.executeQueryMultiFull(connectionId, sql);

  Future<Result<QueryResultMulti>> executeQueryMultiParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  ) =>
      query.executeQueryMultiParams(connectionId, sql, params);

  Future<Result<QueryResultMulti>> executeQueryMultiParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params,
  ) =>
      query.executeQueryMultiParamValues(connectionId, sql, params);

  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql,
  ) =>
      query.streamQueryMulti(connectionId, sql);

  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) =>
      query.executeQueryNamed(connectionId, sql, namedParams);

  Stream<Result<QueryResult>> streamQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) =>
      query.streamQueryNamed(connectionId, sql, namedParams);

  Future<Result<TypedColumnarResult>> executeQueryColumnar(
    String connectionId,
    String sql, {
    List<dynamic>? params,
  }) =>
      query.executeQueryColumnar(connectionId, sql, params: params);

  Future<Result<TypedColumnarResult>> executeQueryColumnarParamValues(
    String connectionId,
    String sql, {
    List<ParamValue>? params,
  }) =>
      query.executeQueryColumnarParamValues(
        connectionId,
        sql,
        params: params,
      );

  Stream<Result<TypedColumnarResult>> streamQueryColumnar(
    String connectionId,
    String sql,
  ) =>
      query.streamQueryColumnar(connectionId, sql);

  Future<Result<QueryResult>> catalogTables({
    required String connectionId,
    String catalog = '',
    String schema = '',
  }) =>
      query.catalogTables(
        connectionId: connectionId,
        catalog: catalog,
        schema: schema,
      );

  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  ) =>
      query.catalogColumns(connectionId, table);

  Future<Result<QueryResult>> catalogTypeInfo(String connectionId) =>
      query.catalogTypeInfo(connectionId);

  Future<Result<QueryResult>> catalogPrimaryKeys(
    String connectionId,
    String table,
  ) =>
      query.catalogPrimaryKeys(connectionId, table);

  Future<Result<QueryResult>> catalogForeignKeys(
    String connectionId,
    String table,
  ) =>
      query.catalogForeignKeys(connectionId, table);

  Future<Result<QueryResult>> catalogIndexes(
    String connectionId,
    String table,
  ) =>
      query.catalogIndexes(connectionId, table);

  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  ) =>
      query.bulkInsert(
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
      query.bulkInsertParallel(
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
  }) =>
      query.executeQuery(
        sql,
        params: params,
        connectionId: connectionId,
      );
}
