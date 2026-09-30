import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator_base.dart';
import 'package:odbc_fast/domain/entities/directed_param.dart';
import 'package:odbc_fast/domain/entities/param_value.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error_boundary.dart';
import 'package:result_dart/result_dart.dart';

/// Query-shaped `IOdbcService` forwards for the telemetry decorator façade.
mixin TelemetryOdbcServiceQueryForwards on TelemetryOdbcServiceDecoratorBase {
  Future<Result<QueryResult>> executeQueryParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    ResultEncoding? resultEncoding,
  }) =>
      OdbcErrorBoundary.run(
        'executeQueryParamValues',
        () => query.executeQueryParamValues(
          connectionId,
          sql,
          params,
          resultEncoding: resultEncoding,
        ),
      );

  Future<Result<QueryResult>> executeQueryDirectedParams(
    String connectionId,
    String sql,
    List<DirectedParam> params,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryDirectedParams',
        () => query.executeQueryDirectedParams(connectionId, sql, params),
      );

  Stream<Result<QueryResult>> streamQuery(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQuery',
        () => query.streamQuery(
          connectionId,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) =>
      OdbcErrorBoundary.run(
        'prepare',
        () => query.prepare(connectionId, sql, timeoutMs: timeoutMs),
      );

  Future<Result<int>> prepareNamed(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) =>
      OdbcErrorBoundary.run(
        'prepareNamed',
        () => query.prepareNamed(connectionId, sql, timeoutMs: timeoutMs),
      );

  Future<Result<QueryResult>> executePreparedParamValues(
    String connectionId,
    int stmtId,
    List<ParamValue>? params,
    StatementOptions? options, {
    ResultEncoding? resultEncoding,
  }) =>
      OdbcErrorBoundary.run(
        'executePreparedParamValues',
        () => query.executePreparedParamValues(
          connectionId,
          stmtId,
          params,
          options,
          resultEncoding: resultEncoding,
        ),
      );

  Future<Result<QueryResult>> executePreparedNamed(
    String connectionId,
    int stmtId,
    Map<String, Object?> namedParams,
    StatementOptions? options,
  ) =>
      OdbcErrorBoundary.run(
        'executePreparedNamed',
        () => query.executePreparedNamed(
          connectionId,
          stmtId,
          namedParams,
          options,
        ),
      );

  Future<Result<void>> closeStatement(String connectionId, int stmtId) =>
      OdbcErrorBoundary.runVoid(
        'closeStatement',
        () => query.closeStatement(connectionId, stmtId),
      );

  Future<Result<void>> cancelStatement(String connectionId, int stmtId) =>
      OdbcErrorBoundary.runVoid(
        'cancelStatement',
        () => query.cancelStatement(connectionId, stmtId),
      );

  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryMulti',
        () => query.executeQueryMulti(connectionId, sql),
      );

  Future<Result<QueryResultMulti>> executeQueryMultiFull(
    String connectionId,
    String sql,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryMultiFull',
        () => query.executeQueryMultiFull(connectionId, sql),
      );

  Future<Result<QueryResultMulti>> executeQueryMultiParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryMultiParamValues',
        () => query.executeQueryMultiParamValues(connectionId, sql, params),
      );

  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryMulti',
        () => query.streamQueryMulti(
          connectionId,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  Stream<Result<QueryResultMultiItem>> streamQueryMultiParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryMultiParamValues',
        () => query.streamQueryMultiParamValues(
          connectionId,
          sql,
          params,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  Stream<Result<QueryResultMultiBatchItem>> streamQueryMultiBatchesParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryMultiBatchesParamValues',
        () => query.streamQueryMultiBatchesParamValues(
          connectionId,
          sql,
          params,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  Stream<Result<QueryResultMultiBatchItem>> streamQueryMultiBatches(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryMultiBatches',
        () => query.streamQueryMultiBatches(
          connectionId,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryNamed',
        () => query.executeQueryNamed(connectionId, sql, namedParams),
      );

  Stream<Result<QueryResult>> streamQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryNamed',
        () => query.streamQueryNamed(
          connectionId,
          sql,
          namedParams,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  Future<Result<TypedColumnarResult>> executeQueryColumnarParamValues(
    String connectionId,
    String sql, {
    List<ParamValue>? params,
  }) =>
      OdbcErrorBoundary.run(
        'executeQueryColumnarParamValues',
        () => query.executeQueryColumnarParamValues(
          connectionId,
          sql,
          params: params,
        ),
      );

  Stream<Result<TypedColumnarResult>> streamQueryColumnar(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryColumnar',
        () => query.streamQueryColumnar(
          connectionId,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  Future<Result<QueryResult>> catalogTables({
    required String connectionId,
    String catalog = '',
    String schema = '',
  }) =>
      OdbcErrorBoundary.run(
        'catalogTables',
        () => query.catalogTables(
          connectionId: connectionId,
          catalog: catalog,
          schema: schema,
        ),
      );

  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  ) =>
      OdbcErrorBoundary.run(
        'catalogColumns',
        () => query.catalogColumns(connectionId, table),
      );

  Future<Result<QueryResult>> catalogTypeInfo(String connectionId) =>
      OdbcErrorBoundary.run(
        'catalogTypeInfo',
        () => query.catalogTypeInfo(connectionId),
      );

  Future<Result<QueryResult>> catalogPrimaryKeys(
    String connectionId,
    String table,
  ) =>
      OdbcErrorBoundary.run(
        'catalogPrimaryKeys',
        () => query.catalogPrimaryKeys(connectionId, table),
      );

  Future<Result<QueryResult>> catalogForeignKeys(
    String connectionId,
    String table,
  ) =>
      OdbcErrorBoundary.run(
        'catalogForeignKeys',
        () => query.catalogForeignKeys(connectionId, table),
      );

  Future<Result<QueryResult>> catalogIndexes(
    String connectionId,
    String table,
  ) =>
      OdbcErrorBoundary.run(
        'catalogIndexes',
        () => query.catalogIndexes(connectionId, table),
      );

  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  ) =>
      OdbcErrorBoundary.run(
        'bulkInsert',
        () => query.bulkInsert(
          connectionId,
          table,
          columns,
          dataBuffer,
          rowCount,
        ),
      );

  Future<Result<int>> bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount, {
    int parallelism = 0,
  }) =>
      OdbcErrorBoundary.run(
        'bulkInsertParallel',
        () => query.bulkInsertParallel(
          poolId,
          table,
          columns,
          dataBuffer,
          rowCount,
          parallelism: parallelism,
        ),
      );

  Future<Result<QueryResult>> executeQuery(
    String sql, {
    String? connectionId,
  }) =>
      OdbcErrorBoundary.run(
        'executeQuery',
        () => query.executeQuery(
          sql,
          connectionId: connectionId,
        ),
      );
}
